#!/usr/bin/env python3
"""Build Drash's compact offline crag and Colorado summit search catalog."""

from __future__ import annotations

import argparse
import concurrent.futures
import csv
import datetime as dt
import functools
import json
import os
import pathlib
import sqlite3
import time
import unicodedata
import urllib.error
import urllib.request


OPENBETA_URL = "https://api.openbeta.io"
GNIS_COLORADO_URL = (
    "https://prd-tnm.s3.amazonaws.com/StagedProducts/GeographicNames/Archive/"
    "MainDomestic/CO_Features_20210825.txt"
)
USA_UUID = "1db1e8ba-a40e-587c-88a4-64f5ea814b8e"
OUTPUT = pathlib.Path(__file__).parents[1] / "Drash/Resources/outdoor-places.sqlite"
FOURTEENERS = pathlib.Path(__file__).with_name("colorado_fourteeners.json")
CRAG_CACHE = pathlib.Path("/private/tmp/drash-outdoor-crags.json")
STATE_CACHE = pathlib.Path("/private/tmp/drash-outdoor-state-cache")
USER_AGENT = "Drash catalog builder/1.0"
CATALOG_VERSION = 2
SCHEMA_VERSION = 2
APPLICATION_ID = 0x44524153  # "DRAS"

STATE_CODES = {
    "Alabama": "AL", "Arizona": "AZ", "Arkansas": "AR", "California": "CA",
    "Colorado": "CO", "Connecticut": "CT", "Delaware": "DE", "Florida": "FL",
    "Georgia": "GA", "Idaho": "ID", "Illinois": "IL", "Indiana": "IN",
    "Iowa": "IA", "Kansas": "KS", "Kentucky": "KY", "Louisiana": "LA",
    "Maine": "ME", "Maryland": "MD", "Massachusetts": "MA", "Michigan": "MI",
    "Minnesota": "MN", "Mississippi": "MS", "Missouri": "MO", "Montana": "MT",
    "Nebraska": "NE", "Nevada": "NV", "New Hampshire": "NH", "New Jersey": "NJ",
    "New Mexico": "NM", "New York": "NY", "North Carolina": "NC", "North Dakota": "ND",
    "Ohio": "OH", "Oklahoma": "OK", "Oregon": "OR", "Pennsylvania": "PA",
    "Rhode Island": "RI", "South Carolina": "SC", "South Dakota": "SD",
    "Tennessee": "TN", "Texas": "TX", "Utah": "UT", "Vermont": "VT",
    "Virginia": "VA", "Washington": "WA", "West Virginia": "WV", "Wisconsin": "WI",
    "Wyoming": "WY", "District of Columbia": "DC",
}


def request_json(request: urllib.request.Request, attempts: int = 8) -> dict:
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(request, timeout=90) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            if attempt + 1 == attempts:
                raise
            retry_after = int(error.headers.get("Retry-After", "0"))
            time.sleep(max(retry_after, min(60, 5 * (attempt + 1))))
        except Exception:
            if attempt + 1 == attempts:
                raise
            time.sleep(min(30, 2 ** attempt))
    raise RuntimeError("unreachable")


def graphql(query: str, variables: dict | None = None) -> dict:
    body = json.dumps({"query": query, "variables": variables or {}}).encode()
    request = urllib.request.Request(
        OPENBETA_URL,
        data=body,
        headers={"Content-Type": "application/json", "User-Agent": USER_AGENT},
    )
    payload = request_json(request)
    if payload.get("errors"):
        raise RuntimeError(payload["errors"])
    return payload["data"]


def openbeta_states() -> list[dict]:
    query = """
    query StateAreas($uuid: ID!) {
      area(uuid: $uuid) { children { uuid area_name } }
    }
    """
    children = graphql(query, {"uuid": USA_UUID})["area"]["children"]
    return [child for child in children if child["area_name"] in STATE_CODES]


