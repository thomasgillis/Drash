import SwiftUI

@main
struct DrashApp: App {
    @StateObject private var model = WeatherViewModel()
    @StateObject private var locationManager = LocationManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(locationManager)
        }
    }
}

