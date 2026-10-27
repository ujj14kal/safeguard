import CoreLocation
import Foundation
import MapKit

/// One location reading, stripped to what the policy needs (pure, testable).
public struct LocationSample: Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    /// Horizontal accuracy radius in metres (negative = invalid).
    public var accuracy: Double
    public var timestamp: Date

    public init(latitude: Double, longitude: Double, accuracy: Double, timestamp: Date) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
        self.timestamp = timestamp
    }

    /// Great-circle distance in metres.
    public func distance(to other: LocationSample) -> Double {
        let radius = 6_371_000.0
        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (other.longitude - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * radius * asin(min(1, sqrt(a)))
    }
}

public enum LocationQuality: Equatable, Sendable {
    /// Street-level: good enough to pick the right building.
    case precise
    /// Neighbourhood-level: fine for a route, shown with its error circle.
    case usable
    /// Cell-tower or approximate: only a rough guess.
    case coarse
}

/// Which fixes the SOS flow trusts. The old tracker took whatever Core
/// Location delivered first, which on a cold start is often a cached or
/// cell-tower fix hundreds of metres to kilometres off, and never corrected
/// it. These rules reject stale readings, prefer accurate ones, and tell
/// the route search when to run again.
public enum LocationFixPolicy {
    public static let maxAgeSeconds: Double = 15
    public static let preciseMeters: Double = 65
    public static let usableMeters: Double = 250
    /// How long the route track waits for a precise fix before it goes
    /// ahead with the best one it has (it refines later anyway).
    public static let preciseWaitSeconds: Double = 8
    /// Moving this far (or gaining accuracy) re-runs the route search.
    public static let rerouteMeters: Double = 150

    public static func isAcceptable(accuracy: Double, age: Double) -> Bool {
        accuracy >= 0 && age <= maxAgeSeconds
    }

    public static func quality(accuracy: Double) -> LocationQuality {
        if accuracy <= preciseMeters { return .precise }
        if accuracy <= usableMeters { return .usable }
        return .coarse
    }

    /// Should `new` replace `old` as the best-known position?
    public static func shouldReplace(old: LocationSample?, with new: LocationSample, now: Date) -> Bool {
        guard isAcceptable(accuracy: new.accuracy, age: now.timeIntervalSince(new.timestamp)) else {
            return false
        }
        guard let old else { return true }
        // The old one went stale: any acceptable fresh reading wins.
        if now.timeIntervalSince(old.timestamp) > maxAgeSeconds { return true }
        // Otherwise: strictly better accuracy, or newer and not much worse
        // (a walking user must be tracked, not frozen on one great fix).
        if new.accuracy < old.accuracy { return true }
        return new.timestamp > old.timestamp && new.accuracy <= old.accuracy + 25
    }

    /// Re-run the nearest-help search?
    public static func shouldReroute(from origin: LocationSample, to current: LocationSample) -> Bool {
        let wasCoarse = quality(accuracy: origin.accuracy) != .precise
        if wasCoarse, quality(accuracy: current.accuracy) == .precise,
           origin.distance(to: current) > preciseMeters
        {
            return true
        }
        return origin.distance(to: current) > rerouteMeters
    }

    /// Short text for the SOS map card ("Accurate to about 12 m").
    public static func accuracyText(_ accuracy: Double) -> String {
        let rounded = Int((accuracy / 5).rounded() * 5)
        if accuracy < 10 { return String(localized: "Location: exact") }
        if accuracy >= 1000 {
            return L10n.format("Location: about %.1f km", accuracy / 1000)
        }
        return L10n.format("Location: about %d m", rounded)
    }
}

public enum SOSPlaceKind: Sendable {
    case police
    case hospital

    public var symbol: String {
        switch self {
        case .police: "shield.lefthalf.filled"
        case .hospital: "cross.case.fill"
        }
    }
}

/// A staffed place shown on the SOS map.
public struct SOSPlace: Identifiable, Equatable {
    public let id: String
    public var name: String
    public var kind: SOSPlaceKind
    public var coordinate: CLLocationCoordinate2D
    /// Straight-line metres from the wearer when it was found.
    public var distance: Double

    public static func == (lhs: SOSPlace, rhs: SOSPlace) -> Bool { lhs.id == rhs.id }
}

public enum MapFraming {
    /// Smallest map rect holding `points`, padded and never tighter than
    /// `minimumMeters` across (so a single point is not zoomed to a pin).
    public static func rect(
        covering points: [CLLocationCoordinate2D], minimumMeters: Double
    ) -> MKMapRect? {
        guard !points.isEmpty else { return nil }
        var rect = MKMapRect.null
        for point in points {
            let mapPoint = MKMapPoint(point)
            rect = rect.union(MKMapRect(x: mapPoint.x, y: mapPoint.y, width: 0, height: 0))
        }
        let perMeter = MKMapPointsPerMeterAtLatitude(points[0].latitude)
        let minimum = minimumMeters * perMeter
        let width = max(rect.size.width * 1.5, minimum)
        let height = max(rect.size.height * 1.5, minimum)
        return MKMapRect(
            x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height
        )
    }
}
