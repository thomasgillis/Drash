import Foundation
import SQLite3

struct OutdoorCatalogEntry: Hashable, Identifiable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case crag
        case thirteener
    }

    let id: String
    let name: String
    let state: String
    let latitude: Double
    let longitude: Double
    let kind: Kind
    let elevationFeet: Int?

    var weatherLocation: WeatherLocation {
        WeatherLocation(
            name: name,
            state: state,
            latitude: latitude,
            longitude: longitude,
            kind: kind == .thirteener ? .summit : .crag,
            elevation: elevationFeet.map { Elevation(feet: $0, source: .terrainModel) }
        )
    }
}

private enum OutdoorCatalogError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case invalidDatabase
    case unsupportedVersion
    case emptyCatalog
    case missingBundledCatalog
    case olderCatalog
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The outdoor-place catalog could not be downloaded."
        case .httpStatus(404):
            return "No outdoor-place catalog has been published for download yet."
        case let .httpStatus(statusCode):
            return "The outdoor-place catalog could not be downloaded (HTTP \(statusCode))."
        case .invalidDatabase:
            return "The downloaded outdoor-place catalog was damaged."
        case .unsupportedVersion:
            return "The downloaded outdoor-place catalog is not compatible with this version of Drash."
        case .emptyCatalog:
            return "The downloaded outdoor-place catalog was empty."
        case .missingBundledCatalog:
            return "The bundled outdoor-place catalog could not be found."
        case .olderCatalog:
            return "The downloaded outdoor-place catalog is older than the installed catalog."
        case .unavailable:
            return "The outdoor-place catalog is temporarily unavailable."
        }
    }
}

private final class OutdoorCatalogDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let progressHandler: @MainActor (Double) -> Void

    init(progressHandler: @escaping @MainActor (Double) -> Void) {
        self.progressHandler = progressHandler
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = min(
            max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0),
            1
        )
        Task { @MainActor [progressHandler] in
            progressHandler(progress)
        }
    }
}

private final class OutdoorCatalogDatabase {
    struct Metadata {
        let entryCount: Int
        let generatedAt: Date
    }

    private static let applicationID: Int64 = 0x44524153 // "DRAS"
    private static let schemaVersion: Int64 = 1
    private static let catalogVersion = 1
    private static let maximumEntryCount = 250_000
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private var connection: OpaquePointer?
    private(set) var metadata = Metadata(entryCount: 0, generatedAt: .distantPast)

    init(url: URL, thoroughValidation: Bool) throws {
        var openedConnection: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &openedConnection, flags, nil) == SQLITE_OK,
              let openedConnection else {
            if let openedConnection {
                sqlite3_close(openedConnection)
            }
            throw OutdoorCatalogError.invalidDatabase
        }

