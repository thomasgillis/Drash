import CoreLocation
import Combine
import SwiftUI

private enum AppTab: Hashable {
    case forecast
    case radar
    case places
    case settings
}

struct RootView: View {
    @EnvironmentObject private var model: WeatherViewModel
    @EnvironmentObject private var locationManager: LocationManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = AppTab.forecast
    @State private var isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                ForecastView()
            }
            .tabItem { Label("Forecast", systemImage: "sun.max.fill") }
            .tag(AppTab.forecast)

            NavigationStack {
                RadarView(isActive: selectedTab == .radar)
            }
            .tabItem { Label("Radar", systemImage: "dot.radiowaves.left.and.right") }
            .tag(AppTab.radar)

            NavigationStack {
                PlacesView {
                    selectedTab = .forecast
                }
            }
            .tabItem { Label("Places", systemImage: "location.fill") }
            .tag(AppTab.places)

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gearshape.fill") }
            .tag(AppTab.settings)
        }
        .tint(.blue)
        .task {
            await model.restoreLastSession(lowPowerMode: isLowPowerModeEnabled)
            if !requestDeviceLocationIfNeeded() {
                model.refreshIfStale(lowPowerMode: isLowPowerModeEnabled)
            }
        }
        .onReceive(locationManager.$currentLocation.compactMap { $0 }) { location in
            model.useDeviceLocation(location)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                if !requestDeviceLocationIfNeeded() {
                    model.refreshIfStale(lowPowerMode: isLowPowerModeEnabled)
                }
            case .background:
                model.suspendNetworkWork()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    @discardableResult
    private func requestDeviceLocationIfNeeded() -> Bool {
        guard model.shouldRequestDeviceLocation(lowPowerMode: isLowPowerModeEnabled) else { return false }
        model.beginUsingDeviceLocation()
        guard locationManager.requestLocation() else {
            model.cancelUsingDeviceLocation()
            return false
        }
        return true
    }
}
