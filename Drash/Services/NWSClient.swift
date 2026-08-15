import Foundation

enum WeatherServiceError: LocalizedError {
    case invalidURL
    case outsideCoverage
    case server(status: Int)
    case invalidResponse

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

actor NWSClient {
    static let shared = NWSClient()

    private let session: URLSession
    private let decoder: JSONDecoder
    private var pointCache: [String: (value: PointResponse, cachedAt: Date)] = [:]
    private var stationCache: [URL: StationLookup] = [:]
    private let metadataFreshnessInterval: TimeInterval = 6 * 60 * 60

    init(session: URLSession = .shared) {
        self.session = session
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

    func weather(for requestedLocation: WeatherLocation, unit: TemperatureUnit) async throws -> WeatherSnapshot {
        let coordinates = String(format: "%.4f,%.4f", requestedLocation.latitude, requestedLocation.longitude)
        guard let pointURL = URL(string: "https://api.weather.gov/points/\(coordinates)") else {
            throw WeatherServiceError.invalidURL
        }

        let point = try await pointResponse(at: pointURL, cacheKey: coordinates)

        let forecastURL = addingQuery(name: "units", value: unit.apiUnit, to: point.properties.forecast)
        let hourlyURL = addingQuery(name: "units", value: unit.apiUnit, to: point.properties.forecastHourly)
        let alertsURL = URL(string: "https://api.weather.gov/alerts/active?point=\(coordinates)")!

        async let dailyResponse: ForecastResponse = get(forecastURL)
        async let hourlyResponse: ForecastResponse = get(hourlyURL)
        async let gridResult: OptionalFetch<GridpointResponse> = optionalGet(point.properties.forecastGridData)
        async let stationResult = fetchStationAndObservation(from: point.properties.observationStations)
        async let alertResult: OptionalFetch<AlertsResponse> = optionalGet(alertsURL)

        let (daily, hourly, grid, stationAndObservation, alerts) = try await (
            dailyResponse,
            hourlyResponse,
            gridResult,
            stationResult,
            alertResult
        )

        let precipitationAmounts = grid.value?.properties.quantitativePrecipitation?.values.compactMap {
            PrecipitationAmount(validTime: $0.validTime, millimeters: $0.value)
        }

        var location = requestedLocation
        if let place = point.properties.relativeLocation?.properties,
           requestedLocation.isCurrentLocation || requestedLocation.name == "Dropped pin" {
            location.name = place.city
            location.state = place.state
        }

        return WeatherSnapshot(
            location: location,
            updatedAt: daily.properties.updated ?? daily.properties.generatedAt ?? Date(),
            forecastOffice: point.properties.forecastOffice?.absoluteString,
            daily: daily.properties.periods,
            hourly: hourly.properties.periods,
            precipitationAmounts: precipitationAmounts,
            observation: stationAndObservation.observation,
            station: stationAndObservation.station,
            alerts: alerts.value?.features.map(\.properties.alert) ?? [],
            alertsUnavailable: !alerts.succeeded,
            hourlyForecastModel: .nws
        )
    }

    func weatherContext(for requestedLocation: WeatherLocation) async throws -> NWSWeatherContext {
        let coordinates = String(format: "%.4f,%.4f", requestedLocation.latitude, requestedLocation.longitude)
        guard let pointURL = URL(string: "https://api.weather.gov/points/\(coordinates)"),
              let alertsURL = URL(string: "https://api.weather.gov/alerts/active?point=\(coordinates)") else {
            throw WeatherServiceError.invalidURL
        }

        let point = try await pointResponse(at: pointURL, cacheKey: coordinates)
        async let stationResult = fetchStationAndObservation(from: point.properties.observationStations)
        async let alertResult: OptionalFetch<AlertsResponse> = optionalGet(alertsURL)
        let (stationAndObservation, alerts) = await (stationResult, alertResult)

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
        var request = URLRequest(url: url)
        request.setValue("application/geo+json", forHTTPHeaderField: "Accept")
        request.setValue("Drash/1.0 (personal iOS weather app)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .useProtocolCachePolicy
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WeatherServiceError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw WeatherServiceError.server(status: http.statusCode)
        }
        return try decoder.decode(T.self, from: data)
    }
}
