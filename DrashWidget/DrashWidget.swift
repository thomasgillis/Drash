import CoreLocation
import Foundation
import SwiftUI
import WidgetKit

@main
struct DrashWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: WidgetWeatherData.widgetKind,
            provider: DrashTimelineProvider()
        ) { entry in
            DrashWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    WidgetBackground(isDaytime: entry.weather?.isDaytime ?? true)
                }
        }
        .configurationDisplayName("Current Weather")
        .description("See the current temperature and next-hour rain chance.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryInline,
            .accessoryCircular,
            .accessoryRectangular
        ])
    }
}

private struct DrashTimelineEntry: TimelineEntry {
    let date: Date
    let weather: WidgetWeatherData?
}

private struct DrashTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> DrashTimelineEntry {
        DrashTimelineEntry(date: .now, weather: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (DrashTimelineEntry) -> Void) {
        completion(DrashTimelineEntry(
            date: .now,
            weather: context.isPreview ? .preview : WidgetWeatherData.load()
        ))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DrashTimelineEntry>) -> Void) {
        DispatchQueue.main.async {
            WidgetLocationProvider.shared.requestLocation { location in
                Task {
                    var weather = WidgetWeatherData.load()
                    if let location,
                       let refreshed = try? await WidgetWeatherService.weather(
                        at: location,
                        temperatureUnit: WidgetWeatherData.preferredTemperatureUnit
                       ) {
                        refreshed.save(reloadWidget: false)
                        weather = refreshed
                    }

                    let now = Date()
                    completion(Timeline(
                        entries: [DrashTimelineEntry(date: now, weather: weather)],
                        policy: .after(now.addingTimeInterval(15 * 60))
                    ))
                }
            }
        }
    }
}

