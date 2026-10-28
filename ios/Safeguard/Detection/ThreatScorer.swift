import Foundation

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
        let closingIn = max(features.trend, features.speed, features.cornering)
        let strongSpeech = features.speech >= config.reasonThreshold
        let strongHand = features.handReach >= config.reasonThreshold
        if closingIn < config.motionMin, !features.reappearing, !strongSpeech, !strongHand {
            value = min(value, config.staticScoreCap)
        }
        value = min(1, value + features.speech * config.weightSpeech
            + features.handReach * config.weightHandReach
            + features.shouting * config.weightShouting
            + features.hostileGesture * config.weightHostileGesture
            + features.angryFace * config.weightAngryFace)
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
        if features.hostileGesture >= config.reasonThreshold {
            reasons.append("hostile hand gesture")
        }
        if features.angryFace >= config.reasonThreshold {
            reasons.append("angry face")
        }
        return ThreatScore(
            value: value,
            alert: value >= config.alertThreshold,
            reasons: reasons
        )
    }
}
