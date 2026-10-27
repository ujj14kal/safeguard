import Foundation

/// Pure lifecycle for one conversation-listening run: gapless recognition
/// restarts, TTS pausing, and honest deaf states. The real
/// ConversationListener drives AVFoundation; this type holds every decision
/// the tests can check.
public struct ListeningSession: Sendable {
    public enum State: Sendable, Equatable {
        case idle
        /// Live. `generation` counts recognition requests: each restart
        /// bumps it, and audio buffers always feed exactly one request.
        case listening(generation: Int, requestStart: TimeInterval)
        /// Interrupted or errored. Never looks active: `isLive` is false.
        case deaf(reason: String)
    }

    // NOTE: there is deliberately no paused-for-TTS state. Pausing would
    // deafen the unsafe code phrase, which must work at ANY time while
    // protecting. The app "ignores itself" instead: our spoken texts match
    // no code phrase and no threat pattern, and voice commands are gated
    // on `speakingNow` in the view model.

    public private(set) var state: State = .idle
    private let restartInterval: TimeInterval
    private var recentTaskEnds: [TimeInterval] = []

    /// What to do when a recognition task ends on its own.
    public enum TaskEndDecision: Sendable, Equatable {
        case restart
        case deaf(reason: String)
    }

    public init(config: SpeechConfig = SpeechConfig()) {
        self.restartInterval = config.restartIntervalSeconds
    }

    /// True only while actually transcribing. Deaf is not live.
    public var isLive: Bool {
        if case .listening = state { return true }
        return false
    }

    /// Current recognition-request generation (nil unless listening).
    /// The listener tags each task with its generation so a stale task's
    /// error (e.g. from a routine restart cancel) is ignored.
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

    /// Starts a fresh recognition request when the system time limit
    /// approaches. Returns true exactly when the caller must restart.
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

    /// A recognition task finished by itself: after every final result, and
    /// on "no speech detected" style errors. The recogniser then delivers
    /// NOTHING more, so the listener must start a fresh request at once, or
    /// it goes deaf after the first sentence. Many endings in a short time
    /// mean something is really broken: report it instead of spinning.
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

    /// Phone call, Siri, or another app took the microphone.
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

/// Partial transcripts grow word by word, so the same code phrase matches on
/// every later partial of an utterance. This acts on it once, and remembers
/// it so the utterance's final transcript does not act on it again.
public struct PartialReplyGate: Sendable {
    private var handled: UserReply?

    public init() {}

    /// The reply to act on now, or nil when there is none or it was already
    /// acted on in this utterance.
    public mutating func consume(_ reply: UserReply?) -> UserReply? {
        guard let reply, reply != handled else { return nil }
        handled = reply
        return reply
    }

    /// The utterance ended: returns what the partials already acted on.
    public mutating func finishUtterance() -> UserReply? {
        defer { handled = nil }
        return handled
    }
}

/// Silent conversation rating: each rated chunk of talk maps to a vibration
/// pattern, never a sound. Heavier talk, heavier pattern.
public enum SpeechHapticLevel: Int, Sendable, Comparable, Equatable {
    case none, nudge, elevated, strong

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// Thresholds: below 0.35 nothing (ordinary talk and mild words);
    /// 0.35...0.55 a nudge; 0.55...0.7 elevated; 0.7+ strong (a check-in).
    public static func level(for severity: Double) -> SpeechHapticLevel {
        switch severity {
        case ..<0.35: .none
        case ..<0.55: .nudge
        case ..<0.7: .elevated
        default: .strong
        }
    }
}

/// Keeps vibrations from becoming a constant buzz: a repeat of the same or
/// a lighter level inside `minInterval` is dropped; a heavier one gets through.
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

/// Concerning talk that was just heard: shown in red on the HUD with the
/// option to start the safety measures. It fades by itself.
public struct ConversationFlag: Sendable, Equatable {
    public var category: SpeechCategory
    public var severity: Double
    public var at: TimeInterval

    public init(category: SpeechCategory, severity: Double, at: TimeInterval) {
        self.category = category
        self.severity = severity
        self.at = at
    }

    /// Talk at or above this severity raises a flag (vibration level "nudge"
    /// and up).
    public static let minSeverity = 0.45
    public static let showSeconds: TimeInterval = 12

    public var label: String {
        switch category {
        case .threat: "Threatening words"
        case .coercion: "Someone is pressuring you"
        case .pursuit: "Someone may be following you"
        case .proposition: "Unwanted advances"
        case .abuse, .anger: "Abusive or angry language"
        case .distress: "A call for help"
        }
    }

    public func isActive(at time: TimeInterval) -> Bool {
        time - at < Self.showSeconds
    }

    /// A new flag replaces the shown one only when it is heavier or the
    /// shown one has expired, so the banner does not flicker between labels.
    public static func merged(_ current: ConversationFlag?, with new: ConversationFlag) -> ConversationFlag {
        guard let current, current.isActive(at: new.at), current.severity > new.severity else {
            return new
        }
        var kept = current
        kept.at = new.at
        return kept
    }
}

/// Decides when the conversation goes to the AI judge: after new talk, at
/// most every `minInterval` seconds, one call at a time, never the same
/// text twice. Pure, so the schedule is testable.
public struct SpeechJudgeSchedule: Sendable {
    private let minInterval: TimeInterval
    private var lastSentAt: TimeInterval?
    private var lastText = ""
    public private(set) var inFlight = false

    public init(minInterval: TimeInterval = 1.5) {
        self.minInterval = minInterval
    }

    /// True when `text` should be sent now. Marks the call in flight.
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

/// Software gain for quiet speech. The recogniser misses words spoken softly
/// or from a chest-mounted phone, so the audio it hears is lifted toward a
/// steady level. Silence and room noise are NOT amplified (below the noise
/// floor the gain stays where it was), and loud speech is never boosted.
public struct AutoGain: Sendable {
    public var targetRMS: Float = 0.10      // about -20 dBFS
    public var noiseFloor: Float = 0.004    // about -48 dBFS: below this, hold
    public var maxGain: Float = 12
    public var attack: Float = 0.6          // how fast gain falls when it gets loud
    public private(set) var gain: Float = 1

    public init() {}

    /// Updates and returns the gain for a buffer whose RMS is `rms`.
    public mutating func update(rms: Float) -> Float {
        guard rms > noiseFloor else { return gain }
        let wanted = min(maxGain, max(1, targetRMS / rms))
        let rate: Float = wanted < gain ? attack : 0.15
        gain += (wanted - gain) * rate
        return gain
    }
}

/// Shouting: loud sound sustained for a moment. Fed one level (dBFS RMS) per
/// audio buffer; fires once, then stays quiet for `cooldown` seconds.
public struct LoudnessDetector: Sendable {
    public var thresholdDB: Float = -16
    public var windowSeconds: TimeInterval = 1.5
    public var loudSecondsNeeded: TimeInterval = 0.7
    public var cooldown: TimeInterval = 8

    private var samples: [(time: TimeInterval, loud: Bool)] = []
    private var lastFire: TimeInterval = -.infinity

    public init() {}

    public mutating func feed(levelDB: Float, at time: TimeInterval) -> Bool {
        samples.append((time, levelDB >= thresholdDB))
        samples.removeAll { time - $0.time > windowSeconds }
        guard time - lastFire >= cooldown, samples.count >= 2 else { return false }
        // Time spent loud = span of consecutive loud samples, summed.
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
