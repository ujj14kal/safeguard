import Foundation

public struct VerifierGate: Sendable {
    public private(set) var armed = true

    private let threshold: Double
    private let rearmMargin: Double

    public init(config: ThreatConfig = ThreatConfig()) {
        self.threshold = config.alertThreshold
        self.rearmMargin = config.verifyRearmMargin
    }

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

    public mutating func noteSent(at time: TimeInterval) {
        lastFire = time
    }

    public mutating func reset() {
        nearSince = nil
        lastFire = nil
    }
}
