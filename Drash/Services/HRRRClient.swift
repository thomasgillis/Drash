import Foundation

enum HRRRServiceError: LocalizedError {
    case invalidURL
    case invalidResponse
    case unavailable(String?)
    case server(status: Int)
    case rateLimited(retryAt: Date)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The HRRR request could not be created."
        case .invalidResponse:
            return "The HRRR response was incomplete."
        case .unavailable(let reason):
            if let reason, !reason.isEmpty {
                return "HRRR is unavailable for this place. \(reason)"
            }
            return "HRRR is available only within its continental U.S. forecast domain."
        case .server(let status):
            return "The HRRR forecast provider returned an error (\(status))."
        case .rateLimited(let retryAt):
            return "The HRRR forecast provider is temporarily rate-limited. Drash will try again after \(retryAt.formatted(date: .omitted, time: .shortened))."
        }
    }
}

struct HRRRForecastData: Sendable {
    let updatedAt: Date
    let daily: [ForecastPeriod]
    let hourly: [ForecastPeriod]
    let precipitationAmounts: [PrecipitationAmount]
    let observation: Observation?
    let elevation: Elevation?
}

actor WeatherClient {
    static let shared = WeatherClient()

    private let nwsClient: NWSClient
    private let hrrrClient: HRRRClient

    init(nwsClient: NWSClient = .shared, hrrrClient: HRRRClient = .shared) {
        self.nwsClient = nwsClient
        self.hrrrClient = hrrrClient
    }

    func weather(
        for location: WeatherLocation,
        unit: TemperatureUnit,
        hourlyModel: ForecastModel,
        forceHRRRRetry: Bool = false,
        onCoreForecast: @escaping @Sendable (WeatherSnapshot) async -> Void
    ) async throws -> WeatherSnapshot {
        let needsHRRR = location.forecastModel == .hrrr || hourlyModel == .hrrr
        let needsNWSDaily = location.forecastModel == .nws
        let needsNWSHourly = hourlyModel == .nws

        async let hrrrResult: HRRRForecastData? = needsHRRR
            ? hrrrClient.forecast(
                for: location,
                unit: unit,
                forceProviderRetry: forceHRRRRetry
            )
            : nil
        async let nwsDailyResult: NWSDailyForecast? = needsNWSDaily
            ? nwsClient.dailyForecast(for: location, unit: unit)
            : nil
        async let nwsHourlyResult: NWSHourlyForecast? = needsNWSHourly
            ? nwsClient.hourlyForecast(for: location, unit: unit)
            : nil
        let (hrrr, nwsDaily, nwsHourly) = try await (
            hrrrResult,
            nwsDailyResult,
            nwsHourlyResult
        )

        let daily = location.forecastModel == .hrrr ? hrrr?.daily : nwsDaily?.periods
        let hourly = hourlyModel == .hrrr ? hrrr?.hourly : nwsHourly?.periods
        guard let daily, let hourly, !daily.isEmpty, !hourly.isEmpty else {
            throw HRRRServiceError.invalidResponse
        }

        var resolvedLocation = nwsDaily?.location ?? nwsHourly?.location ?? location
        resolvedLocation.elevation = resolvedLocation.elevation
            ?? hrrr?.elevation
            ?? nwsHourly?.elevation

        let core = WeatherSnapshot(
            location: resolvedLocation,
            updatedAt: hourlyModel == .hrrr
                ? hrrr?.updatedAt ?? Date()
                : nwsHourly?.updatedAt ?? Date(),
            forecastOffice: nwsDaily?.forecastOffice ?? nwsHourly?.forecastOffice,
            daily: daily,
            hourly: hourly,
            precipitationAmounts: hourlyModel == .hrrr
                ? hrrr?.precipitationAmounts
                : nwsHourly?.precipitationAmounts,
            observation: hourlyModel == .hrrr ? hrrr?.observation : nil,
            observationModel: hourlyModel,
            hrrrCurrentTemperature: hourlyModel == .hrrr
                ? hrrr?.observation?.temperature
                : nil,
            station: nil,
            alerts: [],
            alertsUnavailable: nil,
            hourlyForecastModel: hourlyModel
        )

        try Task.checkCancellation()
        await onCoreForecast(core)
        try Task.checkCancellation()
        return try await enrichWithNWSContext(core, hourlyModel: hourlyModel)
    }

    private func enrichWithNWSContext(
        _ core: WeatherSnapshot,
        hourlyModel: ForecastModel
    ) async throws -> WeatherSnapshot {
        do {
            let context = try await nwsClient.weatherContext(
                for: core.location,
                includeStationObservation: hourlyModel == .nws && core.location.kind != .summit
            )
            try Task.checkCancellation()
            var resolvedLocation = context.location
            resolvedLocation.elevation = resolvedLocation.elevation ?? core.location.elevation

            return WeatherSnapshot(
                location: resolvedLocation,
                updatedAt: hourlyModel == .nws
                    ? context.observation?.timestamp ?? core.updatedAt
                    : core.updatedAt,
                forecastOffice: context.forecastOffice ?? core.forecastOffice,
                daily: core.daily,
                hourly: core.hourly,
                precipitationAmounts: core.precipitationAmounts,
                observation: hourlyModel == .nws
                    ? context.observation ?? core.observation
                    : core.observation,
                observationModel: hourlyModel,
                hrrrCurrentTemperature: core.hrrrCurrentTemperature,
                station: hourlyModel == .nws ? context.station : nil,
                alerts: context.alerts,
                alertsUnavailable: context.alertsUnavailable,
                hourlyForecastModel: core.hourlyForecastModel
            )
        } catch {
            try Task.checkCancellation()
            return WeatherSnapshot(
                location: core.location,
                updatedAt: core.updatedAt,
                forecastOffice: core.forecastOffice,
                daily: core.daily,
                hourly: core.hourly,
                precipitationAmounts: core.precipitationAmounts,
                observation: core.observation,
                observationModel: hourlyModel,
                hrrrCurrentTemperature: core.hrrrCurrentTemperature,
                station: nil,
                alerts: [],
                alertsUnavailable: true,
                hourlyForecastModel: core.hourlyForecastModel
            )
        }
    }
}