def fetch_state_crags(state: dict, *, use_cache: bool = True) -> list[dict]:
    STATE_CACHE.mkdir(parents=True, exist_ok=True)
    cache_path = STATE_CACHE / f"{STATE_CODES[state['area_name']]}.json"
    if use_cache and cache_path.exists():
        return json.loads(cache_path.read_text())

    query = """
    query StateCatalog($ancestors: [String!]!, $limit: Int, $offset: Int) {
      bulkAreas(ancestors: $ancestors, limit: $limit, offset: $offset) {
        uuid
        area_name
        pathTokens
        totalClimbs
        metadata { lat lng }
      }
    }
    """
    state_name = state["area_name"]
    entries: list[dict] = []
    offset = 0
    while True:
        areas = graphql(
            query,
            {"ancestors": [USA_UUID, state["uuid"]], "limit": 500, "offset": offset},
        )["bulkAreas"]
        for area in areas:
            metadata = area.get("metadata") or {}
            latitude = metadata.get("lat")
            longitude = metadata.get("lng")
            if (
                area.get("totalClimbs", 0) <= 0
                or len(area.get("pathTokens", [])) < 3
                or not isinstance(latitude, (int, float))
                or not isinstance(longitude, (int, float))
                or not -90 <= latitude <= 90
                or not -180 <= longitude <= 180
            ):
                continue
            entries.append(
                {
                    "id": f"openbeta:{area['uuid']}",
                    "name": area["area_name"],
                    "state": STATE_CODES[state_name],
                    "latitude": latitude,
                    "longitude": longitude,
                    "kind": "crag",
                }
            )
        if len(areas) < 500:
            break
        offset += len(areas)
    print(f"{state_name}: {len(entries)} climbing areas")
    cache_path.write_text(json.dumps(entries, ensure_ascii=False, separators=(",", ":")))
    return entries


def fetch_thirteeners() -> list[dict]:
    request = urllib.request.Request(GNIS_COLORADO_URL, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=90) as response:
        lines = (line.decode("utf-8-sig") for line in response)
        rows = list(csv.DictReader(lines, delimiter="|"))

    entries: list[dict] = []
    for summit in rows:
        if summit["FEATURE_CLASS"] != "Summit" or summit["STATE_ALPHA"] != "CO":
            continue
        try:
            feet = int(summit["ELEV_IN_FT"])
            latitude = float(summit["PRIM_LAT_DEC"])
            longitude = float(summit["PRIM_LONG_DEC"])
        except (TypeError, ValueError):
            continue
        if 13_000 <= feet < 14_000:
            entries.append(
                {
                    "id": f"gnis:{summit['FEATURE_ID']}",
                    "name": summit["FEATURE_NAME"],
                    "state": "CO",
                    "latitude": latitude,
                    "longitude": longitude,
                    "kind": "thirteener",
                    "elevationFeet": feet,
                }
            )
    print(f"Colorado: {len(entries)} named 13ers")
    return entries


def load_fourteeners() -> list[dict]:
    entries = json.loads(FOURTEENERS.read_text())
    if len(entries) != 58:
        raise ValueError(f"Expected 58 named Colorado 14ers, found {len(entries)}")
    for entry in entries:
        if (
            entry.get("state") != "CO"
            or entry.get("kind") != "fourteener"
            or not 14_000 <= entry.get("elevationFeet", 0) < 15_000
            or not -90 <= entry.get("latitude", 91) <= 90
            or not -180 <= entry.get("longitude", 181) <= 180
        ):
            raise ValueError(f"Invalid Colorado 14er entry: {entry!r}")
    print(f"Colorado: {len(entries)} named 14ers")
    return entries


def normalize(value: str) -> str:
    decomposed = unicodedata.normalize("NFKD", value)
    return "".join(character for character in decomposed if not unicodedata.combining(character)).casefold()


def database_matches(entries: list[dict]) -> bool:
    """Return whether the existing database already contains the source entries."""
    if not OUTPUT.exists():
        return False

    expected_rows = sorted(
        (
            entry["id"],
            entry["name"],
            entry["state"],
            entry["latitude"],
            entry["longitude"],
            entry["kind"],
            entry.get("elevationFeet"),
            normalize(entry["name"]),
        )
        for entry in entries
    )

    try:
        connection = sqlite3.connect(f"file:{OUTPUT}?mode=ro", uri=True)
        try:
            application_id = connection.execute("PRAGMA application_id").fetchone()[0]
            schema_version = connection.execute("PRAGMA user_version").fetchone()[0]
            metadata = dict(connection.execute("SELECT key, value FROM metadata"))
            existing_rows = connection.execute(
                """
                SELECT id, name, state, latitude, longitude, kind,
                       elevation_feet, normalized_name
                FROM entries
                ORDER BY id
                """
            ).fetchall()
        finally:
            connection.close()
    except (OSError, sqlite3.Error, TypeError):
        return False

    return (
        application_id == APPLICATION_ID
        and schema_version == SCHEMA_VERSION
        and metadata.get("catalog_version") == str(CATALOG_VERSION)
        and metadata.get("schema_version") == str(SCHEMA_VERSION)
        and metadata.get("entry_count") == str(len(entries))
        and existing_rows == expected_rows
    )


