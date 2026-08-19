import SwiftUI
import UIKit

extension ForecastPeriod {
    var symbolName: String {
        let text = shortForecast.lowercased()
        if text.contains("thunder") { return "cloud.bolt.rain.fill" }
        if text.contains("snow") || text.contains("flurr") { return "cloud.snow.fill" }
        if text.contains("sleet") || text.contains("ice") { return "cloud.sleet.fill" }
        if text.contains("rain") || text.contains("shower") || text.contains("drizzle") { return "cloud.rain.fill" }
        if text.contains("fog") || text.contains("haze") || text.contains("smoke") { return "cloud.fog.fill" }
        if text.contains("wind") { return "wind" }
        if text.contains("partly") || text.contains("mostly sunny") || text.contains("mostly clear") {
            return isDaytime ? "cloud.sun.fill" : "cloud.moon.fill"
        }
        if text.contains("cloud") || text.contains("overcast") { return "cloud.fill" }
        return isDaytime ? "sun.max.fill" : "moon.stars.fill"
    }

    var weatherTint: Color {
        switch symbolName {
        case "sun.max.fill": return WeatherIconPalette.sun
        case "moon.stars.fill": return WeatherIconPalette.moon
        case "cloud.bolt.rain.fill", "cloud.snow.fill", "cloud.rain.fill", "cloud.sleet.fill":
            return WeatherIconPalette.cloud
        case "cloud.fill", "cloud.fog.fill", "cloud.sun.fill", "cloud.moon.fill": return WeatherIconPalette.cloud
        case "wind": return WeatherIconPalette.wind
        default: return WeatherIconPalette.rain
        }
    }

    var weatherSecondaryTint: Color {
        switch symbolName {
        case "moon.stars.fill": return WeatherIconPalette.star
        case "cloud.bolt.rain.fill": return WeatherIconPalette.lightning
        case "cloud.snow.fill": return WeatherIconPalette.snow
        case "cloud.rain.fill", "cloud.sleet.fill": return WeatherIconPalette.rain
        case "cloud.sun.fill": return WeatherIconPalette.sun
        case "cloud.moon.fill": return WeatherIconPalette.moon
        case "cloud.fog.fill": return WeatherIconPalette.fog
        default: return weatherTint
        }
    }

    var weatherTertiaryTint: Color {
        symbolName == "cloud.bolt.rain.fill" ? WeatherIconPalette.rain : weatherSecondaryTint
    }
}

private enum WeatherIconPalette {
    private static let lightAccent = UIColor(red: 0.16, green: 0.46, blue: 0.64, alpha: 1)
    private static let lightCloud = UIColor(red: 0.4, green: 0.47, blue: 0.53, alpha: 1)

    static let sun = adaptive(
        light: UIColor(red: 0.82, green: 0.61, blue: 0.18, alpha: 1),
        dark: UIColor(red: 1, green: 0.78, blue: 0.22, alpha: 1)
    )
    static let moon = adaptive(
        light: lightAccent,
        dark: UIColor(red: 0.72, green: 0.68, blue: 1, alpha: 1)
    )
    static let star = adaptive(
        light: lightAccent,
        dark: UIColor(red: 1, green: 0.82, blue: 0.35, alpha: 1)
    )
    static let lightning = adaptive(
        light: lightAccent,
        dark: UIColor(red: 1, green: 0.76, blue: 0.16, alpha: 1)
    )
    static let snow = adaptive(
        light: lightAccent,
        dark: UIColor(red: 0.42, green: 0.84, blue: 1, alpha: 1)
    )
    static let rain = adaptive(
        light: lightAccent,
        dark: UIColor(red: 0.34, green: 0.72, blue: 1, alpha: 1)
    )
    static let cloud = adaptive(
        light: lightCloud,
        dark: UIColor(red: 0.72, green: 0.78, blue: 0.84, alpha: 1)
    )
    static let fog = adaptive(
        light: lightCloud,
        dark: UIColor(red: 0.52, green: 0.61, blue: 0.69, alpha: 1)
    )
    static let wind = adaptive(
        light: lightAccent,
        dark: UIColor(red: 0.38, green: 0.78, blue: 0.92, alpha: 1)
    )

    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
}

extension WeatherAlert {
    var severityColor: Color {
        switch severity.lowercased() {
        case "extreme": return .purple
        case "severe": return .red
        case "moderate": return .orange
        default: return .yellow
        }
    }

    var symbolName: String {
        severity.lowercased() == "extreme" ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill"
    }
}

extension Date {
    var relativeUpdateDescription: String {
        relativeUpdateDescription(relativeTo: Date())
    }

    func relativeUpdateDescription(relativeTo referenceDate: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: self, relativeTo: referenceDate)
    }
}
