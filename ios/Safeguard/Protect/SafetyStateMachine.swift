import Foundation

/// Parsed Muse verdict level. Unknown strings from the backend never reach
/// the machine: the view model drops them (a strict contract beats a guess).
public enum MuseVerdictLevel: String, Sendable, Equatable {
    case low, medium, high
}

/// Where a suspicion came from. A Muse `low` cancels movement-only
/// suspicion, never speech- or Muse-backed suspicion.
public enum SuspicionSource: Sendable, Equatable, Hashable {
    case movement, muse, speech
}

/// How Unsafe was reached (drives the SOS wording, Phase 6 escalates).
public enum UnsafeCause: Sendable, Equatable {
    /// The 10 s question timer ran out with no answer.
    case noReply
    /// The wearer said the unsafe code phrase.
    case unsafePhrase
}

/// The wearer's reply during a check-in. `.tap` is the non-verbal answer:
/// a double tap (or the on-screen button). Volume-button capture needs
/// private API, so it is deliberately not implemented.
public enum UserReply: Sendable, Equatable {
    case safePhrase
    case unsafePhrase
    case tap
}

/// Safety states. `.listening` is the observable suspicion phase: the silent
/// "stay quiet" window (Part C) that precedes the spoken question.
public enum SafetyState: Sendable, Equatable {
    case idle, monitoring, listening, asking, safe, unsafe
}

/// Every threshold, window and phrase for the safety state machine.
/// Times are seconds; the machine takes explicit timestamps so tests drive
/// it without waiting.
public struct SafetyConfig: Sendable {
    public init() {}

    // MARK: - Check-in timing

    /// Seconds the wearer has to answer once the spoken question STARTS
    /// (not when Asking is entered — TTS may lag).
    public var askTimeoutSeconds: TimeInterval = 10
    /// Quiet period after Safe before movement/speech may nag again.
    /// A Muse `high` verdict bypasses it.
    public var cooldownSeconds: TimeInterval = 60

    // MARK: - Listening window (Part C)

    /// Silent window after suspicion before the spoken question. A
    /// recommendation-length pause, never a requirement.
    public var listeningWindowSeconds: TimeInterval = 6
    /// On-device score at or above this skips the window: waiting is unsafe.
    public var listeningSkipScore: Double = 0.80
    /// Calm on-screen cue shown during the window (VoiceOver reads it once).
    public var listeningCueText = "Stay quiet for a moment, listening to your surroundings"

    // MARK: - Speech

    /// Spoken question. Said quietly through the speaker.
    public var askPhrase = "Are you safe?"
    /// Speech volume 0...1 for the question (quiet, not silent).
    public var askVolume: Float = 0.5
    /// Speech severity at or above this triggers a check-in. Speech NEVER
    /// moves directly to Unsafe.
    public var speechStrongThreshold: Double = 0.7

    // MARK: - Code phrases (configurable; matched on close variants)

    public var safePhrases = ["open calculator"]
    public var unsafePhrases = ["open app store"]
}

/// Pure, timestamp-based safety state machine.
///
/// Inputs: scorer alerts, Muse verdicts, speech severity, user replies and
/// timer ticks. It never touches audio, haptics or the network: entering
/// Asking sets `askSpeechDue`, and the view model speaks, then reports back
/// via `noteAskSpeechStarted` so the 10 s clock starts with the audio.
public struct SafetyStateMachine: Sendable {
    public private(set) var state: SafetyState = .idle
    public private(set) var suspicionSources: Set<SuspicionSource> = []
    public private(set) var unsafeCause: UnsafeCause?
    /// True exactly when Asking was just entered and the question is not
    /// yet spoken. The view model consumes it with `takeAskSpeechDue`.
    public private(set) var askSpeechDue = false

    private let config: SafetyConfig
    private var listeningUntil: TimeInterval?
    private var askDeadline: TimeInterval?

    /// End of the post-Safe quiet period (nil when not in Safe).
    public private(set) var cooldownUntil: TimeInterval?

    public init(config: SafetyConfig = SafetyConfig()) {
        self.config = config
    }

    // MARK: - Session

    public mutating func startProtecting(at time: TimeInterval) {
        guard state == .idle else { return }
        reset()
        state = .monitoring
        _ = time
    }

    public mutating func stopProtecting() {
        reset()
        state = .idle
    }

    // MARK: - Inputs

    /// An on-device scorer alert (score at or above threshold).
    public mutating func noteMovementAlert(score: Double, at time: TimeInterval) {
        switch state {
        case .monitoring:
            suspicionSources.insert(.movement)
            enterSuspicionOrAsking(skip: score >= config.listeningSkipScore, at: time)
        case .listening:
            suspicionSources.insert(.movement)
            if score >= config.listeningSkipScore {
                enterAsking()
            }
        case .idle, .asking, .safe, .unsafe:
            break
        }
    }