        connection = openedConnection
        do {
            try execute("PRAGMA query_only = ON")
            try execute("PRAGMA trusted_schema = OFF")
            try execute("PRAGMA cache_size = -1024")

            guard try integer(from: "PRAGMA application_id") == Self.applicationID,
                  try integer(from: "PRAGMA user_version") == Self.schemaVersion else {
                throw OutdoorCatalogError.unsupportedVersion
            }

            let metadataValues = try stringDictionary(
                sql: "SELECT key, value FROM metadata"
            )
            guard metadataValues["schema_version"] == String(Self.schemaVersion),
                  metadataValues["catalog_version"] == String(Self.catalogVersion) else {
                throw OutdoorCatalogError.unsupportedVersion
            }
            guard let countText = metadataValues["entry_count"],
                  let entryCount = Int(countText),
                  let generatedAtText = metadataValues["generated_at"],
                  let generatedAt = ISO8601DateFormatter().date(from: generatedAtText) else {
                throw OutdoorCatalogError.invalidDatabase
            }
            guard entryCount > 0 else { throw OutdoorCatalogError.emptyCatalog }
            guard entryCount <= Self.maximumEntryCount else {
                throw OutdoorCatalogError.invalidDatabase
            }

            try validateEntrySchema()
            if thoroughValidation {
                guard try string(from: "PRAGMA quick_check") == "ok" else {
                    throw OutdoorCatalogError.invalidDatabase
                }
                guard try integer(from: "SELECT COUNT(*) FROM entries") == entryCount else {
                    throw OutdoorCatalogError.invalidDatabase
                }
                guard try integer(from: """
                    SELECT COUNT(*) FROM entries
                    WHERE latitude < -90 OR latitude > 90
                       OR longitude < -180 OR longitude > 180
                       OR kind NOT IN ('crag', 'thirteener')
                    """) == 0 else {
                    throw OutdoorCatalogError.invalidDatabase
                }
            }

            metadata = Metadata(entryCount: entryCount, generatedAt: generatedAt)
        } catch {
            sqlite3_close(openedConnection)
            connection = nil
            throw error
        }
    }

    deinit {
        if let connection {
            sqlite3_close(connection)
        }
    }

    func matches(
        kind: OutdoorCatalogEntry.Kind,
        normalizedQuery: String,
        limit: Int
    ) throws -> [OutdoorCatalogEntry] {
        let categoryText = kind == .crag
            ? "crag climbing area"
            : "13er thirteener summit"
        let searchableTerms = normalizedQuery
            .split(separator: " ")
            .map(String.init)
            .filter { !categoryText.contains($0) }
        guard limit > 0 else { return [] }

        var sql = """
            SELECT id, name, state, latitude, longitude, kind, elevation_feet
            FROM entries
            WHERE kind = ?
            """
        for _ in searchableTerms {
            sql += " AND (normalized_name LIKE ? ESCAPE '\\' OR lower(state) LIKE ? ESCAPE '\\')"
        }
        sql += """
             ORDER BY CASE WHEN normalized_name LIKE ? ESCAPE '\\' THEN 0 ELSE 1 END,
                      normalized_name, state, id
             LIMIT ?
            """

        guard let connection else { throw OutdoorCatalogError.unavailable }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw OutdoorCatalogError.invalidDatabase
        }
        defer { sqlite3_finalize(statement) }

        var parameter: Int32 = 1
        try bind(kind.rawValue, to: parameter, in: statement)
        parameter += 1
        for term in searchableTerms {
            let pattern = "%\(Self.escapedLikeValue(term))%"
            try bind(pattern, to: parameter, in: statement)
            parameter += 1
            try bind(pattern, to: parameter, in: statement)
            parameter += 1
        }
        try bind("\(Self.escapedLikeValue(normalizedQuery))%", to: parameter, in: statement)
        parameter += 1
        guard sqlite3_bind_int(statement, parameter, Int32(limit)) == SQLITE_OK else {
            throw OutdoorCatalogError.invalidDatabase
        }

        var results: [OutdoorCatalogEntry] = []
        results.reserveCapacity(limit)
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let id = columnText(0, from: statement),
                      let name = columnText(1, from: statement),
                      let state = columnText(2, from: statement),
                      let kindText = columnText(5, from: statement),
                      let entryKind = OutdoorCatalogEntry.Kind(rawValue: kindText) else {
                    throw OutdoorCatalogError.invalidDatabase
                }
                let elevation = sqlite3_column_type(statement, 6) == SQLITE_NULL
                    ? nil
                    : Int(sqlite3_column_int(statement, 6))
                results.append(OutdoorCatalogEntry(
                    id: id,
                    name: name,
                    state: state,
                    latitude: sqlite3_column_double(statement, 3),
                    longitude: sqlite3_column_double(statement, 4),
                    kind: entryKind,
                    elevationFeet: elevation
                ))
            case SQLITE_DONE:
                return results
            default:
                throw OutdoorCatalogError.invalidDatabase
            }
        }
    }

    private func validateEntrySchema() throws {
        guard let connection else { throw OutdoorCatalogError.invalidDatabase }
        var statement: OpaquePointer?
        let sql = """
            SELECT id, name, state, latitude, longitude, kind,
                   elevation_feet, normalized_name
            FROM entries LIMIT 0
            """
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else {
            throw OutdoorCatalogError.invalidDatabase
        }
        sqlite3_finalize(statement)
    }

    private func execute(_ sql: String) throws {
        guard let connection,
              sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
            throw OutdoorCatalogError.invalidDatabase
        }
    }

    private func integer(from sql: String) throws -> Int64 {
        guard let connection else { throw OutdoorCatalogError.invalidDatabase }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw OutdoorCatalogError.invalidDatabase
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw OutdoorCatalogError.invalidDatabase
        }
        return sqlite3_column_int64(statement, 0)
    }

    private func string(from sql: String) throws -> String? {
        guard let connection else { throw OutdoorCatalogError.invalidDatabase }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw OutdoorCatalogError.invalidDatabase
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw OutdoorCatalogError.invalidDatabase
        }
        return columnText(0, from: statement)
    }

    private func stringDictionary(sql: String) throws -> [String: String] {
        guard let connection else { throw OutdoorCatalogError.invalidDatabase }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw OutdoorCatalogError.invalidDatabase
        }
        defer { sqlite3_finalize(statement) }

        var result: [String: String] = [:]
        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            guard let key = columnText(0, from: statement),
                  let value = columnText(1, from: statement) else {
                throw OutdoorCatalogError.invalidDatabase
            }
            result[key] = value
            stepResult = sqlite3_step(statement)
        }
        guard stepResult == SQLITE_DONE else {
            throw OutdoorCatalogError.invalidDatabase
        }
        return result
    }

    private func bind(_ value: String, to index: Int32, in statement: OpaquePointer) throws {
        guard sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient) == SQLITE_OK else {
            throw OutdoorCatalogError.invalidDatabase
        }
    }

    private func columnText(_ index: Int32, from statement: OpaquePointer) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private static func escapedLikeValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}

