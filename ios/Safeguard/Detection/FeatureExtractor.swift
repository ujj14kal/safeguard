import CoreGraphics
import Foundation

/// Behaviour features for one tracked person. All values are normalized
/// 0...1 (higher = more threatening); see ThreatConfig for the mapping.
public struct PersonFeatures: Sendable, Equatable {
    /// Relative box-height growth over the approach window.
    public var trend: Double
    /// Box-height slope (normalized units/sec), normalized.
    public var speed: Double
    /// Matched presence seconds over the persistence window, normalized,
    /// plus a bonus when reappearing.
    public var persistence: Double
    /// The same track vanished for a real gap and came back.
    public var reappearing: Bool
    /// Mean facing-toward-user score over samples with a known pose.
    public var facing: Double
    /// 1 when alone, 0 in a crowd.
    public var isolation: Double
    /// Fraction of the corridor window spent near and in the forward corridor.
    public var blocking: Double
    /// Intercept course: approaching + near centre + stable bearing.
    public var cornering: Double
    /// Latest speech severity (global, not per-track): threatening or
    /// harassing talk near the wearer. Stamped by the extractor while fresh.
    public var speech: Double
    /// A hand close to the camera and, if it is growing, lunging at it.
    public var handReach: Double
    /// Fraction of recent samples with the mouth wide open (shouting).
    public var shouting: Double
    /// Fraction of recent samples showing a hostile hand gesture (middle
    /// finger), weighted by how sure the classifier was.
    public var hostileGesture: Double
    /// Fraction of recent samples with an angry face.
    public var angryFace: Double

    public init(
        trend: Double = 0,
        speed: Double = 0,
        persistence: Double = 0,
        reappearing: Bool = false,
        facing: Double = 0,
        isolation: Double = 0,
        blocking: Double = 0,
        cornering: Double = 0,
        speech: Double = 0,
        handReach: Double = 0,
        shouting: Double = 0,
        hostileGesture: Double = 0,
        angryFace: Double = 0
    ) {
        self.trend = trend
        self.speed = speed
        self.persistence = persistence
        self.reappearing = reappearing
        self.facing = facing
        self.isolation = isolation
        self.blocking = blocking
        self.cornering = cornering
        self.speech = speech
        self.handReach = handReach
        self.shouting = shouting
        self.hostileGesture = hostileGesture
        self.angryFace = angryFace
    }
}

/// Builds per-track behaviour features from timestamped track history.
/// Feed live tracks at detection rate; all windows are seconds.
public final class FeatureExtractor {
    public let config: ThreatConfig

    private struct Sample: Sendable {
        var time: TimeInterval
        var box: CGRect
        var pose: BodyPose?
        var cues: GestureCues?
        var others: Int
    }

    private var histories: [Int: [Sample]] = [:]
    private var egoSamples: [(time: TimeInterval, level: Double)] = []

    /// Latest speech severity + when it was reported. Speech is global
    /// (the mic hears the scene, not one track), so one value is stamped
    /// onto every track's features while fresh.
    private var speechSeverity = 0.0
    private var speechAt: TimeInterval = -.infinity

    public init(config: ThreatConfig = ThreatConfig()) {
        self.config = config
    }

    /// Wearer motion level 0 (still) ... 1 (walking or swinging the phone),
    /// from the phone's accelerometer. Without it every level is 0, so a
    /// replayed video keeps the old behaviour.
    public func setEgoMotion(accelRMS: Double, at time: TimeInterval) {
        let span = max(config.egoMovingAccel - config.egoStillAccel, 1e-6)
        egoSamples.append((time, clamp01((accelRMS - config.egoStillAccel) / span)))
        egoSamples.removeAll { time - $0.time > maxWindow }
    }

    public func reset() {
        egoSamples = []
        histories = [:]
        speechSeverity = 0
        speechAt = -.infinity
    }

    /// Report the listener's latest speech severity (0...1, clamped).
    public func setSpeech(severity: Double, at time: TimeInterval) {
        speechSeverity = clamp01(severity)
        speechAt = time
    }

