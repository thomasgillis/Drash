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
            }

            Section("Data") {
                LabeledContent("24-hour forecast", value: "NOAA HRRR")
                LabeledContent("Daily forecast", value: "NOAA HRRR (default) or NWS")
                LabeledContent("Radar", value: "NWS (default) or HRRR")
                LabeledContent("Forecasts & alerts", value: "NWS / NOAA")
                Link("National Weather Service", destination: URL(string: "https://www.weather.gov/")!)
                Link("NWS API documentation", destination: URL(string: "https://www.weather.gov/documentation/services-web-api")!)
                Link("HRRR model documentation", destination: URL(string: "https://rapidrefresh.noaa.gov/hrrr/")!)
                Link("Open-Meteo GFS & HRRR API", destination: URL(string: "https://open-meteo.com/en/docs/gfs-api")!)
                Link("Iowa State HRRR reflectivity service", destination: URL(string: "https://mesonet.agron.iastate.edu/GIS/model.phtml")!)
            }

            Section("Coverage") {
                Text("The National Weather Service forecast API covers the United States and its territories. Observation data can be delayed at the source.")
                Text("Forecasts default to HRRR. The expandable next-24-hours forecast always uses HRRR, while the daily section lets you switch to the seven-day NWS outlook. HRRR is limited to its continental U.S. domain.")
                Text("Radar defaults to the official NWS layer for recent observed history. You can switch to HRRR simulated reflectivity through forecast hour 18. Both cover the continental United States.")
            }

            Section("Privacy") {
                Text("Your location is sent to api.weather.gov for NWS data and to api.open-meteo.com for NOAA HRRR model output. Radar tiles are requested from NWS or Iowa State's IEM HRRR service according to your selection. Saved places and daily model choices remain on this device. Drash has no account, ads, analytics, or third-party tracking.")
            }

            Section {
                LabeledContent("Version", value: appVersion)
            }
        }
        .navigationTitle("Settings")
    }

    private var appVersion: String {
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}