actor HRRRClient {
    static let shared = HRRRClient()

    private let session: URLSession
    private let defaults: UserDefaults
    private let decoder = JSONDecoder()
    private var dateFormatters: [String: DateFormatter] = [:]
    private var requestDates: [Date]
    private var providerCooldownUntil: Date?
    private let requestWindow: TimeInterval = 60 * 60
    // A Drash request currently costs about 2.5 Open-Meteo API calls because it
    // asks for 25 variables. This cap keeps one app installation below roughly
    // 250 weighted calls per hour, far under the provider's 5,000-call limit.
    private let maximumRequestsPerWindow = 100

    private enum RateLimitKeys {
        static let requestDates = "hrrrRequestDates"
        static let providerCooldownUntil = "hrrrProviderCooldownUntil"
    }

    init(session: URLSession = .shared, defaults: UserDefaults = .standard) {
        self.session = session
        self.defaults = defaults
        requestDates = defaults.array(forKey: RateLimitKeys.requestDates)?.compactMap {
            ($0 as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        } ?? []
        let cooldownTimestamp = defaults.double(forKey: RateLimitKeys.providerCooldownUntil)
        providerCooldownUntil = cooldownTimestamp > 0
            ? Date(timeIntervalSince1970: cooldownTimestamp)
            : nil
    }

    func forecast(
        for requestedLocation: WeatherLocation,
        unit: TemperatureUnit,
        forceProviderRetry: Bool = false
    ) async throws -> HRRRForecastData {
        let url = try forecastURL(for: requestedLocation, unit: unit)
        let response = try await fetch(url, forceProviderRetry: forceProviderRetry)
        let timeZone = TimeZone(identifier: response.timezone) ?? .current
        let hourly = hourlyPeriods(from: response, unit: unit, timeZone: timeZone)
        guard !hourly.isEmpty else { throw HRRRServiceError.invalidResponse }

        return HRRRForecastData(
            updatedAt: response.current.flatMap { date(from: $0.time, timeZone: timeZone) }
                ?? hourly[0].startTime,
            daily: dailyPeriods(from: response, unit: unit, timeZone: timeZone),
            hourly: hourly,
            precipitationAmounts: precipitationAmounts(from: response, timeZone: timeZone),
            observation: response.current.flatMap {
                observation(from: $0, unit: unit, timeZone: timeZone)
            },
            elevation: requestedLocation.elevation
                ?? response.elevation.map { Elevation(meters: $0, source: .terrainModel) }
        )
    }

    private func forecastURL(for location: WeatherLocation, unit: TemperatureUnit) throws -> URL {
        guard var components = URLComponents(string: "https://api.open-meteo.com/v1/gfs") else {
            throw HRRRServiceError.invalidURL
        }

        var queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", location.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", location.longitude)),
            URLQueryItem(name: "models", value: "ncep_hrrr_conus"),
            URLQueryItem(
                name: "hourly",
                value: [
                    "temperature_2m", "relative_humidity_2m", "dew_point_2m",
                    "precipitation", "precipitation_probability", "weather_code",
                    "wind_speed_10m", "wind_direction_10m", "is_day"
                ].joined(separator: ",")
            ),
            URLQueryItem(
                name: "daily",
                value: [
                    "weather_code", "temperature_2m_max", "temperature_2m_min",
                    "precipitation_probability_max", "wind_speed_10m_max",
                    "wind_direction_10m_dominant"
                ].joined(separator: ",")
            ),
            URLQueryItem(
                name: "current",
                value: [
                    "temperature_2m", "relative_humidity_2m", "dew_point_2m",
                    "weather_code", "wind_speed_10m", "wind_direction_10m",
                    "wind_gusts_10m", "visibility", "surface_pressure", "is_day"
                ].joined(separator: ",")
            ),
            URLQueryItem(name: "temperature_unit", value: unit == .fahrenheit ? "fahrenheit" : "celsius"),
            URLQueryItem(name: "wind_speed_unit", value: "mph"),
            URLQueryItem(name: "precipitation_unit", value: "mm"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_hours", value: "48")
        ]
        if let elevation = location.elevation?.meters {
            queryItems.append(
                URLQueryItem(name: "elevation", value: String(format: "%.1f", elevation))
            )
        }
        components.queryItems = queryItems

        guard let url = components.url else { throw HRRRServiceError.invalidURL }
        return url
    }

    private func fetch(_ url: URL, forceProviderRetry: Bool) async throws -> HRRRResponse {
        let requestedAt = Date()
        try registerRequest(at: requestedAt, forceProviderRetry: forceProviderRetry)

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Drash/1.0 (personal iOS weather app)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw HRRRServiceError.invalidResponse
        }
        if http.statusCode == 429 {
            let retryAt = retryDate(from: http, relativeTo: requestedAt)
            providerCooldownUntil = max(providerCooldownUntil ?? .distantPast, retryAt)
            persistRateLimitState()
            throw HRRRServiceError.rateLimited(retryAt: retryAt)
        }
        guard (200...299).contains(http.statusCode) else {
            let reason = try? decoder.decode(HRRRErrorResponse.self, from: data).reason
            if http.statusCode == 400 {
                throw HRRRServiceError.unavailable(reason)
            }
            throw HRRRServiceError.server(status: http.statusCode)
        }

        do {
            return try decoder.decode(HRRRResponse.self, from: data)
        } catch {
            throw HRRRServiceError.invalidResponse
        }
    }

    private func registerRequest(at date: Date, forceProviderRetry: Bool) throws {
        if !forceProviderRetry,
           let providerCooldownUntil,
           date < providerCooldownUntil {
            throw HRRRServiceError.rateLimited(retryAt: providerCooldownUntil)
        }
        if providerCooldownUntil != nil {
            providerCooldownUntil = nil
            persistRateLimitState()
        }

        let windowStart = date.addingTimeInterval(-requestWindow)
        requestDates.removeAll { $0 <= windowStart }
        guard requestDates.count < maximumRequestsPerWindow else {
            let retryAt = requestDates[0].addingTimeInterval(requestWindow)
            throw HRRRServiceError.rateLimited(retryAt: retryAt)
        }
        // Reserve the request before suspending for URLSession. Actor methods
        // are reentrant, so recording it here also covers concurrent callers.
        requestDates.append(date)
        persistRateLimitState()
    }

    private func persistRateLimitState() {
        defaults.set(
            requestDates.map(\.timeIntervalSince1970),
            forKey: RateLimitKeys.requestDates
        )
        if let providerCooldownUntil {
            defaults.set(
                providerCooldownUntil.timeIntervalSince1970,
                forKey: RateLimitKeys.providerCooldownUntil
            )
        } else {
            defaults.removeObject(forKey: RateLimitKeys.providerCooldownUntil)
        }
    }

    private func retryDate(from response: HTTPURLResponse, relativeTo date: Date) -> Date {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else {
            return date.addingTimeInterval(requestWindow)
        }
        if let seconds = TimeInterval(value), seconds >= 0 {
            return date.addingTimeInterval(seconds)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: value) ?? date.addingTimeInterval(requestWindow)
    }

    private func hourlyPeriods(
        from response: HRRRResponse,
        unit: TemperatureUnit,
        timeZone: TimeZone
    ) -> [ForecastPeriod] {
        response.hourly.time.indices.compactMap { index in
            guard let startTime = date(from: response.hourly.time[index], timeZone: timeZone),
                  let temperature = response.hourly.temperature.compactValue(at: index),
                  let weatherCode = response.hourly.weatherCode.compactValue(at: index) else { return nil }

            let endTime = response.hourly.time.value(at: index + 1)
                .flatMap { date(from: $0, timeZone: timeZone) }
                ?? startTime.addingTimeInterval(3_600)
            let windSpeed = response.hourly.windSpeed.compactValue(at: index) ?? 0
            let windDirection = response.hourly.windDirection.compactValue(at: index) ?? 0
            let isDaytime = response.hourly.isDay.compactValue(at: index) == 1
            let condition = weatherDescription(code: Int(weatherCode), isDaytime: isDaytime)

            return ForecastPeriod(
                number: index + 1,
                name: startTime.formatted(.dateTime.weekday(.abbreviated).hour()),
                startTime: startTime,
                endTime: endTime,
                isDaytime: isDaytime,
                temperature: Int(temperature.rounded()),
                temperatureUnit: unit == .fahrenheit ? "F" : "C",
                probabilityOfPrecipitation: QuantitativeValue(
                    unitCode: "wmoUnit:percent",
                    value: response.hourly.precipitationProbability.compactValue(at: index)
                ),
                dewpoint: QuantitativeValue(
                    unitCode: unit == .fahrenheit ? "wmoUnit:degF" : "wmoUnit:degC",
                    value: response.hourly.dewPoint.compactValue(at: index)
                ),
                relativeHumidity: QuantitativeValue(
                    unitCode: "wmoUnit:percent",
                    value: response.hourly.relativeHumidity.compactValue(at: index)
                ),
                windSpeed: formattedWind(speed: windSpeed, direction: windDirection),
                windDirection: compassDirection(windDirection),
                icon: nil,
                shortForecast: condition,
                detailedForecast: "HRRR forecasts \(condition.lowercased()) with winds \(formattedWind(speed: windSpeed, direction: windDirection))."
            )
        }
    }

    private func dailyPeriods(
        from response: HRRRResponse,
        unit: TemperatureUnit,
        timeZone: TimeZone
    ) -> [ForecastPeriod] {
        guard let daily = response.daily else { return [] }
        var periods: [ForecastPeriod] = []
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        for index in daily.time.indices {
            guard let startOfDay = date(from: daily.time[index], timeZone: timeZone, dateOnly: true),
                  let weatherCode = daily.weatherCode.compactValue(at: index),
                  let high = daily.temperatureMax.compactValue(at: index),
                  let low = daily.temperatureMin.compactValue(at: index) else { continue }

            let dayStart = calendar.date(byAdding: .hour, value: 6, to: startOfDay) ?? startOfDay
            let nightStart = calendar.date(byAdding: .hour, value: 18, to: startOfDay) ?? startOfDay
            let nextMorning = calendar.date(byAdding: .day, value: 1, to: dayStart)
                ?? nightStart.addingTimeInterval(12 * 3_600)
            let dayName = calendar.isDateInToday(startOfDay)
                ? "Today"
                : startOfDay.formatted(.dateTime.weekday(.wide))
            let condition = weatherDescription(code: Int(weatherCode), isDaytime: true)
            let windSpeed = daily.windSpeedMax.compactValue(at: index) ?? 0
            let windDirection = daily.windDirection.compactValue(at: index) ?? 0
            let precipitationChance = daily.precipitationProbabilityMax.compactValue(at: index)
            let wind = formattedWind(speed: windSpeed, direction: windDirection)
            let nighttimeCondition = weatherDescription(code: Int(weatherCode), isDaytime: false)

            periods.append(ForecastPeriod(
                number: 10_000 + index * 2,
                name: dayName,
                startTime: dayStart,
                endTime: nightStart,
                isDaytime: true,
                temperature: Int(high.rounded()),
                temperatureUnit: unit == .fahrenheit ? "F" : "C",
                probabilityOfPrecipitation: QuantitativeValue(unitCode: "wmoUnit:percent", value: precipitationChance),
                dewpoint: nil,
                relativeHumidity: nil,
                windSpeed: wind,
                windDirection: compassDirection(windDirection),
                icon: nil,
                shortForecast: condition,
                detailedForecast: "HRRR forecasts \(condition.lowercased()) with a high near \(Int(high.rounded()))° and winds \(wind)."
            ))
            periods.append(ForecastPeriod(
                number: 10_001 + index * 2,
                name: dayName == "Today" ? "Tonight" : "\(dayName) Night",
                startTime: nightStart,
                endTime: nextMorning,
                isDaytime: false,
                temperature: Int(low.rounded()),
                temperatureUnit: unit == .fahrenheit ? "F" : "C",
                probabilityOfPrecipitation: QuantitativeValue(unitCode: "wmoUnit:percent", value: precipitationChance),
                dewpoint: nil,
                relativeHumidity: nil,
                windSpeed: wind,
                windDirection: compassDirection(windDirection),
                icon: nil,
                shortForecast: nighttimeCondition,
                detailedForecast: "HRRR forecasts \(nighttimeCondition.lowercased()) with a low near \(Int(low.rounded()))° and winds \(wind)."
            ))
        }

        return periods
    }

    private func precipitationAmounts(from response: HRRRResponse, timeZone: TimeZone) -> [PrecipitationAmount] {
        response.hourly.time.indices.compactMap { index in
            guard let startTime = date(from: response.hourly.time[index], timeZone: timeZone),
                  let millimeters = response.hourly.precipitation.compactValue(at: index) else { return nil }
            let endTime = response.hourly.time.value(at: index + 1)
                .flatMap { date(from: $0, timeZone: timeZone) }
                ?? startTime.addingTimeInterval(3_600)
            return PrecipitationAmount(startTime: startTime, endTime: endTime, millimeters: millimeters)
        }
    }

    private func observation(
        from current: HRRRCurrent,
        unit: TemperatureUnit,
        timeZone: TimeZone
    ) -> Observation? {
        guard let timestamp = date(from: current.time, timeZone: timeZone),
              let temperature = current.temperature else { return nil }
        let isDaytime = current.isDay == 1
        let speedMetersPerSecond = current.windSpeed.map { $0 / 2.236_936 }
        let gustMetersPerSecond = current.windGusts.map { $0 / 2.236_936 }

        return Observation(
            timestamp: timestamp,
            textDescription: weatherDescription(code: current.weatherCode ?? 0, isDaytime: isDaytime),
            icon: nil,
            temperature: QuantitativeValue(
                unitCode: unit == .fahrenheit ? "wmoUnit:degF" : "wmoUnit:degC",
                value: temperature
            ),
            dewpoint: QuantitativeValue(
                unitCode: unit == .fahrenheit ? "wmoUnit:degF" : "wmoUnit:degC",
                value: current.dewPoint
            ),
            windDirection: QuantitativeValue(unitCode: "wmoUnit:degree_(angle)", value: current.windDirection),
            windSpeed: QuantitativeValue(unitCode: "wmoUnit:m_s-1", value: speedMetersPerSecond),
            windGust: QuantitativeValue(unitCode: "wmoUnit:m_s-1", value: gustMetersPerSecond),
            barometricPressure: QuantitativeValue(unitCode: "wmoUnit:Pa", value: current.surfacePressure.map { $0 * 100 }),
            seaLevelPressure: QuantitativeValue(unitCode: "wmoUnit:Pa", value: nil),
            visibility: QuantitativeValue(unitCode: "wmoUnit:m", value: current.visibility),
            relativeHumidity: QuantitativeValue(unitCode: "wmoUnit:percent", value: current.relativeHumidity),
            windChill: QuantitativeValue(unitCode: nil, value: nil),
            heatIndex: QuantitativeValue(unitCode: nil, value: nil)
        )
    }

    private func date(
        from text: String,
        timeZone: TimeZone,
        dateOnly: Bool = false
    ) -> Date? {
        let key = "\(timeZone.identifier)|\(dateOnly ? "date" : "hour")"
        if let formatter = dateFormatters[key] {
            return formatter.date(from: text)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = dateOnly ? "yyyy-MM-dd" : "yyyy-MM-dd'T'HH:mm"
        dateFormatters[key] = formatter
        return formatter.date(from: text)
    }

    private func formattedWind(speed: Double, direction: Double) -> String {
        "\(Int(speed.rounded())) mph \(compassDirection(direction))"
    }

    private func compassDirection(_ degrees: Double) -> String {
        let directions = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let normalized = degrees.truncatingRemainder(dividingBy: 360)
        let index = Int(((normalized + 22.5) / 45).rounded(.down)) % directions.count
        return directions[max(0, index)]
    }

    private func weatherDescription(code: Int, isDaytime: Bool) -> String {
        switch code {
        case 0: return isDaytime ? "Clear" : "Clear"
        case 1: return isDaytime ? "Mostly Sunny" : "Mostly Clear"
        case 2: return "Partly Cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Fog"
        case 51, 53, 55: return "Drizzle"
        case 56, 57: return "Freezing Drizzle"
        case 61, 63, 65: return "Rain"
        case 66, 67: return "Freezing Rain"
        case 71, 73, 75, 77: return "Snow"
        case 80, 81, 82: return "Rain Showers"
        case 85, 86: return "Snow Showers"
        case 95, 96, 99: return "Thunderstorms"
        default: return "Variable Conditions"
        }
    }
}

