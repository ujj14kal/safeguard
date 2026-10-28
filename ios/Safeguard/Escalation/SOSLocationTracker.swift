import CoreLocation

@MainActor
final class SOSLocationTracker: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var latest: CLLocation?
    @Published private(set) var denied = false
    @Published private(set) var reducedAccuracy = false

    private let manager = CLLocationManager()
    private(set) var running = false

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
        manager.requestLocation()
    }

    func stop() {
        running = false
        manager.stopUpdatingLocation()
        latest = nil
    }

    private func refreshAccuracyAuthorization() {
        reducedAccuracy = manager.accuracyAuthorization == .reducedAccuracy
        if reducedAccuracy {
            manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: Self.purposeKey)
        }
    }

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
