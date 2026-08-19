#!/usr/bin/env python3
"""Build Drash's compact offline park, crag, and Colorado summit search catalog."""

from __future__ import annotations

import argparse
import concurrent.futures
import csv
import datetime as dt
import functools
import io
import json
import os
import pathlib
import sqlite3
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
import zipfile


OPENBETA_URL = "https://api.openbeta.io"
GNIS_COLORADO_URL = (
    "https://prd-tnm.s3.amazonaws.com/StagedProducts/GeographicNames/Archive/"
    "MainDomestic/CO_Features_20210825.txt"
)
GNIS_PARKS_URL = (
    "https://prd-tnm.s3.amazonaws.com/StagedProducts/GeographicNames/Archive/"
    "MainDomestic/AllStates.zip"
)
PAD_US_STATE_PARKS_URL = (
    "https://services.arcgis.com/v01gqwM5QqNysAAi/ArcGIS/rest/services/"
    "Management_Areas/FeatureServer/0/query"
)
USA_UUID = "1db1e8ba-a40e-587c-88a4-64f5ea814b8e"
OUTPUT = pathlib.Path(__file__).parents[1] / "Drash/Resources/outdoor-places.sqlite"
FOURTEENERS = pathlib.Path(__file__).with_name("colorado_fourteeners.json")
CRAG_CACHE = pathlib.Path("/private/tmp/drash-outdoor-crags.json")
PARK_CACHE = pathlib.Path("/private/tmp/drash-outdoor-parks-v4.json")
STATE_CACHE = pathlib.Path("/private/tmp/drash-outdoor-state-cache")
USER_AGENT = "Drash catalog builder/1.0"
CATALOG_VERSION = 3
SCHEMA_VERSION = 3
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

