@preconcurrency import CoreLocation
import Foundation

@MainActor
final class LocationManager: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var currentLocation: CLLocation?
    @Published private(set) var locationError: String?

    private let manager = CLLocationManager()
    private var isRequestInFlight = false

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.activityType = .other
    }

    @discardableResult
    func requestLocation() -> Bool {
        guard !isRequestInFlight else { return true }
        locationError = nil
        switch manager.authorizationStatus {
        case .notDetermined:
            isRequestInFlight = true
            manager.requestWhenInUseAuthorization()
            return true
        case .authorizedAlways:
            isRequestInFlight = true
            manager.requestLocation()
            return true
#if os(iOS)
        case .authorizedWhenInUse:
            isRequestInFlight = true
            manager.requestLocation()
            return true
#endif
        case .restricted, .denied:
            isRequestInFlight = false
            locationError = "Location access is off. Enable it in Settings or add a place manually."
            return false
        @unknown default:
            isRequestInFlight = false
            locationError = "Location is currently unavailable."
            return false
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        guard isRequestInFlight else { return }
        if manager.authorizationStatus == .authorizedAlways {
            manager.requestLocation()
        }
#if os(iOS)
        if manager.authorizationStatus == .authorizedWhenInUse {
            manager.requestLocation()
        }
#endif
        if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
            isRequestInFlight = false
            locationError = "Location access is off. Enable it in Settings or add a place manually."
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        isRequestInFlight = false
        currentLocation = locations.last
        locationError = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        isRequestInFlight = false
        locationError = error.localizedDescription
    }
}
