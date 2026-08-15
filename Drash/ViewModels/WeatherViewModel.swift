import CoreLocation
import Foundation

@MainActor
final class WeatherViewModel: ObservableObject {
    @Published private(set) var snapshot: WeatherSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published var temperatureUnit: TemperatureUnit {
        didSet {
            UserDefaults.standard.set(temperatureUnit.rawValue, forKey: Keys.temperatureUnit)
            refresh()
        }
    }
    @Published private(set) var favoriteLocations: [WeatherLocation] {
        didSet { persistFavorites() }
    }
    @Published private(set) var selectedLocation: WeatherLocation? {
        didSet { persistSelectedLocation() }
    }

    private let client: NWSClient
    private let store: SnapshotStore
    private var loadTask: Task<Void, Never>?
    private var loadingLocation: WeatherLocation?
    private var lastSuccessfulFetchAt: Date?
    private var didRestoreLastSession = false
    private var isAwaitingDeviceLocation = false
    private let forecastFreshnessInterval: TimeInterval = 15 * 60
    private let lowPowerForecastFreshnessInterval: TimeInterval = 60 * 60
    private let deviceLocationFreshnessInterval: TimeInterval = 30 * 60
    private let lowPowerDeviceLocationFreshnessInterval: TimeInterval = 60 * 60

    private enum Keys {
        static let favorites = "favoriteLocations"
        static let temperatureUnit = "temperatureUnit"
        static let selectedLocation = "selectedLocation"
    }

    init(client: NWSClient = .shared, store: SnapshotStore = .shared) {
        self.client = client
        self.store = store
        temperatureUnit = TemperatureUnit(
            rawValue: UserDefaults.standard.string(forKey: Keys.temperatureUnit) ?? ""
        ) ?? .fahrenheit
        if let data = UserDefaults.standard.data(forKey: Keys.favorites),
           let saved = try? JSONDecoder().decode([WeatherLocation].self, from: data) {
            favoriteLocations = saved
        } else {
            favoriteLocations = []
        }

        if let data = UserDefaults.standard.data(forKey: Keys.selectedLocation),
           let saved = try? JSONDecoder().decode(WeatherLocation.self, from: data) {
            selectedLocation = saved
        } else {
            selectedLocation = nil
        }
    }

    func restoreLastSession(lowPowerMode: Bool = false) async {
        guard !didRestoreLastSession else { return }
        didRestoreLastSession = true

        var restoredMatchingSnapshot = false
        if let cached = await store.load() {
            let cachedSnapshot = cached.snapshot
            if let selectedLocation {
                if matches(selectedLocation, cachedSnapshot.location) {
                    snapshot = cachedSnapshot
                    self.selectedLocation = cachedSnapshot.location
                    lastSuccessfulFetchAt = cached.savedAt
                    restoredMatchingSnapshot = true
                }
            } else {
                snapshot = cachedSnapshot
                selectedLocation = cachedSnapshot.location
                lastSuccessfulFetchAt = cached.savedAt
                restoredMatchingSnapshot = true
            }
        }

        if let selectedLocation,
           !selectedLocation.isCurrentLocation,
           (!restoredMatchingSnapshot || !hasFreshForecast(lowPowerMode: lowPowerMode)) {
            load(selectedLocation)
        }
    }

    func useDeviceLocation(_ location: CLLocation) {
        guard isAwaitingDeviceLocation || selectedLocation == nil else { return }
        isAwaitingDeviceLocation = false
        let place = WeatherLocation(
            name: "Current location",
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            isCurrentLocation: true
        )
        select(place)
    }

    func beginUsingDeviceLocation() {
        isAwaitingDeviceLocation = true
    }

    func cancelUsingDeviceLocation() {
        isAwaitingDeviceLocation = false
    }

    func shouldRequestDeviceLocation(lowPowerMode: Bool = false) -> Bool {
        guard !isAwaitingDeviceLocation else { return false }
        guard let selectedLocation else { return true }
        guard selectedLocation.isCurrentLocation else { return false }
        guard let lastSuccessfulFetchAt else { return true }
        let freshnessInterval = lowPowerMode
            ? lowPowerDeviceLocationFreshnessInterval
            : deviceLocationFreshnessInterval
        return Date().timeIntervalSince(lastSuccessfulFetchAt) >= freshnessInterval
    }

    func select(_ location: WeatherLocation) {
        if !location.isCurrentLocation {
            isAwaitingDeviceLocation = false
        }
        selectedLocation = location
        load(location)
    }

    func refresh() {
        guard let location = selectedLocation ?? snapshot?.location else { return }
        load(location, force: true)
    }

    func refreshIfStale(lowPowerMode: Bool = false) {
        guard !hasFreshForecast(lowPowerMode: lowPowerMode),
              let location = selectedLocation ?? snapshot?.location else { return }
        load(location)
    }

    func suspendNetworkWork() {
        loadTask?.cancel()
        loadTask = nil
        loadingLocation = nil
        isLoading = false
    }

    func refreshAndWait() async {
        refresh()
        await loadTask?.value
    }

    func addFavorite(_ location: WeatherLocation) {
        let threshold = 0.001
        guard !favoriteLocations.contains(where: {
            abs($0.latitude - location.latitude) < threshold && abs($0.longitude - location.longitude) < threshold
        }) else { return }
        favoriteLocations.append(location)
    }

    func toggleFavorite(_ location: WeatherLocation) {
        if let index = favoriteLocations.firstIndex(where: { matches($0, location) }) {
            favoriteLocations.remove(at: index)
        } else {
            favoriteLocations.append(location)
        }
    }

    func removeFavorites(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            favoriteLocations.remove(at: index)
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    func isFavorite(_ location: WeatherLocation) -> Bool {
        favoriteLocations.contains { matches($0, location) }
    }

    private func hasFreshForecast(lowPowerMode: Bool = false) -> Bool {
        guard let lastSuccessfulFetchAt else { return false }
        let freshnessInterval = lowPowerMode
            ? lowPowerForecastFreshnessInterval
            : forecastFreshnessInterval
        return Date().timeIntervalSince(lastSuccessfulFetchAt) < freshnessInterval
    }

    private func load(_ location: WeatherLocation, force: Bool = false) {
        if !force {
            if let loadingLocation, matches(loadingLocation, location) {
                return
            }
            if let displayedLocation = snapshot?.location,
               matches(displayedLocation, location),
               hasFreshForecast() {
                return
            }
        }

        loadTask?.cancel()
        loadingLocation = location
        errorMessage = nil
        isLoading = true
        loadTask = Task {
            do {
                let result = try await client.weather(for: location, unit: temperatureUnit)
                guard !Task.isCancelled else { return }
                snapshot = result
                selectedLocation = result.location
                lastSuccessfulFetchAt = .now
                loadingLocation = nil
                isLoading = false
                await store.save(result)
            } catch is CancellationError {
                // A new location superseded this request.
            } catch {
                guard !Task.isCancelled else { return }
                loadingLocation = nil
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func persistFavorites() {
        guard let data = try? JSONEncoder().encode(favoriteLocations) else { return }
        UserDefaults.standard.set(data, forKey: Keys.favorites)
    }

    private func persistSelectedLocation() {
        guard let selectedLocation,
              let data = try? JSONEncoder().encode(selectedLocation) else { return }
        UserDefaults.standard.set(data, forKey: Keys.selectedLocation)
    }

    private func matches(_ lhs: WeatherLocation, _ rhs: WeatherLocation) -> Bool {
        abs(lhs.latitude - rhs.latitude) < 0.001 && abs(lhs.longitude - rhs.longitude) < 0.001
    }
}
