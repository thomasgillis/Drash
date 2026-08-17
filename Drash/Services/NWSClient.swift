import Foundation

enum WeatherServiceError: LocalizedError {
    case invalidURL
    case outsideCoverage
    case server(status: Int)
    case invalidResponse
    case rateLimited(retryAt: Date)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The weather request could not be created."
        case .outsideCoverage:
            return "NWS forecasts cover the United States and its territories."
        case .server(let status):
            return "The National Weather Service returned an error (\(status))."
        case .invalidResponse:
            return "The weather response was incomplete."
        case .rateLimited(let retryAt):
            return "The National Weather Service request limit has been reached. Drash will try again after \(retryAt.formatted(date: .omitted, time: .shortened))."
        }
    }
}

struct NWSWeatherContext: Sendable {
    let location: WeatherLocation
    let forecastOffice: String?
    let observation: Observation?
    let station: ObservationStation?
    let alerts: [WeatherAlert]
    let alertsUnavailable: Bool
}

struct NWSDailyForecast: Sendable {
    let location: WeatherLocation
    let forecastOffice: String?
    let periods: [ForecastPeriod]
}

struct NWSHourlyForecast: Sendable {
    let location: WeatherLocation
    let updatedAt: Date
    let forecastOffice: String?
    let periods: [ForecastPeriod]
    let precipitationAmounts: [PrecipitationAmount]
    let elevation: Elevation?
}

