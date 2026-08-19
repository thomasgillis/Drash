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
    private static let automaticForecastRefreshTimer = Timer.publish(
        every: 30,
        tolerance: 5,
        on: .main,
        in: .common
    ).autoconnect()

    @EnvironmentObject private var model: WeatherViewModel
    @EnvironmentObject private var locationManager: LocationManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = AppTab.forecast
    @State private var isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var automaticForecastBoundary: Date?
    @State private var automaticForecastAttemptCount = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                ForecastView()
            }
            .tabItem { Label("Forecast", systemImage: "sun.max.fill") }
            .tag(AppTab.forecast)

            NavigationStack {
                RadarView(isActive: selectedTab == .radar) {
                    selectedTab = .forecast
                }
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
        .tabViewStyle(.sidebarAdaptable)
        .accessibilityIdentifier("app-navigation")
        .tint(.blue)
        .task {
            model.reloadSavedPlaces()
            await model.restoreLastSession(lowPowerMode: isLowPowerModeEnabled)
            requestDeviceLocationIfNeeded()
            model.refreshIfStale(lowPowerMode: isLowPowerModeEnabled)
            refreshForCurrentForecastBoundaryIfNeeded()
        }
        .onReceive(Self.automaticForecastRefreshTimer) { date in
            guard scenePhase == .active else { return }
            requestDeviceLocationIfNeeded()
            refreshForCurrentForecastBoundaryIfNeeded(at: date)
        }
        .onReceive(locationManager.$currentLocation.compactMap { $0 }) { location in
            model.useDeviceLocation(location)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                model.reloadSavedPlaces()
                requestDeviceLocationIfNeeded()
                model.refreshIfStale(lowPowerMode: isLowPowerModeEnabled)
                refreshForCurrentForecastBoundaryIfNeeded()
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
            model.refreshIfStale(lowPowerMode: isLowPowerModeEnabled)
            refreshForCurrentForecastBoundaryIfNeeded()
        }
    }

    private func requestDeviceLocationIfNeeded() {
        guard model.shouldRequestDeviceLocation(lowPowerMode: isLowPowerModeEnabled) else { return }
        locationManager.requestLocation()
    }

    private func refreshForCurrentForecastBoundaryIfNeeded(at date: Date = Date()) {
        let interval: TimeInterval = isLowPowerModeEnabled ? 60 * 60 : 15 * 60
        let boundaryTimestamp = floor(date.timeIntervalSince1970 / interval) * interval
        let boundary = Date(timeIntervalSince1970: boundaryTimestamp)

        if automaticForecastBoundary != boundary {
            automaticForecastBoundary = boundary
            automaticForecastAttemptCount = 0
        }

        guard let snapshot = model.snapshot,
              snapshot.updatedAt < boundary,
              !model.isRefreshInProgress else { return }

        if automaticForecastAttemptCount == 0 {
            // Give providers a short window to publish newly valid data before
            // making the first request assigned to this wall-clock boundary.
            guard date.timeIntervalSince(boundary) >= 30 else { return }
        } else {
            guard automaticForecastAttemptCount < 3,
                  let failureAt = model.lastRefreshFailureAt else { return }
            let retryDelay: TimeInterval = automaticForecastAttemptCount == 1
                ? 60
                : 5 * 60
            guard date.timeIntervalSince(failureAt) >= retryDelay else { return }
        }

        automaticForecastAttemptCount += 1
        model.refresh()
    }
}
