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
                LabeledContent("Forecasts & alerts", value: "NWS / NOAA")
                Link("National Weather Service", destination: URL(string: "https://www.weather.gov/")!)
                Link("NWS API documentation", destination: URL(string: "https://www.weather.gov/documentation/services-web-api")!)
            }

            Section("Coverage") {
                Text("The National Weather Service forecast API covers the United States and its territories. Observation data can be delayed at the source.")
                Text("Radar history uses the official NWS CONUS precipitation layer. Drash displays recent observations only and does not download a separate radar forecast model.")
            }

            Section("Privacy") {
                Text("Your location is sent directly to api.weather.gov to retrieve a local forecast. Radar tiles are requested directly from NWS. Saved places remain on this device. Drash has no account, ads, analytics, or third-party tracking.")
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
