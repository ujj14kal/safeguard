import Foundation

public struct ListeningSession: Sendable {
    public enum State: Sendable, Equatable {
        case idle
        case listening(generation: Int, requestStart: TimeInterval)
        case deaf(reason: String)
    }

    public private(set) var state: State = .idle
    private let restartInterval: TimeInterval
    private var recentTaskEnds: [TimeInterval] = []

    public enum TaskEndDecision: Sendable, Equatable {
        case restart
        case deaf(reason: String)
    }

    public init(config: SpeechConfig = SpeechConfig()) {
        self.restartInterval = config.restartIntervalSeconds
    }

    public var isLive: Bool {
        if case .listening = state { return true }
        return false
    }

    public var generation: Int? {
        if case let .listening(generation, _) = state { return generation }
        return nil
    }

    public mutating func start(at time: TimeInterval) {
        switch state {
        case .idle, .deaf:
            state = .listening(generation: 0, requestStart: time)
        case .listening:
            break
        }
    }

    public mutating func stop() {
        state = .idle
    }

    @discardableResult
    public mutating func restartIfDue(at time: TimeInterval) -> Bool {
        if case let .listening(generation, requestStart) = state,
           time - requestStart >= restartInterval
        {
            state = .listening(generation: generation + 1, requestStart: time)
            return true
        }
        return false
    }

    public mutating func noteTaskEnded(at time: TimeInterval) -> TaskEndDecision {
        guard case let .listening(generation, _) = state else { return .restart }
        recentTaskEnds.append(time)
        recentTaskEnds.removeAll { time - $0 > 10 }
        if recentTaskEnds.count >= 8 {
            recentTaskEnds = []
            let reason = "Speech recognition keeps stopping"
            state = .deaf(reason: reason)
            return .deaf(reason: reason)
        }
        state = .listening(generation: generation + 1, requestStart: time)
        return .restart
    }

    public mutating func noteInterruption() {
        switch state {
        case .listening:
            state = .deaf(reason: "Microphone interrupted")
        case .idle, .deaf:
            break
        }
    }

    public mutating func noteError(_ message: String) {
        switch state {
        case .listening:
            state = .deaf(reason: message)
        case .idle, .deaf:
            break
        }
    }
}

public struct PartialReplyGate: Sendable {
    private var handled: UserReply?

    public init() {}

    public mutating func consume(_ reply: UserReply?) -> UserReply? {
        guard let reply, reply != handled else { return nil }
        handled = reply
        return reply
    }

    public mutating func finishUtterance() -> UserReply? {
        defer { handled = nil }
        return handled
    }
}

public enum SpeechHapticLevel: Int, Sendable, Comparable, Equatable {
    case none, nudge, elevated, strong

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public static func level(for severity: Double) -> SpeechHapticLevel {
        switch severity {
        case ..<0.35: .none
        case ..<0.55: .nudge
        case ..<0.7: .elevated
        default: .strong
        }
    }
}

public struct SpeechHapticGate: Sendable {
    private let minInterval: TimeInterval
    private var last: (level: SpeechHapticLevel, at: TimeInterval)?

    public init(minInterval: TimeInterval = 2.5) {
        self.minInterval = minInterval
    }

    public mutating func consume(_ level: SpeechHapticLevel, at time: TimeInterval) -> SpeechHapticLevel {
        guard level != .none else { return .none }
        if let last, time - last.at < minInterval, level <= last.level { return .none }
        last = (level, time)
        return level
    }

    public mutating func reset() { last = nil }
}

public struct ConversationFlag: Sendable, Equatable {
    public var category: SpeechCategory
    public var severity: Double
    public var at: TimeInterval

    public init(category: SpeechCategory, severity: Double, at: TimeInterval) {
        self.category = category
        self.severity = severity
        self.at = at
    }

    public static let minSeverity = 0.45
    public static let showSeconds: TimeInterval = 12

    public var label: String {
        switch category {
        case .threat: String(localized: "Threatening words")
        case .coercion: String(localized: "Someone is pressuring you")
        case .pursuit: String(localized: "Someone may be following you")
        case .proposition: String(localized: "Unwanted advances")
        case .abuse, .anger: String(localized: "Abusive or angry language")
        case .distress: String(localized: "A call for help")
        }
    }

