import CoreGraphics
import Foundation

public struct PersonFeatures: Sendable, Equatable {
    public var trend: Double
    public var speed: Double
    public var persistence: Double
    public var reappearing: Bool
    public var facing: Double
    public var isolation: Double
    public var blocking: Double
    public var cornering: Double
    public var speech: Double
    public var handReach: Double
    public var shouting: Double
    public var hostileGesture: Double
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

    private var speechSeverity = 0.0
    private var speechAt: TimeInterval = -.infinity

    public init(config: ThreatConfig = ThreatConfig()) {
        self.config = config
    }

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

    public func setSpeech(severity: Double, at time: TimeInterval) {
        speechSeverity = clamp01(severity)
        speechAt = time
    }

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

    private func applyEgoMotionDiscount(to features: inout PersonFeatures, at time: TimeInterval) {
        let recent = egoSamples.filter { time - $0.time <= config.egoWindow }
        guard !recent.isEmpty else { return }
        let level = recent.map(\.level).reduce(0, +) / Double(recent.count)
        let keep = 1 - config.egoMaxDiscount * level
        features.trend *= keep
        features.speed *= keep
        features.cornering *= keep
    }

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

    private func hasEnoughHistory(_ samples: [Sample]) -> Bool {
        guard samples.count >= config.minTrendSamples,
              let first = samples.first, let last = samples.last
        else {
            return false
        }
        return last.time - first.time >= config.minTrendSpan
    }

    private func matchedSeconds(_ samples: [Sample]) -> TimeInterval {
        guard !samples.isEmpty else { return 0 }
        let times = samples.map(\.time).sorted()
        let continuous = zip(times, times.dropFirst())
            .map { $1 - $0 }
            .filter { $0 <= config.reappearMinGap }
            .reduce(0, +)
        return continuous + config.detectionPeriod
    }

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
