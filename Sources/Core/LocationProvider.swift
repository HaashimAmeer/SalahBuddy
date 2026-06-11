import Foundation
import CoreLocation

/// Thin CoreLocation wrapper. If permission is denied/unavailable the app
/// falls back to the fixed coordinates in `AppSettings` — a schedule is
/// ALWAYS computable.
final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationProvider()

    @Published private(set) var deviceCoordinate: CLLocationCoordinate2D?
    @Published private(set) var placeName: String?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    /// True when we actually have a device fix to use.
    var hasDeviceFix: Bool { deviceCoordinate != nil }

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    var onUpdate: (() -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        authorizationStatus = manager.authorizationStatus
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    func refreshLocation() {
        guard authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
        else { return }
        manager.requestLocation()
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        refreshLocation()
        onUpdate?()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        deviceCoordinate = loc.coordinate
        onUpdate?()
        geocoder.reverseGeocodeLocation(loc) { [weak self] placemarks, _ in
            DispatchQueue.main.async {
                if let name = placemarks?.first?.locality ?? placemarks?.first?.name {
                    self?.placeName = name
                    self?.onUpdate?()
                }
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Keep whatever we had; fallback coords cover us.
    }
}
