import Foundation
import CoreLocation

enum ForecastModel: String, CaseIterable, Codable, Identifiable, Sendable {
    case nws
    case hrrr

    var id: String { rawValue }

    var shortName: String {
        switch self {
        case .nws: return "NWS"
        case .hrrr: return "HRRR"
        }
    }

    var loadingDescription: String {
        switch self {
        case .nws: return "Loading NWS and HRRR forecasts…"
        case .hrrr: return "Loading HRRR forecast…"
        }
    }

    var forecastAttribution: String {
        switch self {
        case .nws: return "Forecast from the National Weather Service"
        case .hrrr: return "NOAA HRRR forecast via Open-Meteo"
        }
    }
}

enum PrecipitationVolumeRepresentation: String, CaseIterable, Identifiable, Sendable {
    case expected
    case raw

    var id: Self { self }

    var title: String {
        switch self {
        case .expected: return "Expected"
        case .raw: return "Raw volume"
        }
    }

    var chartTitle: String {
        switch self {
        case .expected: return "Expected precipitation"
        case .raw: return "Precipitation volume"
        }
    }
}

enum WeatherLocationKind: String, Codable, Sendable {
    case place
    case park
    case crag
    case summit
}

enum AltitudeUnit: String, CaseIterable, Identifiable, Sendable {
    case feet
    case meters

    var id: String { rawValue }
}

struct Elevation: Codable, Hashable, Sendable {
    enum Source: String, Codable, Sendable {
        case summitCatalog
        case terrainModel
    }

    let meters: Double
    let source: Source

    init(meters: Double, source: Source) {
        self.meters = meters
        self.source = source
    }

    init(feet: Int, source: Source) {
        self.init(meters: Double(feet) * 0.3048, source: source)
    }

    var feet: Int { Int((meters / 0.3048).rounded()) }

    func formatted(for unit: AltitudeUnit) -> String {
        switch unit {
        case .feet:
            return feet.formatted() + " ft"
        case .meters:
            return Int(meters.rounded()).formatted() + " m"
        }
    }
}

struct WeatherLocation: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var state: String?
    var latitude: Double
    var longitude: Double
    var isCurrentLocation: Bool
    var forecastModel: ForecastModel
    var kind: WeatherLocationKind
    var elevation: Elevation?
    var timeZoneIdentifier: String?

    init(
        id: UUID = UUID(),
        name: String,
        state: String? = nil,
        latitude: Double,
        longitude: Double,
        isCurrentLocation: Bool = false,
        forecastModel: ForecastModel = .hrrr,
        kind: WeatherLocationKind = .place,
        elevation: Elevation? = nil,
        timeZoneIdentifier: String? = nil
    ) {
        self.id = id
        self.name = name
        self.state = state
        self.latitude = latitude
        self.longitude = longitude
        self.isCurrentLocation = isCurrentLocation
        self.forecastModel = forecastModel
        self.kind = kind
        self.elevation = elevation
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var displayName: String {
        guard let state, !state.isEmpty else { return name }
        return "\(name), \(state)"
    }

    var timeZone: TimeZone {
        timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case state
        case latitude
        case longitude
        case isCurrentLocation
        case forecastModel
        case kind
        case elevation
        case timeZoneIdentifier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        state = try container.decodeIfPresent(String.self, forKey: .state)
        latitude = try container.decode(Double.self, forKey: .latitude)
        longitude = try container.decode(Double.self, forKey: .longitude)
        isCurrentLocation = try container.decode(Bool.self, forKey: .isCurrentLocation)
        forecastModel = try container.decodeIfPresent(ForecastModel.self, forKey: .forecastModel) ?? .hrrr
        kind = try container.decodeIfPresent(WeatherLocationKind.self, forKey: .kind) ?? .place
        elevation = try container.decodeIfPresent(Elevation.self, forKey: .elevation)
        timeZoneIdentifier = try container.decodeIfPresent(String.self, forKey: .timeZoneIdentifier)
    }
}

struct WeatherSnapshot: Codable, Sendable {
    let location: WeatherLocation
    let updatedAt: Date
    let forecastOffice: String?
    let daily: [ForecastPeriod]
    let hourly: [ForecastPeriod]
    let precipitationAmounts: [PrecipitationAmount]?
    let dailyPrecipitationAmounts: [PrecipitationAmount]?
    let observation: WeatherObservation?
    let observationModel: ForecastModel?
    let hrrrCurrentTemperature: QuantitativeValue?
    let station: ObservationStation?
    let alerts: [WeatherAlert]
    let alertsUnavailable: Bool?
    let hourlyForecastModel: ForecastModel?