    public mutating func noteMuseVerdict(_ level: MuseVerdictLevel, at time: TimeInterval) {
        switch level {
        case .low:
            // Cancels movement-only suspicion: the known false alert is a
            // still person scoring ~0.74 on-device while Muse says low.
            // Never cancels speech/Muse-backed suspicion, and never yanks
            // an in-progress question away.
            if state == .listening, suspicionSources == [.movement] {
                suspicionSources = []
                listeningUntil = nil
                state = .monitoring
            }
        case .medium, .high:
            switch state {
            case .monitoring:
                suspicionSources.insert(.muse)
                enterSuspicionOrAsking(skip: level == .high, at: time)
            case .listening:
                suspicionSources.insert(.muse)
                if level == .high {
                    enterAsking()
                }
            case .asking:
                suspicionSources.insert(.muse)
            case .safe where level == .high:
                // A high verdict breaks the cooldown; anything else waits.
                suspicionSources = [.muse]
                cooldownUntil = nil
                enterAsking()
            case .idle, .safe, .unsafe:
                break
            }
        }
    }

    /// Speech severity 0...1 from the conversation listener. Strong speech
    /// triggers the check-in path; it NEVER goes directly to Unsafe.
    public mutating func noteSpeech(severity: Double, at time: TimeInterval) {
        guard severity >= config.speechStrongThreshold else { return }
        switch state {
        case .monitoring:
            suspicionSources.insert(.speech)
            enterSuspicionOrAsking(skip: false, at: time)
        case .listening, .asking:
            suspicionSources.insert(.speech)
        case .idle, .safe, .unsafe:
            break
        }
    }

    public mutating func noteReply(_ reply: UserReply, at time: TimeInterval) {
        switch reply {
        case .unsafePhrase:
            // Works at ANY time while protecting — even with no incident —
            // and goes straight to Unsafe.
            switch state {
            case .monitoring, .listening, .asking, .safe:
                enterUnsafe(cause: .unsafePhrase)
            case .idle, .unsafe:
                break
            }
        case .safePhrase:
            if state == .asking {
                enterSafe(at: time)
            }
        case .tap:
            switch state {
            case .listening:
                // Ends the window early; the question is still asked.
                enterAsking()
            case .asking:
                // Non-verbal "I'm OK".
                enterSafe(at: time)
            case .idle, .monitoring, .safe, .unsafe:
                break
            }
        }
    }

    /// The spoken question started playing: the 10 s clock starts NOW.
    /// The view model calls this even if TTS fails, so the clock always runs.
    public mutating func noteAskSpeechStarted(at time: TimeInterval) {
        guard state == .asking, askDeadline == nil else { return }
        askDeadline = time + config.askTimeoutSeconds
    }

    /// Advance timers. Call regularly (the 1 s UI tick is plenty).
    public mutating func tick(at time: TimeInterval) {
        switch state {
        case .listening:
            if let until = listeningUntil, time >= until {
                enterAsking()
            }
        case .asking:
            // No deadline until the question starts playing: the wearer
            // gets the full 10 s from the audio, not from the state change.
            if let deadline = askDeadline, time >= deadline {
                enterUnsafe(cause: .noReply)
            }
        case .safe:
            if let until = cooldownUntil, time >= until {
                cooldownUntil = nil
                suspicionSources = []
                state = .monitoring
            }
        case .idle, .monitoring, .unsafe:
            break
        }
    }

    /// Consumes the pending spoken question (one TTS call per Asking entry).
    public mutating func takeAskSpeechDue() -> Bool {
        let due = askSpeechDue
        askSpeechDue = false
        return due
    }

    // MARK: - Private

    private mutating func enterSuspicionOrAsking(skip: Bool, at time: TimeInterval) {
        if skip {
            enterAsking()
        } else {
            listeningUntil = time + config.listeningWindowSeconds
            state = .listening
        }
    }

    private mutating func enterAsking() {
        listeningUntil = nil
        askDeadline = nil
        state = .asking
        askSpeechDue = true
    }

    private mutating func enterSafe(at time: TimeInterval) {
        listeningUntil = nil
        askDeadline = nil
        askSpeechDue = false
        suspicionSources = []
        cooldownUntil = time + config.cooldownSeconds
        state = .safe
    }

    private mutating func enterUnsafe(cause: UnsafeCause) {
        listeningUntil = nil
        askDeadline = nil
        askSpeechDue = false
        unsafeCause = cause
        state = .unsafe
    }

    private mutating func reset() {
        suspicionSources = []
        unsafeCause = nil
        askSpeechDue = false
        listeningUntil = nil
        askDeadline = nil
        cooldownUntil = nil
    }
}

/// Matches code phrases with close variants: case-insensitive, punctuation
/// ignored, and the phrase may sit inside a longer sentence
/// ("please open calculator now"). Matching is whole-word, so "open
/// calculators" does NOT match. Unsafe is checked first: if a transcript
/// somehow contains both, Unsafe wins.
public struct CodePhraseMatcher: Sendable {
    private let safe: [[String]]
    private let unsafe: [[String]]

    public init(config: SafetyConfig = SafetyConfig()) {
        self.safe = config.safePhrases.map(Self.words(in:))
        self.unsafe = config.unsafePhrases.map(Self.words(in:))
    }

    public func match(_ transcript: String) -> UserReply? {
        let words = Self.words(in: transcript)
        if unsafe.contains(where: { contains(words, phrase: $0) }) {
            return .unsafePhrase
        }
        if safe.contains(where: { contains(words, phrase: $0) }) {
            return .safePhrase
        }
        return nil
    }

    private func contains(_ words: [String], phrase: [String]) -> Bool {
        guard !phrase.isEmpty, words.count >= phrase.count else { return false }
        return (0...(words.count - phrase.count)).contains { start in
            words[start..<(start + phrase.count)].elementsEqual(phrase)
        }
    }

    private static func words(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