private struct HRRRErrorResponse: Decodable {
    let reason: String?
}

private struct HRRRResponse: Decodable {
    let timezone: String
    let elevation: Double?
    let current: HRRRCurrent?
    let hourly: HRRRHourly
    let daily: HRRRDaily?
}

private struct HRRRCurrent: Decodable {
    let time: String
    let temperature: Double?
    let relativeHumidity: Double?
    let dewPoint: Double?
    let weatherCode: Int?
    let windSpeed: Double?
    let windDirection: Double?
    let windGusts: Double?
    let visibility: Double?
    let surfacePressure: Double?
    let isDay: Int?

    enum CodingKeys: String, CodingKey {
        case time
        case temperature = "temperature_2m"
        case relativeHumidity = "relative_humidity_2m"
        case dewPoint = "dew_point_2m"
        case weatherCode = "weather_code"
        case windSpeed = "wind_speed_10m"
        case windDirection = "wind_direction_10m"
        case windGusts = "wind_gusts_10m"
        case visibility
        case surfacePressure = "surface_pressure"
        case isDay = "is_day"
    }
}

private struct HRRRHourly: Decodable {
    let time: [String]
    let temperature: [Double?]
    let relativeHumidity: [Double?]
    let dewPoint: [Double?]
    let precipitation: [Double?]
    let precipitationProbability: [Double?]
    let weatherCode: [Double?]
    let windSpeed: [Double?]
    let windDirection: [Double?]
    let isDay: [Double?]

    enum CodingKeys: String, CodingKey {
        case time
        case temperature = "temperature_2m"
        case relativeHumidity = "relative_humidity_2m"
        case dewPoint = "dew_point_2m"
        case precipitation
        case precipitationProbability = "precipitation_probability"
        case weatherCode = "weather_code"
        case windSpeed = "wind_speed_10m"
        case windDirection = "wind_direction_10m"
        case isDay = "is_day"
    }
}

private struct HRRRDaily: Decodable {
    let time: [String]
    let weatherCode: [Double?]
    let temperatureMax: [Double?]
    let temperatureMin: [Double?]
    let precipitationProbabilityMax: [Double?]
    let windSpeedMax: [Double?]
    let windDirection: [Double?]

    enum CodingKeys: String, CodingKey {
        case time
        case weatherCode = "weather_code"
        case temperatureMax = "temperature_2m_max"
        case temperatureMin = "temperature_2m_min"
        case precipitationProbabilityMax = "precipitation_probability_max"
        case windSpeedMax = "wind_speed_10m_max"
        case windDirection = "wind_direction_10m_dominant"
    }
}

private extension Array {
    func value(at index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension Array where Element == Double? {
    func compactValue(at index: Index) -> Double? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