    var alertsAreAvailable: Bool { alertsUnavailable != true }
    var effectiveHourlyForecastModel: ForecastModel {
        hourlyForecastModel ?? location.forecastModel
    }
}

struct PrecipitationAmount: Codable, Identifiable, Hashable, Sendable {
    private static let validTimeDateStyle = Date.ISO8601FormatStyle()
    private static let durationExpression = try? NSRegularExpression(
        pattern: #"^P(?:(\d+(?:\.\d+)?)D)?(?:T(?:(\d+(?:\.\d+)?)H)?(?:(\d+(?:\.\d+)?)M)?(?:(\d+(?:\.\d+)?)S)?)?$"#
    )

    let startTime: Date
    let endTime: Date
    let millimeters: Double

    var id: Date { startTime }

    init(startTime: Date, endTime: Date, millimeters: Double) {
        self.startTime = startTime
        self.endTime = endTime
        self.millimeters = max(0, millimeters)
    }

    init?(validTime: String, millimeters: Double?) {
        guard let millimeters,
              millimeters >= 0,
              let separator = validTime.firstIndex(of: "/") else { return nil }

        let startText = String(validTime[..<separator])
        let durationText = String(validTime[validTime.index(after: separator)...])
        guard let startTime = try? Self.validTimeDateStyle.parse(startText),
              let duration = Self.timeInterval(fromISO8601Duration: durationText),
              duration > 0 else { return nil }

        self.startTime = startTime
        self.endTime = startTime.addingTimeInterval(duration)
        self.millimeters = millimeters
    }

    func formattedAmount(for unit: TemperatureUnit) -> String {
        if unit == .celsius {
            if millimeters == 0 { return "0 mm" }
            if millimeters < 0.1 { return "<0.1 mm" }
            if millimeters < 10 { return String(format: "%.1f mm", millimeters) }
            return String(format: "%.0f mm", millimeters)
        }

        let inches = millimeters / 25.4
        if inches == 0 { return "0 in" }
        if inches < 0.01 { return "<0.01 in" }
        if inches < 1 { return String(format: "%.2f in", inches) }
        return String(format: "%.1f in", inches)
    }

    private static func timeInterval(fromISO8601Duration duration: String) -> TimeInterval? {
        guard let expression = durationExpression,
              let match = expression.firstMatch(
                in: duration,
                range: NSRange(duration.startIndex..., in: duration)
              ) else { return nil }

        func value(at index: Int) -> Double {
            let range = match.range(at: index)
            guard range.location != NSNotFound,
                  let swiftRange = Range(range, in: duration) else { return 0 }
            return Double(duration[swiftRange]) ?? 0
        }

        return value(at: 1) * 86_400
            + value(at: 2) * 3_600
            + value(at: 3) * 60
            + value(at: 4)
    }
}

struct ForecastPeriod: Codable, Identifiable, Hashable, Sendable {
    let number: Int
    let name: String
    let startTime: Date
    let endTime: Date
    let isDaytime: Bool
    let temperature: Int
    let temperatureUnit: String
    let probabilityOfPrecipitation: QuantitativeValue?
    let dewpoint: QuantitativeValue?
    let relativeHumidity: QuantitativeValue?
    let windSpeed: String
    let windDirection: String
    let icon: URL?
    let shortForecast: String
    let detailedForecast: String

    var id: Int { number }
    var precipitationChance: Int { Int(probabilityOfPrecipitation?.value ?? 0) }
    var humidity: Int? { relativeHumidity?.value.map(Int.init) }
}

