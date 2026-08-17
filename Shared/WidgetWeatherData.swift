import Foundation
import WidgetKit

struct WidgetWeatherData: Codable, Sendable {
    static let appGroupIdentifier = "group.com.tgillis.Drash"
    static let widgetKind = "DrashWeatherWidget"

    // Use a dedicated key so builds that previously stored the selected place
    // can never surface that stale place as current-location weather.
    private static let storageKey = "currentLocationWidgetWeatherData"
    private static let temperatureUnitKey = "widgetTemperatureUnit"

    let locationName: String
    let temperature: Int
    let temperatureUnit: String
    let rainChance: Int
    let summary: String
    let symbolName: String
    let isDaytime: Bool
    let updatedAt: Date
    let latitude: Double?
    let longitude: Double?

    init(
        locationName: String,
        temperature: Int,
        temperatureUnit: String,
        rainChance: Int,
        summary: String,
        symbolName: String,
        isDaytime: Bool,
        updatedAt: Date,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) {
        self.locationName = locationName
        self.temperature = temperature
        self.temperatureUnit = temperatureUnit
        self.rainChance = rainChance
        self.summary = summary
        self.symbolName = symbolName
        self.isDaytime = isDaytime
        self.updatedAt = updatedAt
        self.latitude = latitude
        self.longitude = longitude
    }

    static var preferredTemperatureUnit: String {
        UserDefaults(suiteName: appGroupIdentifier)?.string(forKey: temperatureUnitKey) ?? "F"
    }

    static func setPreferredTemperatureUnit(_ unit: String) {
        UserDefaults(suiteName: appGroupIdentifier)?.set(unit, forKey: temperatureUnitKey)
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
    }

    static func load() -> WidgetWeatherData? {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
              let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(WidgetWeatherData.self, from: data)
    }

    func save(reloadWidget: Bool = true) {
        guard let defaults = UserDefaults(suiteName: Self.appGroupIdentifier),
              let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
        if reloadWidget {
            WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
        }
    }
}