    public func isActive(at time: TimeInterval) -> Bool {
        time - at < Self.showSeconds
    }

    public static func merged(_ current: ConversationFlag?, with new: ConversationFlag) -> ConversationFlag {
        guard let current, current.isActive(at: new.at), current.severity > new.severity else {
            return new
        }
        var kept = current
        kept.at = new.at
        return kept
    }
}

public struct SpeechJudgeSchedule: Sendable {
    private let minInterval: TimeInterval
    private var lastSentAt: TimeInterval?
    private var lastText = ""
    public private(set) var inFlight = false

    public init(minInterval: TimeInterval = 1.5) {
        self.minInterval = minInterval
    }

    public mutating func shouldSend(_ text: String, at time: TimeInterval) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inFlight, trimmed.split(separator: " ").count >= 2, trimmed != lastText else { return false }
        if let last = lastSentAt, time - last < minInterval { return false }
        inFlight = true
        lastSentAt = time
        lastText = trimmed
        return true
    }

    public mutating func finished() { inFlight = false }

    public mutating func reset() {
        lastSentAt = nil
        lastText = ""
        inFlight = false
    }
}

public enum ListenSensitivity: Int, Sendable, CaseIterable {
    case normal = 0
    case high = 1
    case max = 2

    public static let key = "listenSensitivity"
    public static let defaultLevel: ListenSensitivity = .high

    public static var current: ListenSensitivity {
        let stored = UserDefaults.standard.object(forKey: key) as? Int
        return stored.flatMap(ListenSensitivity.init(rawValue:)) ?? defaultLevel
    }

    var targetRMS: Float {
        switch self {
        case .normal: return 0.10
        case .high: return 0.14
        case .max: return 0.18
        }
    }

    var noiseFloor: Float {
        switch self {
        case .normal: return 0.004
        case .high: return 0.0025
        case .max: return 0.0015
        }
    }

    var maxGain: Float {
        switch self {
        case .normal: return 12
        case .high: return 20
        case .max: return 30
        }
    }

    var shoutDB: Float {
        switch self {
        case .normal: return -16
        case .high: return -18
        case .max: return -20
        }
    }
}

public struct AutoGain: Sendable {
    public var targetRMS: Float = 0.14
    public var noiseFloor: Float = 0.0025
    public var maxGain: Float = 20
    public var attack: Float = 0.6
    public var rise: Float = 0.3
    public private(set) var gain: Float = 1

    public init() {}

    public init(sensitivity: ListenSensitivity) {
        targetRMS = sensitivity.targetRMS
        noiseFloor = sensitivity.noiseFloor
        maxGain = sensitivity.maxGain
    }

    public mutating func apply(_ sensitivity: ListenSensitivity) {
        targetRMS = sensitivity.targetRMS
        noiseFloor = sensitivity.noiseFloor
        maxGain = sensitivity.maxGain
    }

    public mutating func update(rms: Float) -> Float {
        guard rms > noiseFloor else { return gain }
        let wanted = min(maxGain, max(1, targetRMS / rms))
        let rate: Float = wanted < gain ? attack : rise
        gain += (wanted - gain) * rate
        return gain
    }
}

public struct LoudnessDetector: Sendable {
    public var thresholdDB: Float = -18
    public var windowSeconds: TimeInterval = 1.5
    public var loudSecondsNeeded: TimeInterval = 0.6
    public var cooldown: TimeInterval = 8

    private var samples: [(time: TimeInterval, loud: Bool)] = []
    private var lastFire: TimeInterval = -.infinity

    public init() {}

    public init(sensitivity: ListenSensitivity) {
        thresholdDB = sensitivity.shoutDB
    }

    public mutating func feed(levelDB: Float, at time: TimeInterval) -> Bool {
        samples.append((time, levelDB >= thresholdDB))
        samples.removeAll { time - $0.time > windowSeconds }
        guard time - lastFire >= cooldown, samples.count >= 2 else { return false }
        var loud: TimeInterval = 0
        for (previous, current) in zip(samples, samples.dropFirst()) where previous.loud && current.loud {
            loud += current.time - previous.time
        }
        guard loud >= loudSecondsNeeded else { return false }
        lastFire = time
        samples.removeAll()
        return true
    }

    public mutating func reset() {
        samples.removeAll()
        lastFire = -.infinity
    }
}