extension PrecipitationVolumeRepresentation {
    func presentedAmounts(
        _ amounts: [PrecipitationAmount],
        probabilityPeriods: [ForecastPeriod]
    ) -> [PrecipitationAmount] {
        guard self == .expected else {
            return amounts.sorted { $0.startTime < $1.startTime }
        }

        return amounts.flatMap { amount -> [PrecipitationAmount] in
            let duration = amount.endTime.timeIntervalSince(amount.startTime)
            guard duration > 0 else { return [] }

            let relevantPeriods = probabilityPeriods.filter {
                $0.endTime > amount.startTime && $0.startTime < amount.endTime
            }
            guard !relevantPeriods.isEmpty else { return [] }

            var boundaries = [amount.startTime, amount.endTime]
            for period in relevantPeriods {
                boundaries.append(max(period.startTime, amount.startTime))
                boundaries.append(min(period.endTime, amount.endTime))
            }
            let sortedBoundaries = Array(Set(boundaries)).sorted()

            return zip(sortedBoundaries, sortedBoundaries.dropFirst()).compactMap {
                segmentStart, segmentEnd in
                let segmentDuration = segmentEnd.timeIntervalSince(segmentStart)
                guard segmentDuration > 0 else { return nil }

                // Prefer hourly probabilities when hourly and day/night periods overlap.
                let overlappingPeriods = relevantPeriods.filter {
                    $0.startTime < segmentEnd && $0.endTime > segmentStart
                }
                guard let probabilityPeriod = overlappingPeriods.min(by: {
                        $0.endTime.timeIntervalSince($0.startTime)
                            < $1.endTime.timeIntervalSince($1.startTime)
                    }) else { return nil }

                let probability = min(max(Double(probabilityPeriod.precipitationChance) / 100, 0), 1)
                return PrecipitationAmount(
                    startTime: segmentStart,
                    endTime: segmentEnd,
                    millimeters: amount.millimeters * segmentDuration / duration * probability
                )
            }
        }
        .sorted { $0.startTime < $1.startTime }
    }
}

struct QuantitativeValue: Codable, Hashable, Sendable {
    let unitCode: String?
    let value: Double?
}

struct WeatherObservation: Codable, Sendable {
    let timestamp: Date
    let textDescription: String
    let icon: URL?
    let temperature: QuantitativeValue
    let dewpoint: QuantitativeValue
    let windDirection: QuantitativeValue
    let windSpeed: QuantitativeValue
    let windGust: QuantitativeValue
    let barometricPressure: QuantitativeValue
    let seaLevelPressure: QuantitativeValue
    let visibility: QuantitativeValue
    let relativeHumidity: QuantitativeValue
    let windChill: QuantitativeValue
    let heatIndex: QuantitativeValue

    var displayDescription: String? {
        let trimmed = textDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct ObservationStation: Codable, Sendable {
    let stationIdentifier: String
    let name: String
    let latitude: Double?
    let longitude: Double?
}

struct WeatherAlert: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let areaDescription: String
    let sent: Date?
    let effective: Date?
    let onset: Date?
    let expires: Date?
    let ends: Date?
    let status: String
    let messageType: String
    let category: String
    let severity: String
    let certainty: String
    let urgency: String
    let event: String
    let senderName: String
    let headline: String?
    let description: String
    let instruction: String?
}

enum TemperatureUnit: String, CaseIterable, Codable, Identifiable {
    case fahrenheit
    case celsius

    var id: String { rawValue }
    var symbol: String { self == .fahrenheit ? "°F" : "°C" }
    var apiUnit: String { self == .fahrenheit ? "us" : "si" }
}

extension ForecastPeriod {
    func temperature(in unit: TemperatureUnit) -> Int {
        let isFahrenheit = temperatureUnit.uppercased() == "F"
        switch (isFahrenheit, unit) {
        case (true, .fahrenheit), (false, .celsius): return temperature
        case (true, .celsius): return Int(((Double(temperature) - 32) * 5 / 9).rounded())
        case (false, .fahrenheit): return Int((Double(temperature) * 9 / 5 + 32).rounded())
        }
    }
}

extension QuantitativeValue {
    var celsius: Double? { value }

    func temperature(in unit: TemperatureUnit) -> Int? {
        guard let value else { return nil }
        let celsiusValue: Double
        if unitCode?.contains("degF") == true {
            celsiusValue = (value - 32) * 5 / 9
        } else {
            celsiusValue = value
        }
        return Int((unit == .celsius ? celsiusValue : celsiusValue * 9 / 5 + 32).rounded())
    }

    var metersPerSecond: Double? { value }
    var milesPerHour: Double? { value.map { $0 * 2.236_936 } }
    var hectopascals: Double? { value.map { $0 / 100 } }
    var miles: Double? { value.map { $0 / 1_609.344 } }
}
