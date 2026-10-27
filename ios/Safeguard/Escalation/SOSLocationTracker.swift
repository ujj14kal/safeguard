import CoreLocation

/// SOS-only location: starts when Unsafe begins, stops when the SOS ends.
/// Privacy rule, enforced structurally: nothing outside the SOS flow calls
/// `start()`, so the app never reads location at any other time.
@MainActor
final class SOSLocationTracker: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var latest: CLLocation?
    @Published private(set) var denied = false

    private let manager = CLLocationManager()
    private(set) var running = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    /// Asks for when-in-use on first protecting start. No-op once decided.
    func requestPermission() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    func start() {
        guard !running else { return }
        running = true
        denied = false
        manager.startUpdatingLocation()
    }

    func stop() {
        running = false
        manager.stopUpdatingLocation()
        latest = nil
    }

    // MARK: - CLLocationManagerDelegate

    // Nonisolated: the protocol is not main-actor bound, so the callbacks
    // hop back to publish.
    nonisolated func locationManager(
        _ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]
    ) {
        guard let fix = locations.last, fix.horizontalAccuracy >= 0 else { return }
        Task { @MainActor [weak self] in self?.latest = fix }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard let clError = error as? CLError, clError.code == .denied else { return }
        Task { @MainActor [weak self] in self?.denied = true }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        guard status == .denied || status == .restricted else { return }
        Task { @MainActor [weak self] in self?.denied = true }
    }
}
