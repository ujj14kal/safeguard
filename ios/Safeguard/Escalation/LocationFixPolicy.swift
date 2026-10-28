import CoreLocation
import Foundation
import MapKit

public struct LocationSample: Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var accuracy: Double
    public var timestamp: Date

    public init(latitude: Double, longitude: Double, accuracy: Double, timestamp: Date) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
        self.timestamp = timestamp
    }

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
    case precise
    case usable
    case coarse
}

public enum LocationFixPolicy {
    public static let maxAgeSeconds: Double = 15
    public static let preciseMeters: Double = 65
    public static let usableMeters: Double = 250
    public static let preciseWaitSeconds: Double = 8
    public static let rerouteMeters: Double = 150

    public static func isAcceptable(accuracy: Double, age: Double) -> Bool {
        accuracy >= 0 && age <= maxAgeSeconds
    }

    public static func quality(accuracy: Double) -> LocationQuality {
        if accuracy <= preciseMeters { return .precise }
        if accuracy <= usableMeters { return .usable }
        return .coarse
    }

    public static func shouldReplace(old: LocationSample?, with new: LocationSample, now: Date) -> Bool {
        guard isAcceptable(accuracy: new.accuracy, age: now.timeIntervalSince(new.timestamp)) else {
            return false
        }
        guard let old else { return true }
        if now.timeIntervalSince(old.timestamp) > maxAgeSeconds { return true }
        if new.accuracy < old.accuracy { return true }
        return new.timestamp > old.timestamp && new.accuracy <= old.accuracy + 25
    }

    public static func shouldReroute(from origin: LocationSample, to current: LocationSample) -> Bool {
        let wasCoarse = quality(accuracy: origin.accuracy) != .precise
        if wasCoarse, quality(accuracy: current.accuracy) == .precise,
           origin.distance(to: current) > preciseMeters
        {
            return true
        }
        return origin.distance(to: current) > rerouteMeters
    }

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

public struct SOSPlace: Identifiable, Equatable {
    public let id: String
    public var name: String
    public var kind: SOSPlaceKind
    public var coordinate: CLLocationCoordinate2D
    public var distance: Double

    public static func == (lhs: SOSPlace, rhs: SOSPlace) -> Bool { lhs.id == rhs.id }
}

public enum MapFraming {
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