    /// Record one detection tick. Pass matched (live) tracks only; gaps in a
    /// track's samples are its undetected spans. Times are seconds on any
    /// consistent clock (production uses monotonic uptime).
    public func update(tracks: [Track], at time: TimeInterval) {
        let live = tracks.filter { $0.missed == 0 }
        for track in live {
            histories[track.id, default: []].append(Sample(
                time: time, box: track.box, pose: track.pose, cues: track.cues,
                others: live.count - 1
            ))
        }
        let cutoff = time - maxWindow
        for id in histories.keys {
            histories[id]?.removeAll { $0.time < cutoff }
            if histories[id]?.isEmpty == true {
                histories.removeValue(forKey: id)
            }
        }
    }

    /// Features for a track, or nil when it has no samples in range.
    public func features(for trackID: Int, at time: TimeInterval) -> PersonFeatures? {
        guard let samples = histories[trackID], !samples.isEmpty else { return nil }
        var features = PersonFeatures()
        if time - speechAt <= config.speechWindowSeconds {
            features.speech = speechSeverity
        }

        let approach = window(samples, time, config.approachWindow)
        let enoughHistory = hasEnoughHistory(approach)
        if enoughHistory,
           let slope = slope(of: approach.map { ($0.time, Double($0.box.height)) }),
           let medianH = median(approach.map { Double($0.box.height) }), medianH > 0
        {
            let growth = slope * config.approachWindow / medianH
            features.trend = clamp01(growth / config.growthForMax)
            features.speed = clamp01(slope / config.speedForMax)
        }

        let presence = window(samples, time, config.persistenceWindow)
        features.persistence = clamp01(matchedSeconds(presence) / config.persistenceTime)
        features.reappearing = hasGap(presence, longerThan: config.reappearMinGap)
        if features.reappearing {
            features.persistence = min(1, features.persistence + config.reappearBonus)
        }

        let faced = window(samples, time, config.featureWindow).compactMap(\.pose)
        if !faced.isEmpty {
            features.facing = faced.map { $0.facingScore(using: config) }.reduce(0, +)
                / Double(faced.count)
        }

        let social = window(samples, time, config.featureWindow)
        if !social.isEmpty {
            let meanOthers = Double(social.map(\.others).reduce(0, +)) / Double(social.count)
            features.isolation = clamp01(1 - meanOthers / config.isolationCrowdCount)
        }

        let corridor = window(samples, time, config.corridorWindow)
        if !corridor.isEmpty {
            let blocked = corridor.filter {
                abs($0.box.midX - 0.5) < config.corridorHalfWidth
                    && Double($0.box.height) >= config.blockingMinHeight
            }
            features.blocking = Double(blocked.count) / Double(corridor.count)
        }

        if enoughHistory,
           let lateral = slope(of: approach.map { ($0.time, Double($0.box.midX)) }),
           let lastX = approach.last.map({ Double($0.box.midX) })
        {
            let steadiness = clamp01(1 - abs(lateral) / config.interceptMaxDrift)
            let centre = clamp01(1 - abs(lastX - 0.5) / 0.5)
            features.cornering = features.speed * centre * steadiness
        }

        applyEgoMotionDiscount(to: &features, at: time)
        applyCues(to: &features, samples: samples, at: time)
        return features
    }

    /// A box that grows while the WEARER moves (walking up to a still
    /// person) is mostly the wearer closing in. Discount the approach
    /// features by the recent motion level; a still wearer keeps full weight.
    private func applyEgoMotionDiscount(to features: inout PersonFeatures, at time: TimeInterval) {
        let recent = egoSamples.filter { time - $0.time <= config.egoWindow }
        guard !recent.isEmpty else { return }
        let level = recent.map(\.level).reduce(0, +) / Double(recent.count)
        let keep = 1 - config.egoMaxDiscount * level
        features.trend *= keep
        features.speed *= keep
        features.cornering *= keep
    }

