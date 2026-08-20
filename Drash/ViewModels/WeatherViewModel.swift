import CoreLocation
import Combine
import Foundation

@MainActor
final class WeatherViewModel: ObservableObject {
    @Published private(set) var snapshot: WeatherSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastRefreshFailureAt: Date?
    @Published var temperatureUnit: TemperatureUnit {
        didSet {
            UserDefaults.standard.set(temperatureUnit.rawValue, forKey: Keys.temperatureUnit)
            WidgetWeatherData.setPreferredTemperatureUnit(
                temperatureUnit == .fahrenheit ? "F" : "C"
            )
            refresh()
        }
    }
    @Published var altitudeUnit: AltitudeUnit {
        didSet {
            UserDefaults.standard.set(altitudeUnit.rawValue, forKey: Keys.altitudeUnit)
        }
    }
    @Published var precipitationVolumeRepresentation: PrecipitationVolumeRepresentation {
        didSet {
            UserDefaults.standard.set(
                precipitationVolumeRepresentation.rawValue,
                forKey: Keys.precipitationVolumeRepresentation
            )
        }
    }
    @Published var currentAndHourlyForecastModel: ForecastModel {
        didSet {
            UserDefaults.standard.set(
                currentAndHourlyForecastModel.rawValue,
                forKey: Keys.currentAndHourlyForecastModel
            )
            refresh()
        }
    }
    @Published private(set) var favoriteLocations: [WeatherLocation]
    @Published private(set) var selectedLocation: WeatherLocation? {
        didSet { persistSelectedLocation() }
    }

    private let client: WeatherClient
    private let store: SnapshotStore
    private let savedPlacesStore: SavedPlacesStore
    private var savedPlacesCancellable: AnyCancellable?
    private var loadTask: Task<Void, Never>?
    private var widgetLoadTask: Task<Void, Never>?
    private var loadingLocation: WeatherLocation?
    private var loadingUnit: TemperatureUnit?
    private var loadingHourlyModel: ForecastModel?
    private var activeLoadID: UUID?
    private var lastSuccessfulFetchAt: Date?
    private var nextAutomaticFetchAt: Date?
    private var didRestoreLastSession = false
    private var isAwaitingDeviceLocation = false
    private var lastDeviceLocationAt: Date?
    private let forecastFreshnessInterval: TimeInterval = 15 * 60
    private let lowPowerForecastFreshnessInterval: TimeInterval = 60 * 60
    private let deviceLocationFreshnessInterval: TimeInterval = 30 * 60
    private let lowPowerDeviceLocationFreshnessInterval: TimeInterval = 60 * 60

    private enum Keys {
        static let temperatureUnit = "temperatureUnit"
        static let altitudeUnit = "altitudeUnit"
        static let precipitationVolumeRepresentation = "precipitationVolumeRepresentation"
        static let currentAndHourlyForecastModel = "currentAndHourlyForecastModel"
        static let selectedLocation = "selectedLocation"
        static let precipitationTimingVersion = "precipitationTimingVersion"
    }

    init(
        client: WeatherClient = .shared,
        store: SnapshotStore = .shared,
        savedPlacesStore: SavedPlacesStore? = nil
    ) {
        let savedPlacesStore = savedPlacesStore ?? SavedPlacesStore()
        self.client = client
        self.store = store
        self.savedPlacesStore = savedPlacesStore
        temperatureUnit = TemperatureUnit(
            rawValue: UserDefaults.standard.string(forKey: Keys.temperatureUnit) ?? ""
        ) ?? .fahrenheit
        altitudeUnit = AltitudeUnit(
            rawValue: UserDefaults.standard.string(forKey: Keys.altitudeUnit) ?? ""
        ) ?? .feet
        precipitationVolumeRepresentation = PrecipitationVolumeRepresentation(
            rawValue: UserDefaults.standard.string(
                forKey: Keys.precipitationVolumeRepresentation
            ) ?? ""
        ) ?? .expected
        currentAndHourlyForecastModel = ForecastModel(
            rawValue: UserDefaults.standard.string(forKey: Keys.currentAndHourlyForecastModel) ?? ""
        ) ?? .hrrr
        favoriteLocations = savedPlacesStore.locations

        if let data = UserDefaults.standard.data(forKey: Keys.selectedLocation),
           let saved = try? JSONDecoder().decode(WeatherLocation.self, from: data) {
            selectedLocation = saved
        } else {
            selectedLocation = nil
        }
        WidgetWeatherData.setPreferredTemperatureUnit(
            temperatureUnit == .fahrenheit ? "F" : "C"
        )
        savedPlacesCancellable = savedPlacesStore.$locations
            .sink { [weak self] locations in
                self?.favoriteLocations = locations
            }
    }

