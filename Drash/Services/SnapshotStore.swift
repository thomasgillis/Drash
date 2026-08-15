import Foundation

struct CachedWeatherSnapshot: Codable, Sendable {
    let snapshot: WeatherSnapshot
    let savedAt: Date
}

actor SnapshotStore {
    static let shared = SnapshotStore()

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var cacheURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("weather-snapshot.json")
    }

    func save(_ snapshot: WeatherSnapshot) {
        let cached = CachedWeatherSnapshot(snapshot: snapshot, savedAt: .now)
        guard let cacheURL, let data = try? encoder.encode(cached) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    func load() -> CachedWeatherSnapshot? {
        guard let cacheURL,
              let data = try? Data(contentsOf: cacheURL) else { return nil }

        if let cached = try? decoder.decode(CachedWeatherSnapshot.self, from: data) {
            return cached
        }

        // Preserve caches created by earlier Drash builds.
        guard let snapshot = try? decoder.decode(WeatherSnapshot.self, from: data) else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: cacheURL.path)
        let savedAt = attributes?[.modificationDate] as? Date ?? snapshot.updatedAt
        return CachedWeatherSnapshot(snapshot: snapshot, savedAt: savedAt)
    }
}
