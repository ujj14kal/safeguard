import Foundation

public final class LatencyMeter: @unchecked Sendable {
    public static let shared = LatencyMeter()

    public struct Stats: Equatable, Sendable {
        public var count: Int
        public var meanMs: Double
        public var p95Ms: Double
        public var maxMs: Double
    }

    private let capacity: Int
    private var samples: [String: [Double]] = [:]
    private let lock = NSLock()

    public init(capacity: Int = 90) {
        self.capacity = capacity
    }

    public func record(_ stage: String, ms: Double) {
        lock.lock(); defer { lock.unlock() }
        var list = samples[stage, default: []]
        list.append(ms)
        if list.count > capacity { list.removeFirst(list.count - capacity) }
        samples[stage] = list
    }

    @discardableResult
    public func measure<T>(_ stage: String, _ work: () throws -> T) rethrows -> T {
        let start = ProcessInfo.processInfo.systemUptime
        defer { record(stage, ms: (ProcessInfo.processInfo.systemUptime - start) * 1000) }
        return try work()
    }

    public func stats(_ stage: String) -> Stats? {
        lock.lock(); defer { lock.unlock() }
        guard let list = samples[stage], !list.isEmpty else { return nil }
        let sorted = list.sorted()
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        return Stats(
            count: list.count, meanMs: list.reduce(0, +) / Double(list.count),
            p95Ms: p95, maxMs: sorted.last ?? 0
        )
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        samples = [:]
    }

    public func summary(stages: [String]) -> String {
        stages.compactMap { stage in
            guard let s = stats(stage) else { return nil }
            return String(format: "%@ %.0f ms (p95 %.0f)", stage, s.meanMs, s.p95Ms)
        }.joined(separator: " • ")
    }
}
