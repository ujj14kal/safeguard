import Foundation

/// Counts distinct unwanted-gesture episodes (a raised middle finger held
/// for a few frames is ONE episode, not thirty) and fires once when the
/// count within the window goes past the limit. Pure: times are passed in.
public struct UnwantedGestureCounter: Sendable {
    public enum Event: Sendable, Equatable {
        /// A new episode was counted; `total` is the count in the window.
        case counted(total: Int)
        /// More than `limit` episodes inside the window: start the SOS flow.
        case exceeded(total: Int)
    }

    /// Consecutive frames with the gesture before it counts.
    public var minFrames = 3
    /// Hostile-free seconds needed before the next episode can start.
    public var gapSeconds: TimeInterval = 1.0
    /// Episodes older than this stop counting.
    public var windowSeconds: TimeInterval = 120
    /// "More than 5" gestures starts the auto-SOS countdown.
    public var limit = 5

    private var episodeTimes: [TimeInterval] = []
    private var streak = 0
    private var countedThisStreak = false
    private var lastHostile: TimeInterval = -.infinity

    public init() {}

    public var total: Int { episodeTimes.count }

    public mutating func reset() {
        episodeTimes.removeAll()
        streak = 0
        countedThisStreak = false
        lastHostile = -.infinity
    }

    /// Feed one detection frame.
    public mutating func feed(hostile: Bool, at time: TimeInterval) -> Event? {
        episodeTimes.removeAll { time - $0 > windowSeconds }
        if !hostile {
            if time - lastHostile >= gapSeconds {
                streak = 0
                countedThisStreak = false
            }
            return nil
        }
        // A hostile frame after a long enough gap starts a fresh episode.
        if time - lastHostile >= gapSeconds {
            streak = 0
            countedThisStreak = false
        }
        lastHostile = time
        streak += 1
        guard streak >= minFrames, !countedThisStreak else { return nil }
        countedThisStreak = true
        episodeTimes.append(time)
        if episodeTimes.count > limit {
            let count = episodeTimes.count
            episodeTimes.removeAll()
            return .exceeded(total: count)
        }
        return .counted(total: episodeTimes.count)
    }
}
