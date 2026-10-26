import Foundation

/// Scored threat for one tracked person: a 0...1 value, an alert flag, and
/// the features that fired (for logging and the spoken summary later).
public struct ThreatScore: Sendable, Equatable {
    public var value: Double
    public var alert: Bool
    public var reasons: [String]

    public init(value: Double, alert: Bool, reasons: [String]) {
        self.value = value
        self.alert = alert
        self.reasons = reasons
    }
}

/// Weighted-sum scorer over normalized behaviour features. Linear and
/// explainable by design; weights live in ThreatConfig.
public struct ThreatScorer: Sendable {
    public let config: ThreatConfig

    public init(config: ThreatConfig = ThreatConfig()) {
        self.config = config
    }

    public func score(_ features: PersonFeatures) -> ThreatScore {
        let parts: [(reason: String, value: Double, weight: Double)] = [
            ("approaching", features.trend, config.weightTrend),
            ("fast approach", features.speed, config.weightSpeed),
            ("persistent", features.persistence, config.weightPersistence),
            ("facing you", features.facing, config.weightFacing),
            ("isolated", features.isolation, config.weightIsolation),
            ("blocking the way", features.blocking, config.weightBlocking),
            ("cutting you off", features.cornering, config.weightCornering),
        ]
        let totalWeight = parts.map(\.weight).reduce(0, +)
        let value = totalWeight > 0
            ? parts.map { $0.value * $0.weight }.reduce(0, +) / totalWeight
            : 0
        let reasons = parts
            .filter { $0.value >= config.reasonThreshold }
            .map(\.reason)
        return ThreatScore(
            value: value,
            alert: value >= config.alertThreshold,
            reasons: reasons
        )
    }
}