@MainActor
final class OutdoorCatalogStore: ObservableObject {
    @Published private(set) var entryCount = 0
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var refreshProgress = 0.0
    @Published private(set) var refreshError: String?

    private static let refreshURL = URL(
        string: "https://raw.githubusercontent.com/thomasgillis/Drash/main/Drash/Resources/outdoor-places.sqlite"
    )!

    private let session: URLSession
    private var database: OutdoorCatalogDatabase?
    private var matchCache: [OutdoorCatalogEntry.Kind: MatchCache] = [:]

    private struct MatchCache {
        let query: String
        let limit: Int
        let results: [OutdoorCatalogEntry]
    }

    init(session: URLSession = .shared) {
        self.session = session
        loadInitialCatalog()
    }

    func matchingCrags(_ query: String, limit: Int = 8) -> [OutdoorCatalogEntry] {
        matching(query, kind: .crag, limit: limit)
    }

    func matchingThirteeners(_ query: String, limit: Int = 8) -> [OutdoorCatalogEntry] {
        matching(query, kind: .thirteener, limit: limit)
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        refreshProgress = 0
        refreshError = nil
        defer { isRefreshing = false }

        do {
            var request = URLRequest(
                url: Self.refreshURL,
                cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: 30
            )
            request.setValue(
                "application/vnd.sqlite3, application/octet-stream",
                forHTTPHeaderField: "Accept"
            )
            request.setValue("Drash/1.0 (personal iOS weather app)", forHTTPHeaderField: "User-Agent")
            let progressDelegate = OutdoorCatalogDownloadDelegate { [weak self] progress in
                guard let self else { return }
                refreshProgress = max(refreshProgress, progress)
            }
            let (downloadedURL, response) = try await session.download(
                for: request,
                delegate: progressDelegate
            )
            guard let http = response as? HTTPURLResponse else {
                throw OutdoorCatalogError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                throw OutdoorCatalogError.httpStatus(http.statusCode)
            }
            refreshProgress = 1
            guard let activeURL = Self.activeCatalogURL else {
                throw OutdoorCatalogError.unavailable
            }

            try Self.installDatabase(
                from: downloadedURL,
                at: activeURL,
                minimumDate: lastUpdated
            )
            let replacement = try OutdoorCatalogDatabase(
                url: activeURL,
                thoroughValidation: false
            )
            install(replacement)
            Self.removeLegacyJSONCatalog()
        } catch {
            refreshError = error.localizedDescription
        }
    }

