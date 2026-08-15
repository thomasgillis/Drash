import SwiftUI

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
        case "sun.max.fill": return .yellow
        case "moon.stars.fill": return .indigo
        case "cloud.bolt.rain.fill": return Color(red: 0.9, green: 0.32, blue: 0.12)
        case "cloud.snow.fill": return .cyan
        case "cloud.rain.fill", "cloud.sleet.fill": return .blue
        case "cloud.fill", "cloud.fog.fill", "cloud.sun.fill", "cloud.moon.fill": return .gray
        case "wind": return .blue
        default: return .blue
        }
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
        RelativeDateTimeFormatter().localizedString(for: self, relativeTo: Date())
    }
}
