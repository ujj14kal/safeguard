import Foundation

/// Edge-triggered backend verification gate. Fires once when the max
/// on-device score crosses the threshold, then re-arms only after the score
/// falls back below threshold minus margin. This is what makes /verify
/// "only above threshold, never per frame". Proximity never reaches here.
public struct VerifierGate: Sendable {
    public private(set) var armed = true

    private let threshold: Double
    private let rearmMargin: Double

    public init(config: ThreatConfig = ThreatConfig()) {
        self.threshold = config.alertThreshold
        self.rearmMargin = config.verifyRearmMargin
    }

    /// Returns true exactly on rising crossings.
    public mutating func consume(maxScore: Double) -> Bool {
        if armed, maxScore >= threshold {
            armed = false
            return true
        }
        if maxScore < threshold - rearmMargin {
            armed = true
        }
        return false
    }

    public mutating func reset() {
        armed = true
    }
}

/// Backend behaviour check for a person who stays close, even with no
/// movement alert: held objects, gestures and expression are judged by the
/// backend model, not by the on-device scorer. Fires once the person has
/// been near for `nearSeconds`, then at most every `interval` seconds.
public struct NearSweepGate: Sendable {
    private let nearSeconds: TimeInterval
    private let interval: TimeInterval
    private var nearSince: TimeInterval?
    private var lastFire: TimeInterval?

    public init(config: ThreatConfig = ThreatConfig()) {
        self.nearSeconds = config.sweepNearSeconds
        self.interval = config.sweepIntervalSeconds
    }

    public mutating func consume(isNear: Bool, at time: TimeInterval) -> Bool {
        guard isNear else {
            nearSince = nil
            return false
        }
        let since = nearSince ?? time
        nearSince = since
        guard time - since >= nearSeconds else { return false }
        if let last = lastFire, time - last < interval { return false }
        lastFire = time
        return true
    }

    /// Another trigger just sent a clip: do not send a second one at once.
    public mutating func noteSent(at time: TimeInterval) {
        lastFire = time
    }

    public mutating func reset() {
        nearSince = nil
        lastFire = nil
    }
}
