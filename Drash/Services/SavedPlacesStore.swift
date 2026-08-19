import Combine
import CoreData
import Foundation
import SwiftData

@Model
final class SavedPlaceRecord {
    var id: UUID = UUID()
    var name: String = ""
    var state: String?
    var latitude: Double = 0
    var longitude: Double = 0
    var forecastModelRawValue: String = ForecastModel.hrrr.rawValue
    var kindRawValue: String = WeatherLocationKind.place.rawValue
    var elevationMeters: Double?
    var elevationSourceRawValue: String?
    var sortOrder: Int = 0
    var modifiedAt: Date = Date()

    init(location: WeatherLocation, sortOrder: Int, modifiedAt: Date = .now) {
        id = location.id
        name = location.name
        state = location.state
        latitude = location.latitude
        longitude = location.longitude
        forecastModelRawValue = location.forecastModel.rawValue
        kindRawValue = location.kind.rawValue
        elevationMeters = location.elevation?.meters
        elevationSourceRawValue = location.elevation?.source.rawValue
        self.sortOrder = sortOrder
        self.modifiedAt = modifiedAt
    }

    var weatherLocation: WeatherLocation {
        let elevation: Elevation?
        if let elevationMeters,
           let sourceValue = elevationSourceRawValue,
           let source = Elevation.Source(rawValue: sourceValue) {
            elevation = Elevation(meters: elevationMeters, source: source)
        } else {
            elevation = nil
        }

        return WeatherLocation(
            id: id,
            name: name,
            state: state,
            latitude: latitude,
            longitude: longitude,
            forecastModel: ForecastModel(rawValue: forecastModelRawValue) ?? .hrrr,
            kind: WeatherLocationKind(rawValue: kindRawValue) ?? .place,
            elevation: elevation
        )
    }

    func update(from location: WeatherLocation) {
        name = location.name
        state = location.state
        latitude = location.latitude
        longitude = location.longitude
        forecastModelRawValue = location.forecastModel.rawValue
        kindRawValue = location.kind.rawValue
        elevationMeters = location.elevation?.meters
        elevationSourceRawValue = location.elevation?.source.rawValue
        modifiedAt = .now
    }
}

@MainActor
final class SavedPlacesStore: ObservableObject {
    static let cloudContainerIdentifier = "iCloud.com.tgillis.Drash"
    static var syncsWithICloud: Bool {
#if ICLOUD_SYNC_ENABLED
        true
#else
        false
#endif
    }

    @Published private(set) var locations: [WeatherLocation] = []

    private enum Keys {
        static let legacyFavorites = "favoriteLocations"
        static let completedLegacyMigration = "savedPlacesSwiftDataMigrationV1"
    }

    private let container: ModelContainer
    private let context: ModelContext
    private var cancellables = Set<AnyCancellable>()

    init(container: ModelContainer? = nil, defaults: UserDefaults = .standard) {
        if let container {
            self.container = container
        } else {
            let schema = Schema([SavedPlaceRecord.self])
            let configuration: ModelConfiguration
#if ICLOUD_SYNC_ENABLED
            configuration = ModelConfiguration(
                "SavedPlaces",
                schema: schema,
                cloudKitDatabase: .private(Self.cloudContainerIdentifier)
            )
#else
            configuration = ModelConfiguration(
                "SavedPlaces",
                schema: schema,
                cloudKitDatabase: .none
            )
#endif
            do {
                self.container = try ModelContainer(
                    for: schema,
                    configurations: [configuration]
                )
            } catch {
                fatalError("Unable to create the saved-places store: \(error.localizedDescription)")
            }
        }

        context = ModelContext(self.container)
        context.autosaveEnabled = false

        migrateLegacyFavoritesIfNeeded(defaults: defaults)
        reload()
        observeCloudKitEvents()
    }

    func reload() {
        do {
            var records = try fetchRecords()
            if removeDuplicateRecords(from: &records) {
                try context.save()
                records = try fetchRecords()
            }
            locations = records.map(\.weatherLocation)
        } catch {
            // Preserve the last successfully loaded list. SwiftData will retry
            // remote imports, and the scene-active refresh provides another read.
        }
    }

    func add(_ location: WeatherLocation) {
        guard !location.isCurrentLocation,
              record(matching: location) == nil else { return }
        let nextSortOrder = ((try? fetchRecords())?.map(\.sortOrder).max() ?? -1) + 1
        context.insert(
            SavedPlaceRecord(location: location, sortOrder: nextSortOrder)
        )
        saveAndReload()
    }

