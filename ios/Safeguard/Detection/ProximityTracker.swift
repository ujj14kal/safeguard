import Foundation

/// How close the nearest tracked person is. DISPLAY ONLY: proximity never
/// triggers alerts or escalation. Ordered clear < near < tooClose.
public enum Proximity: Int, Sendable, Equatable, Comparable, CaseIterable {
    case clear
    case near
    case tooClose

    public static func < (lhs: Proximity, rhs: Proximity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Status text. Deliberately distinct from the SOS treatment.
    public var title: String {
        switch self {
        case .clear: String(localized: "Clear")
        case .near: String(localized: "Someone is near")
        case .tooClose: String(localized: "Too close")
        }
    }

    /// Spoken on level changes (not every frame).
    public var announcement: String { title }

    /// Never colour alone: every level has its own symbol. Red `tooClose`
    /// uses a warning triangle, never the SOS circle.
    public var symbolName: String {
        switch self {
        case .clear: "shield.fill"
        case .near: "person.fill"
        case .tooClose: "exclamationmark.triangle.fill"
        }
    }
}

/// Nearest-person proximity with hold-to-rise and hysteresis hold-to-fall,
/// so box jitter never flashes colours. Pure; all times are seconds.
/// Not thread-safe: call from one serial queue.
public struct ProximityTracker: Sendable {
    public private(set) var level: Proximity = .clear

    private let config: ThreatConfig
    private var riseStart: TimeInterval?
    private var riseTarget: Proximity = .clear
    private var fallStart: TimeInterval?

    public init(config: ThreatConfig = ThreatConfig()) {
        self.config = config
    }

    public mutating func reset() {
        level = .clear
        riseStart = nil
        riseTarget = .clear
        fallStart = nil
    }

    /// Feed the nearest live box height (nil = no people) at a timestamp in
    /// seconds. Returns the (possibly changed) level.
    @discardableResult
    public mutating func update(nearestHeight: Double?, at time: TimeInterval) -> Proximity {
        switch level {
        case .clear:
            if let height = nearestHeight, height >= config.tooCloseHeight {
                return holdRise(to: .tooClose, at: time)
            }
            if let height = nearestHeight, height >= config.nearHeight {
                return holdRise(to: .near, at: time)
            }
            riseStart = nil
            return .clear
        case .near:
            if let height = nearestHeight, height >= config.tooCloseHeight {
                return holdRise(to: .tooClose, at: time)
            }
            if heightIsBelow(nearestHeight, config.nearHeight - config.proximityHysteresis) {
                return holdFall(to: targetLevel(for: nearestHeight), at: time)
            }
            fallStart = nil
            return .near
        case .tooClose:
            if heightIsBelow(nearestHeight, config.tooCloseHeight - config.proximityHysteresis) {
                return holdFall(to: targetLevel(for: nearestHeight), at: time)
            }
            fallStart = nil
            return .tooClose
        }
    }

    private func targetLevel(for height: Double?) -> Proximity {
        guard let height else { return .clear }
        if height >= config.tooCloseHeight { return .tooClose }
        if height >= config.nearHeight { return .near }
        return .clear
    }

    private func heightIsBelow(_ height: Double?, _ bound: Double) -> Bool {
        guard let height else { return true }
        return height < bound
    }

    private mutating func holdRise(to target: Proximity, at time: TimeInterval) -> Proximity {
        if riseTarget != target || riseStart == nil {
            riseTarget = target
            riseStart = time
        }
        fallStart = nil
        if time - (riseStart ?? time) >= config.proximityRiseHold {
            riseStart = nil
            level = target
            return target
        }
        return level
    }

    private mutating func holdFall(to target: Proximity, at time: TimeInterval) -> Proximity {
        if fallStart == nil {
            fallStart = time
        }
        riseStart = nil
        if time - (fallStart ?? time) >= config.proximityFallHold {
            fallStart = nil
            level = target
            return target
        }
        return level
    }
}
