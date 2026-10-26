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
