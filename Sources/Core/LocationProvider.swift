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

    // MARK: - Test seam (v4.1)

    #if DEBUG
    /// Stand in for a CoreLocation fix. TESTS ONLY — compiled out of Release.
    ///
    /// `deviceCoordinate` is `private(set)` on purpose: inside the app only the
    /// delegate callback above may write it, and that stays true. But
    /// `AppState.reanchorPlace` is *defined* by "where is the device right
    /// now" — a saved place moves to the fix or the call fails — and there is
    /// no way to unit-test either half without one. Deliberately not
    /// `onUpdate`-firing: a test wants to set the world, not restart a refresh.
    func simulateDeviceFix(_ coordinate: CLLocationCoordinate2D?) {
        deviceCoordinate = coordinate
    }
    #endif
}
