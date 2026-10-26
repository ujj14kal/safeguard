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

    public init(
        trend: Double = 0,
        speed: Double = 0,
        persistence: Double = 0,
        reappearing: Bool = false,
        facing: Double = 0,
        isolation: Double = 0,
        blocking: Double = 0,
        cornering: Double = 0
    ) {
        self.trend = trend
        self.speed = speed
        self.persistence = persistence
        self.reappearing = reappearing
        self.facing = facing
        self.isolation = isolation
        self.blocking = blocking
        self.cornering = cornering
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
        var others: Int
    }

    private var histories: [Int: [Sample]] = [:]

    public init(config: ThreatConfig = ThreatConfig()) {
        self.config = config
    }

    public func reset() {
        histories = [:]
    }

    /// Record one detection tick. Pass matched (live) tracks only; gaps in a
    /// track's samples are its undetected spans. Times are seconds on any
    /// consistent clock (production uses monotonic uptime).
    public func update(tracks: [Track], at time: TimeInterval) {
        let live = tracks.filter { $0.missed == 0 }
        for track in live {
            histories[track.id, default: []].append(Sample(
                time: time, box: track.box, pose: track.pose, others: live.count - 1
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

        let approach = window(samples, time, config.approachWindow)
        if let slope = slope(of: approach.map { ($0.time, Double($0.box.height)) }),
           let medianH = median(approach.map { Double($0.box.height) }), medianH > 0
        {
            let growth = slope * config.approachWindow / medianH
            features.trend = clamp01(growth / config.growthForMax)
            features.speed = clamp01(slope / config.speedForMax)
        }

        let presence = window(samples, time, config.persistenceWindow)
        features.persistence = clamp01(
            Double(presence.count) * config.detectionPeriod / config.persistenceTime
        )
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

        if let lateral = slope(of: approach.map { ($0.time, Double($0.box.midX)) }),
           let lastX = approach.last.map({ Double($0.box.midX) })
        {
            let steadiness = clamp01(1 - abs(lateral) / config.interceptMaxDrift)
            let centre = clamp01(1 - abs(lastX - 0.5) / 0.5)
            features.cornering = features.speed * centre * steadiness
        }

        return features
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