    private func loadInitialCatalog() {
        do {
            guard let bundledURL = Bundle.main.url(
                forResource: "outdoor-places",
                withExtension: "sqlite"
            ) else {
                throw OutdoorCatalogError.missingBundledCatalog
            }
            let bundled = try OutdoorCatalogDatabase(
                url: bundledURL,
                thoroughValidation: false
            )

            guard let activeURL = Self.activeCatalogURL else {
                install(bundled)
                return
            }

            if let active = try? OutdoorCatalogDatabase(
                url: activeURL,
                thoroughValidation: false
            ), active.metadata.generatedAt >= bundled.metadata.generatedAt {
                install(active)
            } else {
                try Self.installDatabase(from: bundledURL, at: activeURL)
                install(try OutdoorCatalogDatabase(
                    url: activeURL,
                    thoroughValidation: false
                ))
            }
            Self.removeLegacyJSONCatalog()
        } catch {
            refreshError = error.localizedDescription
        }
    }

    private func install(_ database: OutdoorCatalogDatabase) {
        self.database = database
        matchCache.removeAll(keepingCapacity: true)
        entryCount = database.metadata.entryCount
        lastUpdated = database.metadata.generatedAt
        refreshError = nil
    }

    private func matching(
        _ query: String,
        kind: OutdoorCatalogEntry.Kind,
        limit: Int
    ) -> [OutdoorCatalogEntry] {
        let normalizedQuery = Self.normalize(query)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedQuery.count >= 2, let database else { return [] }
        if let cached = matchCache[kind],
           cached.query == normalizedQuery,
           cached.limit == limit {
            return cached.results
        }
        let results = (try? database.matches(
            kind: kind,
            normalizedQuery: normalizedQuery,
            limit: limit
        )) ?? []
        matchCache[kind] = MatchCache(
            query: normalizedQuery,
            limit: limit,
            results: results
        )
        return results
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    @discardableResult
    private static func installDatabase(
        from sourceURL: URL,
        at destinationURL: URL,
        minimumDate: Date? = nil
    ) throws -> OutdoorCatalogDatabase.Metadata {
        let fileManager = FileManager.default
        let sourceSize = try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard sourceSize > 0, sourceSize <= 64 * 1_024 * 1_024 else {
            throw OutdoorCatalogError.invalidDatabase
        }
        let directory = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let stagingURL = directory.appendingPathComponent(
            "outdoor-places.pending-\(UUID().uuidString).sqlite"
        )
        defer { try? fileManager.removeItem(at: stagingURL) }
        try fileManager.copyItem(at: sourceURL, to: stagingURL)

        let candidate = try OutdoorCatalogDatabase(
            url: stagingURL,
            thoroughValidation: true
        )
        let metadata = candidate.metadata
        if let minimumDate, metadata.generatedAt < minimumDate {
            throw OutdoorCatalogError.olderCatalog
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagingURL)
        } else {
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
        }
        return metadata
    }

    private static var activeCatalogURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Drash", isDirectory: true)
            .appendingPathComponent("outdoor-places.sqlite")
    }

    private static func removeLegacyJSONCatalog() {
        guard let legacyURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?
            .appendingPathComponent("Drash", isDirectory: true)
            .appendingPathComponent("outdoor-places.json") else { return }
        try? FileManager.default.removeItem(at: legacyURL)
    }
}