    func restoreLastSession(lowPowerMode: Bool = false) async {
        guard !didRestoreLastSession else { return }
        didRestoreLastSession = true

        var restoredMatchingSnapshot = false
        var requiresHourlySourceRefresh = false
        if let cached = await store.load() {
            let cachedSnapshot = cached.snapshot
            requiresHourlySourceRefresh = cachedSnapshot.effectiveHourlyForecastModel
                != currentAndHourlyForecastModel
                || cachedSnapshot.observationModel != currentAndHourlyForecastModel
                || cachedSnapshot.dailyPrecipitationAmounts == nil
                || UserDefaults.standard.integer(forKey: Keys.precipitationTimingVersion) < 2
            if let selectedLocation {
                if sameForecast(selectedLocation, cachedSnapshot.location) {
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
            if restoredMatchingSnapshot {
                publishWidget(cachedSnapshot)
            }
        }

        if let selectedLocation {
            if requiresHourlySourceRefresh {
                load(selectedLocation, force: true)
            } else if !selectedLocation.isCurrentLocation,
                      (!restoredMatchingSnapshot || !hasFreshForecast(lowPowerMode: lowPowerMode)) {
                load(selectedLocation)
            }
        }
    }

    func useDeviceLocation(_ location: CLLocation) {
        lastDeviceLocationAt = .now
        let previous = selectedLocation?.isCurrentLocation == true
            ? selectedLocation
            : nil
        let place = WeatherLocation(
            id: previous?.id ?? UUID(),
            name: "Current location",
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            isCurrentLocation: true,
            forecastModel: previous?.forecastModel ?? .hrrr
        )
        if isAwaitingDeviceLocation
            || selectedLocation == nil
            || selectedLocation?.isCurrentLocation == true {
            isAwaitingDeviceLocation = false
            select(place)
        } else {
            refreshWidget(for: place)
        }
    }

    func beginUsingDeviceLocation() {
        isAwaitingDeviceLocation = true
    }

    func cancelUsingDeviceLocation() {
        isAwaitingDeviceLocation = false
    }

    func shouldRequestDeviceLocation(lowPowerMode: Bool = false) -> Bool {
        guard !isAwaitingDeviceLocation else { return false }
        guard let lastDeviceLocationAt else { return true }
        let freshnessInterval = lowPowerMode
            ? lowPowerDeviceLocationFreshnessInterval
            : deviceLocationFreshnessInterval
        return Date().timeIntervalSince(lastDeviceLocationAt) >= freshnessInterval
    }

    func select(_ location: WeatherLocation) {
        if !location.isCurrentLocation {
            isAwaitingDeviceLocation = false
        }
        selectedLocation = location
        load(location)
    }

    var selectedForecastModel: ForecastModel {
        selectedLocation?.forecastModel ?? snapshot?.location.forecastModel ?? .hrrr
    }

    var didLastRefreshFail: Bool { lastRefreshFailureAt != nil }
    var isRefreshInProgress: Bool { loadingLocation != nil }
    var savedPlacesSyncEnabled: Bool { SavedPlacesStore.syncsWithICloud }

    var loadingDescription: String {
        selectedForecastModel == currentAndHourlyForecastModel
            ? "Loading \(selectedForecastModel.shortName) forecast…"
            : "Loading NWS and HRRR forecasts…"
    }

    func selectForecastModel(_ forecastModel: ForecastModel) {
        guard var location = selectedLocation ?? snapshot?.location,
              location.forecastModel != forecastModel else { return }
        location.forecastModel = forecastModel

        if favoriteLocations.contains(where: { samePlace($0, location) }) {
            savedPlacesStore.update(location)
        }

        selectedLocation = location
        load(location, force: true)
    }

    func refresh() {
        guard let location = selectedLocation ?? snapshot?.location else { return }
        load(location, force: true)
    }

    func forceRefreshNow() {
        guard let location = selectedLocation ?? snapshot?.location else { return }
        load(location, force: true, forceProviderRetry: true)
    }

    func refreshIfStale(lowPowerMode: Bool = false) {
        guard nextAutomaticFetchAt.map({ Date() >= $0 }) ?? true,
              !hasFreshForecast(lowPowerMode: lowPowerMode),
              let location = selectedLocation ?? snapshot?.location else { return }
        load(location)
    }

    func suspendNetworkWork() {
        loadTask?.cancel()
        widgetLoadTask?.cancel()
        loadTask = nil
        widgetLoadTask = nil
        loadingLocation = nil
        loadingUnit = nil
        loadingHourlyModel = nil
        activeLoadID = nil
        isLoading = false
    }

    func refreshAndWait() async {
        refresh()
        await loadTask?.value
    }

    func addFavorite(_ location: WeatherLocation) {
        savedPlacesStore.add(location)
    }

    func toggleFavorite(_ location: WeatherLocation) {
        savedPlacesStore.toggle(location)
    }

    func removeFavorites(at offsets: IndexSet) {
        let removedLocations = offsets.compactMap { index in
            favoriteLocations.indices.contains(index) ? favoriteLocations[index] : nil
        }
        savedPlacesStore.remove(removedLocations)
    }

    func reloadSavedPlaces() {
        savedPlacesStore.reload()
    }

    func dismissError() {
        errorMessage = nil
    }

    func isFavorite(_ location: WeatherLocation) -> Bool {
        guard !location.isCurrentLocation else { return false }
        return favoriteLocations.contains { samePlace($0, location) }
    }

    private func hasFreshForecast(lowPowerMode: Bool = false) -> Bool {
        guard let lastSuccessfulFetchAt else { return false }
        let freshnessInterval = lowPowerMode
            ? lowPowerForecastFreshnessInterval
            : forecastFreshnessInterval
        return Date().timeIntervalSince(lastSuccessfulFetchAt) < freshnessInterval
    }

    private func load(
        _ location: WeatherLocation,
        force: Bool = false,
        forceProviderRetry: Bool = false
    ) {
        if let loadingLocation,
           loadingUnit == temperatureUnit,
           loadingHourlyModel == currentAndHourlyForecastModel,
           sameForecast(loadingLocation, location) {
            return
        }

        if !force {
            if let displayedLocation = snapshot?.location,
               sameForecast(displayedLocation, location),
               hasFreshForecast() {
                return
            }
        }

        loadTask?.cancel()
        let loadID = UUID()
        let requestedUnit = temperatureUnit
        let requestedHourlyModel = currentAndHourlyForecastModel
        loadingLocation = location
        loadingUnit = requestedUnit
        loadingHourlyModel = requestedHourlyModel
        activeLoadID = loadID
        nextAutomaticFetchAt = Date().addingTimeInterval(forecastFreshnessInterval)
        errorMessage = nil
        isLoading = true
        loadTask = Task {
            do {
                let result = try await client.weather(
                    for: location,
                    unit: requestedUnit,
                    hourlyModel: requestedHourlyModel,
                    forceHRRRRetry: forceProviderRetry
                ) { [weak self] coreForecast in
                    await self?.publishCoreForecast(coreForecast, for: loadID)
                }
                guard !Task.isCancelled, activeLoadID == loadID else { return }
                apply(result)
                await store.save(result)
                UserDefaults.standard.set(2, forKey: Keys.precipitationTimingVersion)
                finishLoad(loadID, wasSuccessful: true)
            } catch is CancellationError {
                // A new location superseded this request.
            } catch {
                guard !Task.isCancelled, activeLoadID == loadID else { return }
                finishLoad(loadID, wasSuccessful: false)
                lastRefreshFailureAt = .now
                if case let HRRRServiceError.rateLimited(retryAt) = error {
                    nextAutomaticFetchAt = max(nextAutomaticFetchAt ?? .distantPast, retryAt)
                }
                if case let WeatherServiceError.rateLimited(retryAt) = error {
                    nextAutomaticFetchAt = max(nextAutomaticFetchAt ?? .distantPast, retryAt)
                }
                if let displayedLocation = snapshot?.location,
                   samePlace(displayedLocation, location),
                   displayedLocation.forecastModel != location.forecastModel {
                    selectedLocation = displayedLocation
                    if favoriteLocations.contains(where: {
                        samePlace($0, displayedLocation)
                    }) {
                        savedPlacesStore.update(displayedLocation)
                    }
                }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func publishCoreForecast(_ result: WeatherSnapshot, for loadID: UUID) async {
        guard !Task.isCancelled, activeLoadID == loadID else { return }
        apply(retainingSupplementalData(in: result))
        lastRefreshFailureAt = nil
        lastSuccessfulFetchAt = .now
        isLoading = false
    }

    private func retainingSupplementalData(in core: WeatherSnapshot) -> WeatherSnapshot {
        guard let previous = snapshot,
              samePlace(previous.location, core.location) else { return core }
        let retainsSameHourlySource = previous.effectiveHourlyForecastModel
            == core.effectiveHourlyForecastModel

        return WeatherSnapshot(
            location: core.location,
            updatedAt: core.updatedAt,
            forecastOffice: core.forecastOffice ?? previous.forecastOffice,
            daily: core.daily,
            hourly: core.hourly,
            precipitationAmounts: core.precipitationAmounts,
            dailyPrecipitationAmounts: core.dailyPrecipitationAmounts,
            observation: retainsSameHourlySource && core.location.kind != .summit
                ? previous.observation ?? core.observation
                : core.observation,
            observationModel: core.observationModel,
            hrrrCurrentTemperature: core.hrrrCurrentTemperature,
            station: retainsSameHourlySource ? previous.station : core.station,
            alerts: previous.alerts,
            alertsUnavailable: previous.alertsUnavailable,
            hourlyForecastModel: core.hourlyForecastModel
        )
    }

    private func apply(_ result: WeatherSnapshot) {
        snapshot = result
        selectedLocation = result.location
        if favoriteLocations.contains(where: {
            samePlace($0, result.location)
        }) {
            savedPlacesStore.update(result.location)
        }
        publishWidget(result)
    }

    private func refreshWidget(for location: WeatherLocation) {
        widgetLoadTask?.cancel()
        let requestedUnit = temperatureUnit
        let requestedHourlyModel = currentAndHourlyForecastModel
        widgetLoadTask = Task {
            do {
                let result = try await client.weather(
                    for: location,
                    unit: requestedUnit,
                    hourlyModel: requestedHourlyModel
                ) { [weak self] coreForecast in
                    await self?.publishWidget(coreForecast, unit: requestedUnit)
                }
                guard !Task.isCancelled else { return }
                publishWidget(result, unit: requestedUnit)
            } catch {
                // Keep the last successful widget value when a background-style
                // current-location refresh is unavailable.
            }
            widgetLoadTask = nil
        }
    }

    private func publishWidget(_ result: WeatherSnapshot, unit: TemperatureUnit? = nil) {
        guard result.location.isCurrentLocation else { return }
        guard let currentHour = result.hourly.first else { return }
        let widgetUnit = unit ?? temperatureUnit
        let currentObservation = result.observationModel == result.effectiveHourlyForecastModel
            ? result.observation
            : nil
        let currentTemperature: Int?
        if result.effectiveHourlyForecastModel == .hrrr {
            currentTemperature = result.hrrrCurrentTemperature?.temperature(in: widgetUnit)
                ?? currentObservation?.temperature.temperature(in: widgetUnit)
                ?? currentHour.temperature(in: widgetUnit)
        } else {
            currentTemperature = currentObservation?.temperature.temperature(in: widgetUnit)
                ?? currentHour.temperature(in: widgetUnit)
        }
        guard let currentTemperature else { return }

        WidgetWeatherData(
            locationName: result.location.displayName,
            temperature: currentTemperature,
            temperatureUnit: widgetUnit == .fahrenheit ? "F" : "C",
            rainChance: currentHour.precipitationChance,
            summary: currentObservation?.displayDescription ?? currentHour.shortForecast,
            symbolName: currentHour.symbolName,
            isDaytime: currentHour.isDaytime,
            updatedAt: result.updatedAt,
            latitude: result.location.latitude,
            longitude: result.location.longitude
        ).save()
    }

    private func finishLoad(_ loadID: UUID, wasSuccessful: Bool) {
        guard activeLoadID == loadID else { return }
        if wasSuccessful {
            lastSuccessfulFetchAt = .now
            nextAutomaticFetchAt = Date().addingTimeInterval(forecastFreshnessInterval)
        }
        loadingLocation = nil
        loadingUnit = nil
        loadingHourlyModel = nil
        activeLoadID = nil
        loadTask = nil
        isLoading = false
    }

    private func persistSelectedLocation() {
        guard let selectedLocation,
              let data = try? JSONEncoder().encode(selectedLocation) else { return }
        UserDefaults.standard.set(data, forKey: Keys.selectedLocation)
    }

    private func samePlace(_ lhs: WeatherLocation, _ rhs: WeatherLocation) -> Bool {
        abs(lhs.latitude - rhs.latitude) < 0.001 && abs(lhs.longitude - rhs.longitude) < 0.001
    }

    private func sameForecast(_ lhs: WeatherLocation, _ rhs: WeatherLocation) -> Bool {
        samePlace(lhs, rhs)
            && lhs.forecastModel == rhs.forecastModel
            && sameElevation(lhs.elevation, rhs.elevation)
    }

    private func sameElevation(_ lhs: Elevation?, _ rhs: Elevation?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return abs(lhs.meters - rhs.meters) < 1
        default:
            return false
        }
    }
}
