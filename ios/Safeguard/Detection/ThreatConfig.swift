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
    /// Nominal detection period (5 Hz): the dwell credited to the latest
    /// sample when measuring presence. Elapsed time itself comes from sample
    /// timestamps, so a slower real detection rate is not under-counted.
    public var detectionPeriod: TimeInterval = 0.2

    // MARK: - Minimum evidence

    /// Trend, speed and lateral drift are least-squares slopes. With only a
    /// couple of samples, ordinary box jitter reads as a fast approach, so a
    /// new track needs at least this many matched samples in the window...
    public var minTrendSamples: Int = 6
    /// ...spanning at least this many seconds, before they count.
    public var minTrendSpan: TimeInterval = 1.0

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

    // MARK: - Proximity display (DISPLAY ONLY; never triggers alerts)

    /// Normalized upper-body box heights for the proximity levels. GUESSES —
    /// tune on real clips (Phase 8). Do not hard-code heights elsewhere.
    public var nearHeight: Double = 0.30
    public var tooCloseHeight: Double = 0.45
    /// Seconds the condition must hold before the level rises (box jitter
    /// and people stepping into view must not flash colours).
    public var proximityRiseHold: TimeInterval = 0.6
    /// Seconds below (threshold - hysteresis) before the level falls.
    public var proximityFallHold: TimeInterval = 1.0
    /// Hysteresis margin (normalized height) for falling.
    public var proximityHysteresis: Double = 0.05

    // MARK: - Scoring weights (normalized internally; need not sum to 1)

    public var weightTrend: Double = 0.20
    public var weightSpeed: Double = 0.20
    public var weightPersistence: Double = 0.15
    public var weightFacing: Double = 0.15
    public var weightIsolation: Double = 0.10
    public var weightBlocking: Double = 0.10
    public var weightCornering: Double = 0.10

    // MARK: - Hands and expression (Vision hand pose + face landmarks)

    /// Hand box height (normalized) where a hand counts as close to the
    /// camera, and where it counts as in your face (feature 1.0).
    public var handNearHeight: Double = 0.12
    public var handReachHeightForMax: Double = 0.30
    /// Hand box-height growth per second that maps to full lunge speed.
    public var handSpeedForMax: Double = 0.25
    /// Inner-lip height/width at or above which the mouth is wide open
    /// (shouting). GUESS: tune on real clips.
    public var mouthOpenThreshold: Double = 0.45
    /// Mouth-open samples needed in the feature window before it counts.
    public var minMouthSamples: Int = 3
    /// Additive weights like speech: absent cues leave every older score
    /// bit-for-bit unchanged.
    public var weightHandReach: Double = 0.25
    public var weightShouting: Double = 0.15

    // MARK: - Wearer motion (CoreMotion)

    /// Phone acceleration (g, RMS over the window) below `egoStillAccel`
    /// means the wearer is standing still; at `egoMovingAccel` or above the
    /// wearer is walking or swinging the phone. Growth of a person's box
    /// while the wearer moves is mostly the wearer closing in, so approach
    /// features are discounted by up to `egoMaxDiscount`.
    public var egoStillAccel: Double = 0.04
    public var egoMovingAccel: Double = 0.20
    public var egoMaxDiscount: Double = 0.85
    public var egoWindow: TimeInterval = 1.5

    // MARK: - Close-person behaviour sweep (backend)

    /// Someone near for this long is sent to the backend for a behaviour
    /// check (held objects, gestures, expression) even without a movement
    /// alert, then again every `sweepIntervalSeconds` while they stay near.
    public var sweepNearSeconds: TimeInterval = 3
    public var sweepIntervalSeconds: TimeInterval = 20

    // MARK: - Speech signal (Part B)

    /// Speech is ADDITIVE, not normalized: value = base + speech * weight
    /// (capped at 1). Silent speech contributes exactly 0, so all Phase 3
    /// tuning and thresholds hold unchanged. GUESS — tune on real clips.
    public var weightSpeech: Double = 0.30
    /// Seconds a speech severity stays fresh after the listener reports it.
    public var speechWindowSeconds: TimeInterval = 20

    /// Score at or above this raises an alert. Tuned so slow following
    /// (~0.59 synthetic) clears with margin while crowds (~0.29) stay out.
    /// Crossing this threshold (rising edge only) also triggers one backend
    /// /verify call — never per frame, never from proximity.
    public var alertThreshold: Double = 0.50
    /// The verify gate re-arms only after the score falls this far below
    /// the threshold.
    public var verifyRearmMargin: Double = 0.10
    /// Feature value at or above this earns a human-readable reason.
    public var reasonThreshold: Double = 0.5

    // MARK: - Static-presence guard

    /// If the strongest of trend/speed/cornering is below this, nobody is
    /// closing in on the user.
    public var motionMin: Double = 0.15
    /// With nobody closing in (and no reappearing), the score is capped here:
    /// presence alone — a stranger standing still, facing you, alone, near
    /// your path — scored 0.49-0.50 against the 0.50 threshold with zero
    /// threatening behaviour. Keep this well below `alertThreshold`.
    public var staticScoreCap: Double = 0.35
}
