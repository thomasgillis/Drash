import Foundation

struct Summit: Identifiable, Hashable, Sendable {
    let name: String
    let range: String
    let elevationFeet: Int
    let latitude: Double
    let longitude: Double

    var id: String { name }

    var weatherLocation: WeatherLocation {
        WeatherLocation(
            name: name,
            state: "CO",
            latitude: latitude,
            longitude: longitude,
            kind: .summit,
            elevation: Elevation(feet: elevationFeet, source: .summitCatalog)
        )
    }
}

enum SummitCatalog {
    // Colorado's 58 named fourteeners, including the five named summits that do
    // not meet the traditional 300-foot prominence rule.
    static let coloradoFourteeners: [Summit] = [
        summit("Mount Elbert", "Sawatch Range", 14_440, 39.1178, -106.4454),
        summit("Mount Massive", "Sawatch Range", 14_428, 39.1875, -106.4757),
        summit("Mount Harvard", "Sawatch Range", 14_421, 38.9244, -106.3207),
        summit("Blanca Peak", "Sangre de Cristo Range", 14_351, 37.5775, -105.4856),
        summit("La Plata Peak", "Sawatch Range", 14_343, 39.0294, -106.4729),
        summit("Uncompahgre Peak", "San Juan Mountains", 14_321, 38.0717, -107.4621),
        summit("Crestone Peak", "Sangre de Cristo Range", 14_300, 37.9669, -105.5855),
        summit("Mount Lincoln", "Mosquito Range", 14_293, 39.3515, -106.1116),
        summit("Castle Peak", "Elk Mountains", 14_279, 39.0097, -106.8614),
        summit("Grays Peak", "Front Range", 14_278, 39.6339, -105.8176),
        summit("Mount Antero", "Sawatch Range", 14_276, 38.6741, -106.2462),
        summit("Torreys Peak", "Front Range", 14_275, 39.6428, -105.8212),
        summit("Quandary Peak", "Tenmile Range", 14_271, 39.3973, -106.1064),
        summit("Mount Blue Sky", "Front Range", 14_268, 39.5883, -105.6438),
        summit("Longs Peak", "Front Range", 14_259, 40.2550, -105.6151),
        summit("Mount Wilson", "San Juan Mountains", 14_252, 37.8391, -107.9916),
        summit("Mount Cameron", "Mosquito Range", 14_238, 39.347165, -106.118501),
        summit("Mount Shavano", "Sawatch Range", 14_231, 38.6192, -106.2393),
        summit("Mount Princeton", "Sawatch Range", 14_204, 38.7492, -106.2424),
        summit("Mount Belford", "Sawatch Range", 14_203, 38.9607, -106.3607),
        summit("Crestone Needle", "Sangre de Cristo Range", 14_203, 37.9647, -105.5766),
        summit("Mount Yale", "Sawatch Range", 14_200, 38.8442, -106.3138),
        summit("Mount Bross", "Mosquito Range", 14_178, 39.3354, -106.1077),
        summit("Kit Carson Peak", "Sangre de Cristo Range", 14_171, 37.9797, -105.6026),
        summit("Maroon Peak", "Elk Mountains", 14_163, 39.0708, -106.9890),
        summit("Tabeguache Peak", "Sawatch Range", 14_162, 38.6255, -106.2509),
        summit("Mount Oxford", "Sawatch Range", 14_160, 38.9648, -106.3388),
        summit("El Diente Peak", "San Juan Mountains", 14_159, 37.839383, -108.005335),
        summit("Mount Sneffels", "San Juan Mountains", 14_158, 38.0038, -107.7923),
        summit("Mount Democrat", "Mosquito Range", 14_155, 39.3396, -106.1400),
        summit("Capitol Peak", "Elk Mountains", 14_137, 39.1503, -107.0829),
        summit("Pikes Peak", "Front Range", 14_115, 38.8405, -105.0442),
        summit("Snowmass Mountain", "Elk Mountains", 14_099, 39.1188, -107.0665),
        summit("Windom Peak", "San Juan Mountains", 14_093, 37.6212, -107.5919),
        summit("Mount Eolus", "San Juan Mountains", 14_090, 37.6218, -107.6227),
        summit("Challenger Point", "Sangre de Cristo Range", 14_087, 37.9804, -105.6066),
        summit("Mount Columbia", "Sawatch Range", 14_077, 38.9039, -106.2975),
        summit("Missouri Mountain", "Sawatch Range", 14_074, 38.9476, -106.3785),
        summit("Humboldt Peak", "Sangre de Cristo Range", 14_070, 37.9762, -105.5552),
        summit("Mount Bierstadt", "Front Range", 14_065, 39.5826, -105.6688),
        summit("Sunlight Peak", "San Juan Mountains", 14_065, 37.6274, -107.5959),
        summit("Conundrum Peak", "Elk Mountains", 14_060, 39.015682, -106.862749),
        summit("Handies Peak", "San Juan Mountains", 14_058, 37.9130, -107.5044),
        summit("Culebra Peak", "Sangre de Cristo Range", 14_053, 37.1224, -105.1858),
        summit("Ellingwood Point", "Sangre de Cristo Range", 14_048, 37.5826, -105.4927),
        summit("Mount Lindsey", "Sangre de Cristo Range", 14_048, 37.5837, -105.4449),
        summit("Little Bear Peak", "Sangre de Cristo Range", 14_043, 37.5666, -105.4972),
        summit("Mount Sherman", "Mosquito Range", 14_043, 39.2250, -106.1699),
        summit("Redcloud Peak", "San Juan Mountains", 14_041, 37.9410, -107.4219),
        summit("North Eolus", "San Juan Mountains", 14_039, 37.625192, -107.621187),
        summit("Pyramid Peak", "Elk Mountains", 14_025, 39.0717, -106.9502),
        summit("Wilson Peak", "San Juan Mountains", 14_023, 37.8603, -107.9847),
        summit("San Luis Peak", "San Juan Mountains", 14_022, 37.9868, -106.9313),
        summit("Wetterhorn Peak", "San Juan Mountains", 14_021, 38.0607, -107.5109),
        summit("North Maroon Peak", "Elk Mountains", 14_014, 39.076007, -106.987058),
        summit("Mount of the Holy Cross", "Sawatch Range", 14_011, 39.4668, -106.4817),
        summit("Huron Peak", "Sawatch Range", 14_010, 38.9455, -106.4381),
        summit("Sunshine Peak", "San Juan Mountains", 14_007, 37.9228, -107.4256)
    ]

    static func matching(_ query: String) -> [Summit] {
        let terms = query
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !terms.isEmpty else { return coloradoFourteeners }

        if terms.allSatisfy({ ["14er", "14ers", "fourteener", "fourteeners", "colorado"].contains($0.lowercased()) }) {
            return coloradoFourteeners
        }

        return coloradoFourteeners.filter { summit in
            let searchable = "\(summit.name) \(summit.range) Colorado 14er"
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return terms.allSatisfy { searchable.localizedCaseInsensitiveContains($0) }
        }
    }

    private static func summit(
        _ name: String,
        _ range: String,
        _ elevationFeet: Int,
        _ latitude: Double,
        _ longitude: Double
    ) -> Summit {
        Summit(
            name: name,
            range: range,
            elevationFeet: elevationFeet,
            latitude: latitude,
            longitude: longitude
        )
    }
}
