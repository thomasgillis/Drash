import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: WeatherViewModel

    var body: some View {
        Form {
            Section("Units") {
                Picker("Temperature", selection: $model.temperatureUnit) {
                    Text("Fahrenheit").tag(TemperatureUnit.fahrenheit)
                    Text("Celsius").tag(TemperatureUnit.celsius)
                }
                .pickerStyle(.segmented)

                Picker("Altitude", selection: $model.altitudeUnit) {
                    Text("Feet").tag(AltitudeUnit.feet)
                    Text("Meters").tag(AltitudeUnit.meters)
                }
                .pickerStyle(.segmented)
            }

            Section("Current & 24-hour forecast") {
                Picker("Source", selection: $model.currentAndHourlyForecastModel) {
                    Text("HRRR").tag(ForecastModel.hrrr)
                    Text("NWS").tag(ForecastModel.nws)
                }
                .pickerStyle(.segmented)

                Text(
                    model.currentAndHourlyForecastModel == .hrrr
                        ? "Uses high-resolution HRRR model guidance for current conditions and the next 24 hours."
                        : "Uses the nearest NWS station for current conditions and the NWS hourly forecast for the next 24 hours."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section("Data") {
                LabeledContent(
                    "Saved places",
                    value: model.savedPlacesSyncEnabled ? "Private iCloud" : "On this device"
                )
                LabeledContent("Current & 24-hour forecast", value: "NOAA HRRR or NWS")
                LabeledContent("Daily forecast", value: "NOAA HRRR (default) or NWS")
                LabeledContent("Radar", value: "NWS (default) or HRRR")
                LabeledContent("Forecasts & alerts", value: "NWS / NOAA")
                LabeledContent("Crags", value: "OpenBeta")
                LabeledContent("Summit names", value: "USGS GNIS")
                Link("National Weather Service", destination: URL(string: "https://www.weather.gov/")!)
                Link("NWS API documentation", destination: URL(string: "https://www.weather.gov/documentation/services-web-api")!)
                Link("HRRR model documentation", destination: URL(string: "https://rapidrefresh.noaa.gov/hrrr/")!)
                Link("Open-Meteo GFS & HRRR API", destination: URL(string: "https://open-meteo.com/en/docs/gfs-api")!)
                Link("Iowa State HRRR reflectivity service", destination: URL(string: "https://mesonet.agron.iastate.edu/GIS/model.phtml")!)
                Link("OpenBeta climbing data", destination: URL(string: "https://openbeta.io/")!)
                Link("USGS Geographic Names", destination: URL(string: "https://www.usgs.gov/tools/geographic-names-information-system-gnis")!)
            }

            Section("Coverage") {
                Text("The National Weather Service forecast API covers the United States and its territories. Observation data can be delayed at the source.")
                Text("Current conditions and the expandable next-24-hours forecast default to HRRR and can be switched together to NWS above. The daily section has its own per-place HRRR/NWS choice. HRRR is limited to its continental U.S. domain.")
                Text("Radar defaults to the official NWS layer for recent observed history. You can switch to HRRR simulated reflectivity through forecast hour 18. Both cover the continental United States.")
            }

            Section("Privacy") {
                Text("Your location is sent to api.weather.gov for NWS data and, when HRRR is selected, to api.open-meteo.com for NOAA HRRR model output. Radar tiles are requested from NWS or Iowa State's IEM HRRR service according to your selection. Outdoor-place searches remain on this device; the refresh button downloads a static catalog without sending your search text. \(savedPlacesPrivacyDescription) Current GPS coordinates, the selected place, and weather caches do not sync. Drash has no separate account, ads, analytics, or third-party tracking.")
            }

            Section {
                LabeledContent("Version", value: appVersion)
            }
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Settings")
    }

    private var appVersion: String {
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private var savedPlacesPrivacyDescription: String {
        if model.savedPlacesSyncEnabled {
            return "Saved places and their daily forecast-source choices are stored locally and sync through your private iCloud database when iCloud is available."
        }
        return "Saved places and their daily forecast-source choices remain on this device in this development build."
    }
}
