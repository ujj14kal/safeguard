import Foundation

public struct UnwantedGestureCounter: Sendable {
    public enum Event: Sendable, Equatable {
        case counted(total: Int)
        case exceeded(total: Int)
    }

    public var minFrames = 2
    public var gapSeconds: TimeInterval = 1.0
    public var windowSeconds: TimeInterval = 120
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

    public mutating func feed(hostile: Bool, at time: TimeInterval) -> Event? {
        episodeTimes.removeAll { time - $0 > windowSeconds }
        if !hostile {
            if time - lastHostile >= gapSeconds {
                streak = 0
                countedThisStreak = false
            }
            return nil
        }
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
