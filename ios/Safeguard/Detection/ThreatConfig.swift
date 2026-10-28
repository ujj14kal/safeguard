import Foundation

public struct ThreatConfig: Sendable {
    public init() {}

    public var featureWindow: TimeInterval = 8
    public var approachWindow: TimeInterval = 3
    public var persistenceWindow: TimeInterval = 10
    public var corridorWindow: TimeInterval = 4
    public var detectionPeriod: TimeInterval = 0.2

    public var minTrendSamples: Int = 6
    public var minTrendSpan: TimeInterval = 1.0

    public var growthForMax: Double = 0.6
    public var speedForMax: Double = 0.12

    public var persistenceTime: TimeInterval = 6
    public var reappearMinGap: TimeInterval = 1
    public var reappearBonus: Double = 0.25

    public var facingNoseWeight: Double = 0.5
    public var facingEyeWeight: Double = 0.25
    public var facingMinSpread: Double = 0.08

    public var isolationCrowdCount: Double = 4

    public var corridorHalfWidth: Double = 0.18
    public var blockingMinHeight: Double = 0.25
    public var interceptMaxDrift: Double = 0.05

    public var poseMatchDistance: Double = 0.25

    public var nearHeight: Double = 0.30
    public var tooCloseHeight: Double = 0.45
    public var proximityRiseHold: TimeInterval = 0.6
    public var proximityFallHold: TimeInterval = 1.0
    public var proximityHysteresis: Double = 0.05

    public var weightTrend: Double = 0.20
    public var weightSpeed: Double = 0.20
    public var weightPersistence: Double = 0.15
    public var weightFacing: Double = 0.15
    public var weightIsolation: Double = 0.10
    public var weightBlocking: Double = 0.10
    public var weightCornering: Double = 0.10

    public var handNearHeight: Double = 0.12
    public var handReachHeightForMax: Double = 0.30
    public var handSpeedForMax: Double = 0.25
    public var mouthOpenThreshold: Double = 0.45
    public var minMouthSamples: Int = 3
    public var weightHandReach: Double = 0.25
    public var weightShouting: Double = 0.15

    public var minGestureSamples: Int = 3
    public var gestureMinScore: Double = 0.6
    public var gestureGain: Double = 2.0
    public var expressionMinScore: Double = 0.45
    public var weightHostileGesture: Double = 0.30
    public var weightAngryFace: Double = 0.08

    public var egoStillAccel: Double = 0.04
    public var egoMovingAccel: Double = 0.20
    public var egoMaxDiscount: Double = 0.85
    public var egoWindow: TimeInterval = 1.5

    public var sweepNearSeconds: TimeInterval = 3
    public var sweepIntervalSeconds: TimeInterval = 20

    public var weightSpeech: Double = 0.30
    public var speechWindowSeconds: TimeInterval = 20

    public var alertThreshold: Double = 0.50
    public var alertHysteresis: Double = 0.10
    public var verifyRearmMargin: Double = 0.10
    public var reasonThreshold: Double = 0.5

    public var motionMin: Double = 0.15
    public var staticScoreCap: Double = 0.35

    public func nextAlert(wasAlert: Bool, topScore: Double) -> Bool {
        topScore >= (wasAlert ? alertThreshold - alertHysteresis : alertThreshold)
    }
}