actor NWSClient {
    static let shared = NWSClient()

    private let session: URLSession
    private let defaults: UserDefaults
    private let decoder: JSONDecoder
    private var pointCache: [String: (value: PointResponse, cachedAt: Date)] = [:]
    private var stationCache: [URL: StationLookup] = [:]
    private let metadataFreshnessInterval: TimeInterval = 6 * 60 * 60
    private var requestDates: [Date]
    private var providerCooldownUntil: Date?
    private let minuteRequestWindow: TimeInterval = 60
    private let hourlyRequestWindow: TimeInterval = 60 * 60
    private let maximumRequestsPerMinute = 20
    private let maximumRequestsPerHour = 120

    private enum RateLimitKeys {
        static let requestDates = "nwsRequestDates"
        static let providerCooldownUntil = "nwsProviderCooldownUntil"
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
        let decoder = JSONDecoder()
        let fractionalDateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let standardDateStyle = Date.ISO8601FormatStyle()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = try? fractionalDateStyle.parse(value) { return date }
            if let date = try? standardDateStyle.parse(value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO-8601 date: \(value)")
        }
        self.decoder = decoder
    }

    func dailyForecast(for requestedLocation: WeatherLocation, unit: TemperatureUnit) async throws -> NWSDailyForecast {
        let coordinates = String(format: "%.4f,%.4f", requestedLocation.latitude, requestedLocation.longitude)
        guard let pointURL = URL(string: "https://api.weather.gov/points/\(coordinates)") else {
            throw WeatherServiceError.invalidURL
        }

        let point = try await pointResponse(at: pointURL, cacheKey: coordinates)
        let forecastURL = addingQuery(name: "units", value: unit.apiUnit, to: point.properties.forecast)
        let daily: ForecastResponse = try await get(forecastURL)

        var location = requestedLocation
        if let place = point.properties.relativeLocation?.properties,
           requestedLocation.isCurrentLocation || requestedLocation.name == "Dropped pin" {
            location.name = place.city
            location.state = place.state
        }

        return NWSDailyForecast(
            location: location,
            forecastOffice: point.properties.forecastOffice?.absoluteString,
            periods: daily.properties.periods
        )
    }

    func hourlyForecast(for requestedLocation: WeatherLocation, unit: TemperatureUnit) async throws -> NWSHourlyForecast {
        let coordinates = String(format: "%.4f,%.4f", requestedLocation.latitude, requestedLocation.longitude)
        guard let pointURL = URL(string: "https://api.weather.gov/points/\(coordinates)") else {
            throw WeatherServiceError.invalidURL
        }

        let point = try await pointResponse(at: pointURL, cacheKey: coordinates)
        let hourlyURL = addingQuery(name: "units", value: unit.apiUnit, to: point.properties.forecastHourly)
        let hourly: ForecastResponse = try await get(hourlyURL)
        let grid: OptionalFetch<GridpointResponse> = await optionalGet(point.properties.forecastGridData)

        var location = requestedLocation
        if let place = point.properties.relativeLocation?.properties,
           requestedLocation.isCurrentLocation || requestedLocation.name == "Dropped pin" {
            location.name = place.city
            location.state = place.state
        }

        let precipitationAmounts = grid.value?.properties.quantitativePrecipitation?.values.compactMap {
            PrecipitationAmount(validTime: $0.validTime, millimeters: $0.value)
        } ?? []
        let elevation = grid.value?.properties.elevation?.value.map {
            Elevation(meters: $0, source: .terrainModel)
        }

        return NWSHourlyForecast(
            location: location,
            updatedAt: hourly.properties.updated ?? hourly.properties.generatedAt ?? Date(),
            forecastOffice: point.properties.forecastOffice?.absoluteString,
            periods: hourly.properties.periods,
            precipitationAmounts: precipitationAmounts,
            elevation: elevation
        )
    }

    func weatherContext(
        for requestedLocation: WeatherLocation,
        includeStationObservation: Bool = true
    ) async throws -> NWSWeatherContext {
        let coordinates = String(format: "%.4f,%.4f", requestedLocation.latitude, requestedLocation.longitude)
        guard let pointURL = URL(string: "https://api.weather.gov/points/\(coordinates)"),
              let alertsURL = URL(string: "https://api.weather.gov/alerts/active?point=\(coordinates)") else {
            throw WeatherServiceError.invalidURL
        }

        let point = try await pointResponse(at: pointURL, cacheKey: coordinates)
        async let alertResult: OptionalFetch<AlertsResponse> = optionalGet(alertsURL)
        let stationAndObservation: (station: ObservationStation?, observation: Observation?)
        if includeStationObservation {
            stationAndObservation = await fetchStationAndObservation(
                from: point.properties.observationStations
            )
        } else {
            stationAndObservation = (nil, nil)
        }
        let alerts = await alertResult

        var location = requestedLocation
        if let place = point.properties.relativeLocation?.properties,
           requestedLocation.isCurrentLocation || requestedLocation.name == "Dropped pin" {
            location.name = place.city
            location.state = place.state
        }

        return NWSWeatherContext(
            location: location,
            forecastOffice: point.properties.forecastOffice?.absoluteString,
            observation: stationAndObservation.observation,
            station: stationAndObservation.station,
            alerts: alerts.value?.features.map(\.properties.alert) ?? [],
            alertsUnavailable: !alerts.succeeded
        )
    }

    private func pointResponse(at url: URL, cacheKey: String) async throws -> PointResponse {
        if let cached = pointCache[cacheKey],
           Date().timeIntervalSince(cached.cachedAt) < metadataFreshnessInterval {
            return cached.value
        }

        do {
            let point: PointResponse = try await get(url)
            pointCache[cacheKey] = (point, .now)
            return point
        } catch WeatherServiceError.server(let status) where status == 404 {
            throw WeatherServiceError.outsideCoverage
        }
    }

    private func fetchStationAndObservation(from stationsURL: URL) async -> (station: ObservationStation?, observation: Observation?) {
        do {
            let lookup = try await stationLookup(from: stationsURL)
            do {
                let observationResponse: ObservationResponse = try await get(lookup.observationURL)
                return (lookup.station, observationResponse.properties)
            } catch {
                return (lookup.station, nil)
            }
        } catch {
            return (nil, nil)
        }
    }

    private func stationLookup(from stationsURL: URL) async throws -> StationLookup {
        if let cached = stationCache[stationsURL],
           Date().timeIntervalSince(cached.cachedAt) < metadataFreshnessInterval {
            return cached
        }

        let response: StationsResponse = try await get(stationsURL)
        guard let first = response.features.first else {
            throw WeatherServiceError.invalidResponse
        }
        let coordinates = first.geometry?.coordinates
        let station = ObservationStation(
            stationIdentifier: first.properties.stationIdentifier,
            name: first.properties.name,
            latitude: (coordinates?.count ?? 0) > 1 ? coordinates?[1] : nil,
            longitude: coordinates?.first
        )
        guard let observationURL = URL(
            string: "https://api.weather.gov/stations/\(first.properties.stationIdentifier)/observations/latest"
        ) else {
            throw WeatherServiceError.invalidURL
        }
        let lookup = StationLookup(station: station, observationURL: observationURL, cachedAt: .now)
        stationCache[stationsURL] = lookup
        return lookup
    }

    private func addingQuery(name: String, value: String, to url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: name, value: value))
        components.queryItems = queryItems
        return components.url ?? url
    }

    private struct OptionalFetch<T> {
        let value: T?
        let succeeded: Bool
    }

    private struct StationLookup {
        let station: ObservationStation
        let observationURL: URL
        let cachedAt: Date
    }

    private func optionalGet<T: Decodable>(_ url: URL) async -> OptionalFetch<T> {
        do {
            return OptionalFetch(value: try await get(url), succeeded: true)
        } catch {
            return OptionalFetch(value: nil, succeeded: false)
        }
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        let requestedAt = Date()
        try registerRequest(at: requestedAt)

        var request = URLRequest(url: url)
        request.setValue("application/geo+json", forHTTPHeaderField: "Accept")
        request.setValue("Drash/1.0 (personal iOS weather app)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .useProtocolCachePolicy
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw WeatherServiceError.invalidResponse
        }
        if http.statusCode == 429 {
            let retryAt = retryDate(from: http, relativeTo: requestedAt)
            providerCooldownUntil = max(providerCooldownUntil ?? .distantPast, retryAt)
            persistRateLimitState()
            throw WeatherServiceError.rateLimited(retryAt: retryAt)
        }
        guard (200...299).contains(http.statusCode) else {
            throw WeatherServiceError.server(status: http.statusCode)
        }
        return try decoder.decode(T.self, from: data)
    }

    private func registerRequest(at date: Date) throws {
        if let providerCooldownUntil, date < providerCooldownUntil {
            throw WeatherServiceError.rateLimited(retryAt: providerCooldownUntil)
        }
        if providerCooldownUntil != nil {
            providerCooldownUntil = nil
            persistRateLimitState()
        }

        let hourStart = date.addingTimeInterval(-hourlyRequestWindow)
        requestDates.removeAll { $0 <= hourStart }
        let minuteStart = date.addingTimeInterval(-minuteRequestWindow)
        let recentMinuteRequests = requestDates.filter { $0 > minuteStart }

        if recentMinuteRequests.count >= maximumRequestsPerMinute {
            throw WeatherServiceError.rateLimited(
                retryAt: recentMinuteRequests[0].addingTimeInterval(minuteRequestWindow)
            )
        }
        if requestDates.count >= maximumRequestsPerHour {
            throw WeatherServiceError.rateLimited(
                retryAt: requestDates[0].addingTimeInterval(hourlyRequestWindow)
            )
        }

        // Reserve before URLSession suspends so concurrent actor calls count.
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
            return date.addingTimeInterval(5)
        }
        if let seconds = TimeInterval(value), seconds >= 0 {
            return date.addingTimeInterval(seconds)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: value) ?? date.addingTimeInterval(5)
    }
}
