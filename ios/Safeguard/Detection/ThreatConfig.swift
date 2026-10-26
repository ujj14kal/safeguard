import Foundation

/// Every threshold, window and weight for on-device threat scoring.
/// Detection runs at ~5 Hz; all windows are explicit seconds, never frames.
/// Tune here (and only here) — never magic numbers at call sites.
public struct ThreatConfig: Sendable {
    public init() {}

    // MARK: - Time windows (seconds)

    /// How far back facing/isolation features look.
    public var featureWindow: TimeInterval = 8
    /// Window for growth/speed regression and bearing stability.
    public var approachWindow: TimeInterval = 3
    /// Window for presence accounting and reappearance.
    public var persistenceWindow: TimeInterval = 10
    /// Window for corridor blocking fraction.
    public var corridorWindow: TimeInterval = 4
    /// Nominal detection period (5 Hz). Used to convert sample counts to seconds.
    public var detectionPeriod: TimeInterval = 0.2

    // MARK: - Distance trend / approach speed (box height, upper-body boxes)

    /// Relative height growth over `approachWindow` that maps to trend 1.0.
    public var growthForMax: Double = 0.6
    /// Height slope (normalized units/sec) that maps to speed 1.0.
    public var speedForMax: Double = 0.12

    // MARK: - Persistence

    /// Matched presence seconds that map to persistence 1.0.
    public var persistenceTime: TimeInterval = 6
    /// A matched gap longer than this, followed by re-detection of the same
    /// track, counts as reappearing.
    public var reappearMinGap: TimeInterval = 1
    /// Bonus added to persistence when reappearing (capped at 1.0).
    public var reappearBonus: Double = 0.25

    // MARK: - Facing (pose)

    public var facingNoseWeight: Double = 0.5
    public var facingEyeWeight: Double = 0.25 // per eye
    /// Shoulder spread below this (normalized units) gates the facing score.
    public var facingMinSpread: Double = 0.08

    // MARK: - Isolation

    /// Average other-people count that maps to isolation 0.0.
    public var isolationCrowdCount: Double = 4

    // MARK: - Blocking / cornering (normalized coords, centre x = 0.5)

    public var corridorHalfWidth: Double = 0.18
    /// Box height (normalized) above which someone counts as near.
    public var blockingMinHeight: Double = 0.25
    /// Lateral speed (normalized units/sec) below which bearing counts as stable.
    public var interceptMaxDrift: Double = 0.05

    // MARK: - Pose association

    /// Max centre distance (normalized) for pose-to-detection fallback matching.
    public var poseMatchDistance: Double = 0.25

    // MARK: - Scoring weights (normalized internally; need not sum to 1)

    public var weightTrend: Double = 0.20
    public var weightSpeed: Double = 0.20
    public var weightPersistence: Double = 0.15
    public var weightFacing: Double = 0.15
    public var weightIsolation: Double = 0.10
    public var weightBlocking: Double = 0.10
    public var weightCornering: Double = 0.10

    /// Score at or above this raises an alert. Tuned so slow following
    /// (~0.59 synthetic) clears with margin while crowds (~0.29) stay out.
    public var alertThreshold: Double = 0.50
    /// Feature value at or above this earns a human-readable reason.
    public var reasonThreshold: Double = 0.5
}