private struct DrashWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: DrashTimelineEntry

    var body: some View {
        if let weather = entry.weather {
            switch family {
            case .systemMedium:
                mediumView(weather)
            case .accessoryInline:
                inlineView(weather)
            case .accessoryCircular:
                circularView(weather)
            case .accessoryRectangular:
                accessoryView(weather)
            default:
                smallView(weather)
            }
        } else {
            emptyView
        }
    }

    private func smallView(_ weather: WidgetWeatherData) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(weather.locationName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                weatherIcon(weather, size: 25)
            }

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(weather.temperature)°")
                    .font(.system(size: 46, weight: .medium, design: .rounded))
                    .minimumScaleFactor(0.7)
                Text(weather.temperatureUnit)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Label("\(weather.rainChance)% next hour", systemImage: "drop.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.blue)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            updatedText(weather)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription(weather))
    }

    private func mediumView(_ weather: WidgetWeatherData) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(weather.locationName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                HStack(alignment: .center, spacing: 8) {
                    weatherIcon(weather, size: 36)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(weather.temperature)°")
                            .font(.system(size: 48, weight: .medium, design: .rounded))
                        Text(weather.temperatureUnit)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(weather.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            VStack(alignment: .leading, spacing: 3) {
                Label("RAIN", systemImage: "drop.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.blue)
                Text("\(weather.rainChance)%")
                    .font(.system(size: 38, weight: .semibold, design: .rounded))
                Text("next hour")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 2)
                updatedText(weather)
            }
            .frame(width: 104, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription(weather))
    }

    private func accessoryView(_ weather: WidgetWeatherData) -> some View {
        VStack(alignment: .leading, spacing: -5) {
            HStack(spacing: 5) {
                Text(weather.locationName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)

                Spacer(minLength: 4)

                lockScreenWeatherIcon(weather, size: 14)
            }

            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text("\(weather.temperature)°")
                    .font(.system(size: 44, weight: .regular, design: .default))
                    .fixedSize(horizontal: true, vertical: false)

                Text(weather.temperatureUnit)
                    .font(.system(size: 10, weight: .regular, design: .default))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 6)

                VStack(alignment: .trailing, spacing: -1) {
                    HStack(spacing: 3) {
                        Image(systemName: "drop.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text("\(weather.rainChance)%")
                            .font(.system(size: 19, weight: .semibold, design: .rounded))
                    }
                    .widgetAccentable()

                    Text("NEXT HOUR")
                        .font(.system(size: 8, weight: .semibold))
                        .tracking(0.35)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription(weather))
    }

    private func circularView(_ weather: WidgetWeatherData) -> some View {
        Gauge(value: Double(weather.rainChance), in: 0...100) {
            Text("Rain")
        } currentValueLabel: {
            VStack(spacing: -2) {
                Image(systemName: weather.symbolName)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 10, weight: .semibold))
                Text("\(weather.temperature)°")
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                HStack(spacing: 1) {
                    Image(systemName: "drop.fill")
                    Text("\(weather.rainChance)%")
                }
                .font(.system(size: 8, weight: .semibold))
            }
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(.accentColor)
        .widgetAccentable()
        .accessibilityLabel(accessibilityDescription(weather))
    }

    private func inlineView(_ weather: WidgetWeatherData) -> some View {
        HStack(spacing: 5) {
            Image(systemName: weather.symbolName)
                .symbolRenderingMode(.hierarchical)
            Text("\(weather.temperature)°  ·  \(weather.rainChance)% rain")
        }
        .font(.system(size: 16, weight: .semibold))
        .widgetAccentable()
        .accessibilityLabel(accessibilityDescription(weather))
    }

    @ViewBuilder
    private var emptyView: some View {
        switch family {
        case .accessoryInline:
            Label("Open Drash for local weather", systemImage: "location.slash")
        case .accessoryCircular:
            Image(systemName: "location.slash")
                .font(.title2)
                .widgetAccentable()
                .accessibilityLabel("Open Drash for local weather")
        case .accessoryRectangular:
            HStack(spacing: 8) {
                Image(systemName: "location.slash.circle.fill")
                    .font(.title2)
                    .widgetAccentable()
                VStack(alignment: .leading, spacing: 1) {
                    Text("Local weather")
                        .font(.caption.weight(.semibold))
                    Text("Open Drash to load")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        default:
            VStack(alignment: .leading, spacing: 7) {
                Image(systemName: "cloud.sun.fill")
                    .font(.title2)
                Text("Open Drash")
                    .font(.headline)
                Text("Load a forecast to start the widget.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    private func weatherIcon(_ weather: WidgetWeatherData, size: CGFloat) -> some View {
        Image(systemName: weather.symbolName)
            .symbolRenderingMode(.palette)
            .foregroundStyle(.primary, Color.blue, Color.yellow)
            .font(.system(size: size))
            .accessibilityHidden(true)
    }

    private func lockScreenWeatherIcon(_ weather: WidgetWeatherData, size: CGFloat) -> some View {
        Image(systemName: weather.symbolName)
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: size, weight: .semibold))
            .widgetAccentable()
            .accessibilityHidden(true)
    }

    private func updatedText(_ weather: WidgetWeatherData) -> some View {
        HStack(spacing: 3) {
            Text("Updated")
            Text(weather.updatedAt, style: .relative)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private func accessibilityDescription(_ weather: WidgetWeatherData) -> String {
        let unitName = weather.temperatureUnit == "F" ? "Fahrenheit" : "Celsius"
        return "\(weather.locationName), \(weather.temperature) degrees \(unitName), \(weather.rainChance) percent chance of rain in the next hour, \(weather.summary)"
    }
}

private struct WidgetBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    let isDaytime: Bool

    var body: some View {
        LinearGradient(
            colors: colors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var colors: [Color] {
        if colorScheme == .dark {
            return isDaytime
                ? [Color(red: 0.03, green: 0.10, blue: 0.14), Color(red: 0.06, green: 0.19, blue: 0.26)]
                : [Color(red: 0.03, green: 0.04, blue: 0.09), Color(red: 0.08, green: 0.10, blue: 0.19)]
        }
        return isDaytime
            ? [Color(red: 0.94, green: 0.98, blue: 1), Color(red: 0.73, green: 0.89, blue: 0.97)]
            : [Color(red: 0.91, green: 0.92, blue: 0.99), Color(red: 0.78, green: 0.83, blue: 0.96)]
    }
}

private extension WidgetWeatherData {
    static let preview = WidgetWeatherData(
        locationName: "Boulder, CO",
        temperature: 72,
        temperatureUnit: "F",
        rainChance: 20,
        summary: "Partly Sunny",
        symbolName: "cloud.sun.fill",
        isDaytime: true,
        updatedAt: .now
    )
}

private final class WidgetLocationProvider: NSObject, CLLocationManagerDelegate {
    static let shared = WidgetLocationProvider()

    private let manager = CLLocationManager()
    private var completion: ((CLLocation?) -> Void)?
    private var timeout: DispatchWorkItem?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func requestLocation(completion: @escaping (CLLocation?) -> Void) {
        guard manager.isAuthorizedForWidgetUpdates else {
            completion(nil)
            return
        }

        finish(with: nil)
        self.completion = completion
        manager.requestLocation()

        let timeout = DispatchWorkItem { [weak self] in
            self?.finish(with: nil)
        }
        self.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finish(with: locations.last)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(with: nil)
    }

    private func finish(with location: CLLocation?) {
        timeout?.cancel()
        timeout = nil
        let completion = completion
        self.completion = nil
        completion?(location)
    }
}

private enum WidgetWeatherService {
    static func weather(
        at location: CLLocation,
        temperatureUnit: String
    ) async throws -> WidgetWeatherData {
        guard var components = URLComponents(string: "https://api.open-meteo.com/v1/gfs") else {
            throw WidgetWeatherError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", location.coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", location.coordinate.longitude)),
            URLQueryItem(name: "models", value: "ncep_hrrr_conus"),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "hourly", value: "precipitation_probability"),
            URLQueryItem(
                name: "temperature_unit",
                value: temperatureUnit == "C" ? "celsius" : "fahrenheit"
            ),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_hours", value: "2")
        ]
        guard let url = components.url else { throw WidgetWeatherError.invalidResponse }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Drash/1.0 (weather widget)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw WidgetWeatherError.invalidResponse
        }

        let decoded = try JSONDecoder().decode(WidgetForecastResponse.self, from: data)
        guard let temperature = decoded.current.temperature else {
            throw WidgetWeatherError.invalidResponse
        }
        let isDaytime = decoded.current.isDay == 1
        let condition = condition(
            for: decoded.current.weatherCode ?? 3,
            isDaytime: isDaytime
        )
        let rainProbability = decoded.hourly.precipitationProbability.compactMap { $0 }.first ?? 0
        let rainChance = min(100, max(0, Int(rainProbability.rounded())))

        return WidgetWeatherData(
            locationName: locationName(near: location),
            temperature: Int(temperature.rounded()),
            temperatureUnit: temperatureUnit,
            rainChance: rainChance,
            summary: condition.summary,
            symbolName: condition.symbolName,
            isDaytime: isDaytime,
            updatedAt: .now,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude
        )
    }

    private static func locationName(near location: CLLocation) -> String {
        guard let cached = WidgetWeatherData.load(),
              let latitude = cached.latitude,
              let longitude = cached.longitude else { return "Current location" }
        let cachedLocation = CLLocation(latitude: latitude, longitude: longitude)
        return location.distance(from: cachedLocation) < 20_000
            ? cached.locationName
            : "Current location"
    }

    private static func condition(for code: Int, isDaytime: Bool) -> (summary: String, symbolName: String) {
        switch code {
        case 0:
            return (isDaytime ? "Clear" : "Clear", isDaytime ? "sun.max.fill" : "moon.stars.fill")
        case 1:
            return (isDaytime ? "Mostly Sunny" : "Mostly Clear", isDaytime ? "sun.max.fill" : "moon.stars.fill")
        case 2:
            return ("Partly Cloudy", isDaytime ? "cloud.sun.fill" : "cloud.moon.fill")
        case 3:
            return ("Cloudy", "cloud.fill")
        case 45, 48:
            return ("Foggy", "cloud.fog.fill")
        case 51, 53, 55:
            return ("Drizzle", "cloud.drizzle.fill")
        case 56, 57, 66, 67:
            return ("Freezing Rain", "cloud.sleet.fill")
        case 61, 63, 65, 80, 81, 82:
            return ("Rain", "cloud.rain.fill")
        case 71, 73, 75, 77, 85, 86:
            return ("Snow", "cloud.snow.fill")
        case 95, 96, 99:
            return ("Thunderstorms", "cloud.bolt.rain.fill")
        default:
            return ("Current conditions", isDaytime ? "cloud.sun.fill" : "cloud.moon.fill")
        }
    }
}

private enum WidgetWeatherError: Error {
    case invalidResponse
}

private struct WidgetForecastResponse: Decodable {
    let current: WidgetCurrentConditions
    let hourly: WidgetHourlyForecast
}

private struct WidgetCurrentConditions: Decodable {
    let temperature: Double?
    let weatherCode: Int?
    let isDay: Int?

    enum CodingKeys: String, CodingKey {
        case temperature = "temperature_2m"
        case weatherCode = "weather_code"
        case isDay = "is_day"
    }
}

private struct WidgetHourlyForecast: Decodable {
    let precipitationProbability: [Double?]

    enum CodingKeys: String, CodingKey {
        case precipitationProbability = "precipitation_probability"
    }
}
