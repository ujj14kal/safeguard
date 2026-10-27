import CoreLocation

/// SOS-only location: starts when Unsafe begins, stops when the SOS ends.
/// Privacy rule, enforced structurally: nothing outside the SOS flow calls
/// `start()`, so the app never reads location at any other time.
///
/// `latest` is the best fresh fix (see `LocationFixPolicy`), not just the
/// last callback: stale cached fixes are dropped and a coarse reading never
/// replaces an accurate one.
@MainActor
final class SOSLocationTracker: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var latest: CLLocation?
    @Published private(set) var denied = false
    /// The wearer turned Precise Location off for Safeguard (fixes are
    /// ~km off). The tracker asks for temporary full accuracy during an SOS.
    @Published private(set) var reducedAccuracy = false

    private let manager = CLLocationManager()
    private(set) var running = false

    /// Key into Info.plist `NSLocationTemporaryUsageDescriptionDictionary`.
    private static let purposeKey = "SOS"

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = false
    }

    var quality: LocationQuality? {
        latest.map { LocationFixPolicy.quality(accuracy: $0.horizontalAccuracy) }
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
        refreshAccuracyAuthorization()
        manager.startUpdatingLocation()
        // One immediate (possibly cached) reading so the screen has a dot
        // while the GPS warms up; the policy drops it if it is stale.
        manager.requestLocation()
    }

    func stop() {
        running = false
        manager.stopUpdatingLocation()
        latest = nil
    }

    /// Precise Location off: ask once for temporary full accuracy.
    private func refreshAccuracyAuthorization() {
        reducedAccuracy = manager.accuracyAuthorization == .reducedAccuracy
        if reducedAccuracy {
            manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: Self.purposeKey)
        }
    }

    // MARK: - CLLocationManagerDelegate

    // Nonisolated: the protocol is not main-actor bound, so the callbacks
    // hop back to publish.
    nonisolated func locationManager(
        _ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let now = Date()
            for fix in locations {
                let candidate = LocationSample(
                    latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude,
                    accuracy: fix.horizontalAccuracy, timestamp: fix.timestamp
                )
                let current = latest.map {
                    LocationSample(
                        latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude,
                        accuracy: $0.horizontalAccuracy, timestamp: $0.timestamp
                    )
                }
                if LocationFixPolicy.shouldReplace(old: current, with: candidate, now: now) {
                    latest = fix
                }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard let clError = error as? CLError, clError.code == .denied else { return }
        Task { @MainActor [weak self] in self?.denied = true }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            self?.reducedAccuracy = manager.accuracyAuthorization == .reducedAccuracy
            if status == .denied || status == .restricted { self?.denied = true }
        }
    }
}