# The NPS recognizes 63 units with the National Park designation. Most use the
# same name in the legacy GNIS park layer; these aliases cover renamed units.
NATIONAL_PARK_NAMES = (
    "Acadia National Park", "National Park of American Samoa", "Arches National Park",
    "Badlands National Park", "Big Bend National Park", "Biscayne National Park",
    "Black Canyon of the Gunnison National Park", "Bryce Canyon National Park",
    "Canyonlands National Park", "Capitol Reef National Park",
    "Carlsbad Caverns National Park", "Channel Islands National Park",
    "Congaree National Park", "Crater Lake National Park", "Cuyahoga Valley National Park",
    "Death Valley National Park", "Denali National Park", "Dry Tortugas National Park",
    "Everglades National Park", "Gates of the Arctic National Park",
    "Gateway Arch National Park", "Glacier Bay National Park", "Glacier National Park",
    "Grand Canyon National Park", "Grand Teton National Park", "Great Basin National Park",
    "Great Sand Dunes National Park", "Great Smoky Mountains National Park",
    "Guadalupe Mountains National Park", "Haleakala National Park",
    "Hawai'i Volcanoes National Park", "Hot Springs National Park",
    "Indiana Dunes National Park", "Isle Royale National Park", "Joshua Tree National Park",
    "Katmai National Park", "Kenai Fjords National Park", "Kings Canyon National Park",
    "Kobuk Valley National Park", "Lake Clark National Park", "Lassen Volcanic National Park",
    "Mammoth Cave National Park", "Mesa Verde National Park", "Mount Rainier National Park",
    "New River Gorge National Park and Preserve", "North Cascades National Park",
    "Olympic National Park", "Petrified Forest National Park", "Pinnacles National Park",
    "Redwood National Park", "Rocky Mountain National Park", "Saguaro National Park",
    "Sequoia National Park", "Shenandoah National Park", "Theodore Roosevelt National Park",
    "Virgin Islands National Park", "Voyageurs National Park", "White Sands National Park",
    "Wind Cave National Park", "Wrangell-St. Elias National Park",
    "Yellowstone National Park", "Yosemite National Park", "Zion National Park",
)
NATIONAL_PARK_ALIASES = {
    "Hawai'i Volcanoes National Park": "Hawaiʻi Volcanoes National Park",
    "New River Gorge National Park and Preserve": "New River Gorge National River",
    "Wrangell-St. Elias National Park": "Wrangell-Saint Elias National Park",
}
NATIONAL_PARK_OVERRIDES = {
    # These units are omitted from the archived GNIS administrative layer.
    "Denali National Park": ("AK", 63.3411089987, -150.7341705285),
    "Gates of the Arctic National Park": ("AK", 67.7968076812, -153.3098087878),
    "Lake Clark National Park": ("AK", 60.5471428260, -153.2486904234),
    "Virgin Islands National Park": ("VI", 18.3425688734, -64.7452378784),
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


def request_bytes(request: urllib.request.Request, attempts: int = 8) -> bytes:
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(request, timeout=180) as response:
                return response.read()
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


def fetch_parks(*, use_cache: bool = True) -> list[dict]:
    if use_cache and PARK_CACHE.exists():
        entries = json.loads(PARK_CACHE.read_text())
        print(f"Reusing {len(entries)} state and national parks")
        return entries

    request = urllib.request.Request(GNIS_PARKS_URL, headers={"User-Agent": USER_AGENT})
    archive = zipfile.ZipFile(io.BytesIO(request_bytes(request)))
    state_parks: dict[str, dict] = {}
    park_rows: dict[str, dict] = {}

    for filename in archive.namelist():
        if not filename.endswith(".txt"):
            continue
        with archive.open(filename) as data:
            rows = csv.DictReader(
                io.TextIOWrapper(data, encoding="utf-8-sig", newline=""),
                delimiter="|",
            )
            for row in rows:
                if row.get("FEATURE_CLASS") != "Park":
                    continue
                name = row.get("FEATURE_NAME", "")
                park_rows.setdefault(normalize(name), row)
                if not name.endswith(" State Park"):
                    continue
                entry = park_entry(row, name=name, kind="statePark")
                if entry:
                    state_parks[entry["id"]] = entry

    existing_state_park_keys = {
        f"{normalize(candidate['name'])}|{candidate['state']}"
        for candidate in state_parks.values()
    }
    for entry in fetch_pad_us_state_parks():
        key = f"{normalize(entry['name'])}|{entry['state']}"
        if key not in existing_state_park_keys:
            state_parks[entry["id"]] = entry
            existing_state_park_keys.add(key)

    national_parks: list[dict] = []
    for name in NATIONAL_PARK_NAMES:
        if name in NATIONAL_PARK_OVERRIDES:
            state, latitude, longitude = NATIONAL_PARK_OVERRIDES[name]
            national_parks.append({
                "id": f"nps:{normalize(name).replace(' ', '-')}",
                "name": name,
                "state": state,
                "latitude": latitude,
                "longitude": longitude,
                "kind": "nationalPark",
            })
            continue
        source_name = NATIONAL_PARK_ALIASES.get(name, name)
        entry = park_entry(
            park_rows.get(normalize(source_name)),
            name=name,
            kind="nationalPark",
            identifier=f"nps:{normalize(name).replace(' ', '-')}",
        )
        if not entry:
            raise ValueError(f"GNIS did not contain current national park: {name}")
        national_parks.append(entry)

    if len(national_parks) != 63:
        raise ValueError(f"Expected 63 national parks, found {len(national_parks)}")
    entries = list(state_parks.values()) + national_parks
    print(f"United States: {len(state_parks)} state parks and {len(national_parks)} national parks")
    PARK_CACHE.write_text(json.dumps(entries, ensure_ascii=False, separators=(",", ":")))
    return entries


def fetch_pad_us_state_parks() -> list[dict]:
    """Fetch canonical state-park names and derive compact representative points."""
    groups: dict[tuple[str, str], dict[str, float | str]] = {}
    offset = 0
    while True:
        parameters = urllib.parse.urlencode({
            "where": "DesTp_Desc='State Park' AND Unit_Nm LIKE '% State Park'",
            "outFields": "OBJECTID,Unit_Nm,State_Nm",
            "returnGeometry": "true",
            "outSR": "4326",
            "geometryPrecision": "5",
            "orderByFields": "OBJECTID",
            "resultOffset": str(offset),
            "resultRecordCount": "1000",
            "f": "json",
        })
        request = urllib.request.Request(
            f"{PAD_US_STATE_PARKS_URL}?{parameters}",
            headers={"User-Agent": USER_AGENT},
        )
        payload = request_json(request)
        if payload.get("error"):
            raise RuntimeError(payload["error"])
        features = payload.get("features", [])
        for feature in features:
            attributes = feature.get("attributes") or {}
            name = attributes.get("Unit_Nm", "").strip()
            state = attributes.get("State_Nm", "").strip()
            rings = (feature.get("geometry") or {}).get("rings", [])
            if not name.endswith(" State Park") or len(state) != 2 or not rings:
                continue
            key = (normalize(name), state)
            group = groups.setdefault(key, {
                "name": name,
                "state": state,
                "cross": 0.0,
                "longitude_numerator": 0.0,
                "latitude_numerator": 0.0,
            })
            for ring in rings:
                if len(ring) < 3:
                    continue
                for first, second in zip(ring, ring[1:] + ring[:1]):
                    longitude1, latitude1 = first
                    longitude2, latitude2 = second
                    cross = longitude1 * latitude2 - longitude2 * latitude1
                    group["cross"] += cross
                    group["longitude_numerator"] += (longitude1 + longitude2) * cross
                    group["latitude_numerator"] += (latitude1 + latitude2) * cross
        offset += len(features)
        if not payload.get("exceededTransferLimit") or not features:
            break

    entries: list[dict] = []
    for key, group in groups.items():
        cross = float(group["cross"])
        if abs(cross) < 1e-12:
            continue
        longitude = float(group["longitude_numerator"]) / (3 * cross)
        latitude = float(group["latitude_numerator"]) / (3 * cross)
        if not -90 <= latitude <= 90 or not -180 <= longitude <= 180:
            continue
        normalized_name, state = key
        entries.append({
            "id": f"padus:{normalized_name.replace(' ', '-')}:{state.lower()}",
            "name": str(group["name"]),
            "state": state,
            "latitude": latitude,
            "longitude": longitude,
            "kind": "statePark",
        })
    return entries


def park_entry(
    row: dict | None,
    *,
    name: str,
    kind: str,
    identifier: str | None = None,
) -> dict | None:
    if not row:
        return None
    try:
        latitude = float(row["PRIM_LAT_DEC"])
        longitude = float(row["PRIM_LONG_DEC"])
    except (KeyError, TypeError, ValueError):
        return None
    state = row.get("STATE_ALPHA", "")
    feature_id = row.get("FEATURE_ID", "")
    if (
        len(state) != 2
        or not feature_id
        or not -90 <= latitude <= 90
        or not -180 <= longitude <= 180
    ):
        return None
    return {
        "id": identifier or f"gnis:{feature_id}",
        "name": name,
        "state": state,
        "latitude": latitude,
        "longitude": longitude,
        "kind": kind,
    }


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
                kind TEXT NOT NULL CHECK (kind IN (
                    'crag', 'thirteener', 'fourteener', 'statePark', 'nationalPark'
                )),
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
        help="Convert an existing version-3 JSON catalog without downloading source data.",
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
            raise ValueError("Expected a non-empty version-3 outdoor catalog")
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
    parks = fetch_parks(use_cache=not arguments.refresh)
    entries = crags + thirteeners + fourteeners + parks
    entries.sort(key=lambda item: (item["kind"], item["name"].casefold(), item["state"], item["id"]))
    if database_matches(entries):
        print("Outdoor catalog source data is unchanged; keeping the existing database.")
        return
    generated_at = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    write_database(entries, generated_at)


if __name__ == "__main__":
    main()
