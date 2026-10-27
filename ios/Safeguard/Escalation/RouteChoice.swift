import Foundation

/// One staffed/public place the route search found, with MapKit's walking
/// distance and ETA. Pure data: MapKit lives in the view model, the choice
/// rule lives here where tests pin it.
public struct RouteCandidate: Sendable, Equatable {
    public var name: String
    public var distanceMeters: Double
    public var etaSeconds: Double

    public init(name: String, distanceMeters: Double, etaSeconds: Double) {
        self.name = name
        self.distanceMeters = distanceMeters
        self.etaSeconds = etaSeconds
    }
}

/// "Safest" route choice: the lowest walking ETA among the nearest 3
/// staffed/public places (police stations, hospitals). This is NOT a
/// crime-risk model — it answers "where can people help me fastest".
public enum RouteChoice {
    /// Shown instead of failing silently when there is no route.
    public static let noLocationMessage = String(localized: "Location unavailable")
    public static let waitingForLocationMessage = String(localized: "Waiting for location…")
    public static let noPlacesMessage = String(localized: "No staffed places found nearby")
    public static let noRouteMessage = String(localized: "No walking route found")

    public static func pick(from candidates: [RouteCandidate]) -> RouteCandidate? {
        let nearest = candidates.sorted { $0.distanceMeters < $1.distanceMeters }.prefix(3)
        return nearest.min { $0.etaSeconds < $1.etaSeconds }
    }
}
