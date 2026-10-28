import Foundation

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

public enum RouteChoice {
    public static let noLocationMessage = String(localized: "Location unavailable")
    public static let waitingForLocationMessage = String(localized: "Waiting for location…")
    public static let noPlacesMessage = String(localized: "No staffed places found nearby")
    public static let noRouteMessage = String(localized: "No walking route found")

    public static func pick(from candidates: [RouteCandidate]) -> RouteCandidate? {
        let nearest = candidates.sorted { $0.distanceMeters < $1.distanceMeters }.prefix(3)
        return nearest.min { $0.etaSeconds < $1.etaSeconds }
    }
}
