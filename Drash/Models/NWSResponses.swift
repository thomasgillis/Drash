import Foundation

struct PointResponse: Decodable {
    let properties: Properties

    struct Properties: Decodable {
        let forecast: URL
        let forecastHourly: URL
        let forecastGridData: URL
        let observationStations: URL
        let forecastOffice: URL?
        let relativeLocation: RelativeLocation?
    }

    struct RelativeLocation: Decodable {
        let properties: Place
    }

    struct Place: Decodable {
        let city: String
        let state: String
    }
}

struct GridpointResponse: Decodable {
    let properties: Properties

    struct Properties: Decodable {
        let quantitativePrecipitation: GridQuantity?
    }

    struct GridQuantity: Decodable {
        let uom: String?
        let values: [GridValue]
    }

    struct GridValue: Decodable {
        let validTime: String
        let value: Double?
    }
}

struct ForecastResponse: Decodable {
    let properties: Properties

    struct Properties: Decodable {
        let updated: Date?
        let generatedAt: Date?
        let periods: [ForecastPeriod]
    }
}

struct StationsResponse: Decodable {
    let features: [Feature]

    struct Feature: Decodable {
        let geometry: PointGeometry?
        let properties: Properties
    }

    struct Properties: Decodable {
        let stationIdentifier: String
        let name: String
    }
}

struct PointGeometry: Decodable {
    let coordinates: [Double]
}

struct ObservationResponse: Decodable {
    let properties: Observation
}

struct AlertsResponse: Decodable {
    let features: [Feature]

    struct Feature: Decodable {
        let id: URL?
        let properties: Properties
    }

    struct Properties: Decodable {
        let id: String
        let areaDesc: String
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

        var alert: WeatherAlert {
            WeatherAlert(
                id: id,
                areaDescription: areaDesc,
                sent: sent,
                effective: effective,
                onset: onset,
                expires: expires,
                ends: ends,
                status: status,
                messageType: messageType,
                category: category,
                severity: severity,
                certainty: certainty,
                urgency: urgency,
                event: event,
                senderName: senderName,
                headline: headline,
                description: description,
                instruction: instruction
            )
        }
    }
}