def write_database(entries: list[dict], generated_at: str) -> None:
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    temporary_output = OUTPUT.with_suffix(".sqlite.tmp")
    temporary_output.unlink(missing_ok=True)

    connection = sqlite3.connect(temporary_output)
    try:
        connection.execute(f"PRAGMA application_id = {APPLICATION_ID}")
        connection.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")
        connection.execute("PRAGMA journal_mode = OFF")
        connection.execute("PRAGMA synchronous = OFF")
        connection.executescript(
            """
            CREATE TABLE metadata (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            ) WITHOUT ROWID;

            CREATE TABLE entries (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                state TEXT NOT NULL,
                latitude REAL NOT NULL,
                longitude REAL NOT NULL,
                kind TEXT NOT NULL CHECK (kind IN ('crag', 'thirteener', 'fourteener')),
                elevation_feet INTEGER,
                normalized_name TEXT NOT NULL
            ) WITHOUT ROWID;

            CREATE INDEX entries_kind_name
                ON entries(kind, normalized_name);
            """
        )
        connection.executemany(
            "INSERT INTO metadata(key, value) VALUES (?, ?)",
            [
                ("catalog_version", str(CATALOG_VERSION)),
                ("schema_version", str(SCHEMA_VERSION)),
                ("generated_at", generated_at),
                ("entry_count", str(len(entries))),
            ],
        )
        connection.executemany(
            """
            INSERT INTO entries(
                id, name, state, latitude, longitude, kind,
                elevation_feet, normalized_name
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                (
                    entry["id"],
                    entry["name"],
                    entry["state"],
                    entry["latitude"],
                    entry["longitude"],
                    entry["kind"],
                    entry.get("elevationFeet"),
                    normalize(entry["name"]),
                )
                for entry in entries
            ),
        )
        connection.commit()
        connection.execute("ANALYZE")
        connection.execute("VACUUM")
        integrity = connection.execute("PRAGMA quick_check").fetchone()
        if integrity != ("ok",):
            raise RuntimeError(f"SQLite integrity check failed: {integrity}")
    finally:
        connection.close()

    os.replace(temporary_output, OUTPUT)
    print(f"Wrote {len(entries)} entries to {OUTPUT} ({OUTPUT.stat().st_size:,} bytes)")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--from-json",
        type=pathlib.Path,
        help="Convert an existing version-2 JSON catalog without downloading source data.",
    )
    parser.add_argument(
        "--refresh",
        action="store_true",
        help="Ignore cached OpenBeta data and fetch every source again.",
    )
    arguments = parser.parse_args()

    if arguments.from_json:
        catalog = json.loads(arguments.from_json.read_text())
        if catalog.get("version") != CATALOG_VERSION or not catalog.get("entries"):
            raise ValueError("Expected a non-empty version-1 outdoor catalog")
        write_database(catalog["entries"], catalog["generatedAt"])
        return

    if CRAG_CACHE.exists() and not arguments.refresh:
        crags = json.loads(CRAG_CACHE.read_text())
        print(f"Reusing {len(crags)} cached climbing areas")
    else:
        states = openbeta_states()
        crags: list[dict] = []
        fetch_crags = functools.partial(fetch_state_crags, use_cache=not arguments.refresh)
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
            for entries in executor.map(fetch_crags, states):
                crags.extend(entries)
        CRAG_CACHE.write_text(json.dumps(crags, ensure_ascii=False, separators=(",", ":")))

    thirteeners = fetch_thirteeners()
    fourteeners = load_fourteeners()
    entries = crags + thirteeners + fourteeners
    entries.sort(key=lambda item: (item["kind"], item["name"].casefold(), item["state"], item["id"]))
    if database_matches(entries):
        print("Outdoor catalog source data is unchanged; keeping the existing database.")
        return
    generated_at = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    write_database(entries, generated_at)


if __name__ == "__main__":
    main()