    func toggle(_ location: WeatherLocation) {
        guard !location.isCurrentLocation else { return }
        if let existing = record(matching: location) {
            context.delete(existing)
            saveAndReload()
        } else {
            add(location)
        }
    }

    func remove(_ locations: [WeatherLocation]) {
        let ids = Set(locations.map(\.id))
        guard !ids.isEmpty,
              let records = try? fetchRecords() else { return }
        records.filter { ids.contains($0.id) }.forEach(context.delete)
        saveAndReload()
    }

    func update(_ location: WeatherLocation) {
        guard !location.isCurrentLocation,
              let existing = record(matching: location) else { return }
        existing.update(from: location)
        saveAndReload()
    }

    private func fetchRecords() throws -> [SavedPlaceRecord] {
        let descriptor = FetchDescriptor<SavedPlaceRecord>(
            sortBy: [
                SortDescriptor(\.sortOrder),
                SortDescriptor(\.name),
                SortDescriptor(\.id)
            ]
        )
        return try context.fetch(descriptor)
    }

    private func record(matching location: WeatherLocation) -> SavedPlaceRecord? {
        guard let records = try? fetchRecords() else { return nil }
        return records.first { record in
            record.id == location.id
                || Self.samePlace(record.weatherLocation, location)
        }
    }

    private func saveAndReload() {
        do {
            try context.save()
            reload()
        } catch {
            context.rollback()
        }
    }

    private func migrateLegacyFavoritesIfNeeded(defaults: UserDefaults) {
        guard !defaults.bool(forKey: Keys.completedLegacyMigration) else { return }

        var migrationSucceeded = true
        if let data = defaults.data(forKey: Keys.legacyFavorites),
           let legacyLocations = try? JSONDecoder().decode([WeatherLocation].self, from: data) {
            let existing = (try? fetchRecords()) ?? []
            var knownLocations = existing.map(\.weatherLocation)
            var nextSortOrder = (existing.map(\.sortOrder).max() ?? -1) + 1

            for location in legacyLocations where !location.isCurrentLocation {
                let isDuplicate = knownLocations.contains { knownLocation in
                    knownLocation.id == location.id
                        || Self.samePlace(knownLocation, location)
                }
                guard !isDuplicate else { continue }
                context.insert(SavedPlaceRecord(location: location, sortOrder: nextSortOrder))
                knownLocations.append(location)
                nextSortOrder += 1
            }

            do {
                try context.save()
            } catch {
                context.rollback()
                migrationSucceeded = false
            }
        }

        // Keep the legacy payload as a rollback safety net. This marker only
        // prevents importing the same local records again on every launch.
        if migrationSucceeded {
            defaults.set(true, forKey: Keys.completedLegacyMigration)
        }
    }

    private func removeDuplicateRecords(from records: inout [SavedPlaceRecord]) -> Bool {
        var canonicalRecords: [SavedPlaceRecord] = []
        var removedAny = false

        for record in records {
            guard let duplicateIndex = canonicalRecords.firstIndex(where: {
                $0.id == record.id
                    || Self.samePlace($0.weatherLocation, record.weatherLocation)
            }) else {
                canonicalRecords.append(record)
                continue
            }

            let canonical = canonicalRecords[duplicateIndex]
            if record.modifiedAt > canonical.modifiedAt {
                record.sortOrder = min(record.sortOrder, canonical.sortOrder)
                context.delete(canonical)
                canonicalRecords[duplicateIndex] = record
            } else {
                canonical.sortOrder = min(canonical.sortOrder, record.sortOrder)
                context.delete(record)
            }
            removedAny = true
        }

        records = canonicalRecords.sorted {
            ($0.sortOrder, $0.name, $0.id.uuidString)
                < ($1.sortOrder, $1.name, $1.id.uuidString)
        }
        return removedAny
    }

    private func observeCloudKitEvents() {
        NotificationCenter.default.publisher(
            for: NSPersistentCloudKitContainer.eventChangedNotification
        )
        .compactMap { notification in
            notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event
        }
        .filter { $0.endDate != nil }
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in self?.reload() }
        .store(in: &cancellables)
    }

    private static func samePlace(_ lhs: WeatherLocation, _ rhs: WeatherLocation) -> Bool {
        abs(lhs.latitude - rhs.latitude) < 0.001
            && abs(lhs.longitude - rhs.longitude) < 0.001
    }
}