    /// Hand reach: the closest hand's size, scaled up when that hand is
    /// growing (a lunge). Shouting: how often the mouth is wide open.
    private func applyCues(to features: inout PersonFeatures, samples: [Sample], at time: TimeInterval) {
        let recent = window(samples, time, config.featureWindow)
        let withCues = recent.filter { $0.cues != nil }
        guard !withCues.isEmpty else { return }

        let handHeights: [(TimeInterval, Double)] = recent.compactMap { sample in
            guard let top = sample.cues?.hands.map({ Double($0.box.height) }).max() else { return nil }
            return (sample.time, top)
        }
        if let latest = handHeights.last, time - latest.0 <= config.approachWindow {
            let size = clamp01(
                (latest.1 - config.handNearHeight)
                    / max(config.handReachHeightForMax - config.handNearHeight, 1e-6)
            )
            let recentHands = handHeights.filter { time - $0.0 < config.approachWindow }
            var lunge = 0.0
            if recentHands.count >= 3, let growth = slope(of: recentHands) {
                lunge = clamp01(growth / config.handSpeedForMax)
            }
            features.handReach = size * (0.5 + 0.5 * lunge)
        }

        let mouths = recent.compactMap { $0.cues?.mouthOpen }
        if mouths.count >= config.minMouthSamples {
            let open = mouths.filter { $0 >= config.mouthOpenThreshold }.count
            features.shouting = Double(open) / Double(mouths.count)
        }

        // Classified gestures and expressions (MediaPipe engine). Absent
        // cues leave both at 0, so older scores are unchanged.
        let gestureSamples = recent.compactMap { $0.cues }.filter { $0.expression != nil || !$0.gestures.isEmpty }
        if gestureSamples.count >= config.minGestureSamples {
            let hostile = gestureSamples.reduce(0.0) { sum, cues in
                let best = cues.gestures.filter(\.isHostile).map(\.score).max() ?? 0
                return sum + (best >= config.gestureMinScore ? best : 0)
            }
            features.hostileGesture = clamp01(hostile / Double(gestureSamples.count) * config.gestureGain)
            let angry = gestureSamples.filter {
                guard let expression = $0.expression else { return false }
                return expression.kind == .angry && expression.score >= config.expressionMinScore
            }.count
            features.angryFace = Double(angry) / Double(gestureSamples.count)
        }
    }

    // MARK: - Helpers

    private var maxWindow: TimeInterval {
        max(
            config.featureWindow,
            config.approachWindow,
            config.persistenceWindow,
            config.corridorWindow
        )
    }

    private func window(_ samples: [Sample], _ time: TimeInterval, _ span: TimeInterval) -> [Sample] {
        samples.filter { $0.time > time - span }
    }

    /// Enough matched samples, over enough time, for a slope to mean motion
    /// rather than box jitter. Samples are in time order.
    private func hasEnoughHistory(_ samples: [Sample]) -> Bool {
        guard samples.count >= config.minTrendSamples,
              let first = samples.first, let last = samples.last
        else {
            return false
        }
        return last.time - first.time >= config.minTrendSpan
    }

    /// Seconds the track was actually matched, from sample timestamps (not a
    /// count times a nominal period, which under-counts when detection runs
    /// slower than 5 Hz). Gaps longer than `reappearMinGap` were not presence.
    /// The latest sample is credited one nominal period.
    private func matchedSeconds(_ samples: [Sample]) -> TimeInterval {
        guard !samples.isEmpty else { return 0 }
        let times = samples.map(\.time).sorted()
        let continuous = zip(times, times.dropFirst())
            .map { $1 - $0 }
            .filter { $0 <= config.reappearMinGap }
            .reduce(0, +)
        return continuous + config.detectionPeriod
    }

    /// Least-squares slope, or nil with fewer than 2 samples or no time span.
    private func slope(of points: [(TimeInterval, Double)]) -> Double? {
        guard points.count >= 2 else { return nil }
        let n = Double(points.count)
        let sumT = points.map(\.0).reduce(0, +)
        let sumV = points.map(\.1).reduce(0, +)
        let meanT = sumT / n
        let meanV = sumV / n
        var denom = 0.0
        var numer = 0.0
        for (t, v) in points {
            denom += (t - meanT) * (t - meanT)
            numer += (t - meanT) * (v - meanV)
        }
        guard denom > 0 else { return nil }
        return numer / denom
    }

    private func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        if sorted.count % 2 == 1 {
            return sorted[sorted.count / 2]
        }
        return (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    private func hasGap(_ samples: [Sample], longerThan gap: TimeInterval) -> Bool {
        let times = samples.map(\.time).sorted()
        return zip(times, times.dropFirst()).contains { $1 - $0 > gap }
    }

    private func clamp01(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}
