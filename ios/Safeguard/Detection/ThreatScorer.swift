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
        var value = totalWeight > 0
            ? parts.map { $0.value * $0.weight }.reduce(0, +) / totalWeight
            : 0
        // Presence alone (persistent + facing + isolated + near the path) must
        // never alert: require somebody closing in, or a track that reappeared.
        // A strong speech signal bypasses the cap: words can threaten where
        // bodies stand still.
        let closingIn = max(features.trend, features.speed, features.cornering)
        let strongSpeech = features.speech >= config.reasonThreshold
        let strongHand = features.handReach >= config.reasonThreshold
        if closingIn < config.motionMin, !features.reappearing, !strongSpeech, !strongHand {
            value = min(value, config.staticScoreCap)
        }
        // Speech is additive (never normalized in): silent speech leaves
        // every Phase 3 value bit-for-bit identical.
        value = min(1, value + features.speech * config.weightSpeech
            + features.handReach * config.weightHandReach
            + features.shouting * config.weightShouting)
        var reasons = parts
            .filter { $0.value >= config.reasonThreshold }
            .map(\.reason)
        if strongSpeech {
            reasons.append("threatening speech")
        }
        if strongHand {
            reasons.append("hand reaching toward you")
        }
        if features.shouting >= config.reasonThreshold {
            reasons.append("shouting or aggressive expression")
        }
        return ThreatScore(
            value: value,
            alert: value >= config.alertThreshold,
            reasons: reasons
        )
    }
}
