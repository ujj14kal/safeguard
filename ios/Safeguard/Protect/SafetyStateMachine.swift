import Foundation

public enum MuseVerdictLevel: String, Sendable, Equatable {
    case low, medium, high
}

public enum SuspicionSource: Sendable, Equatable, Hashable {
    case movement, muse, speech
}

public enum UnsafeCause: Sendable, Equatable {
    case noReply
    case unsafePhrase
    case distressWord
}

public enum UserReply: Sendable, Equatable {
    case safePhrase
    case unsafePhrase
    case tap
}

public enum SafetyState: Sendable, Equatable {
    case idle, monitoring, listening, asking, safe, unsafe
    case countdown
}

public struct SafetyConfig: Sendable {
    public init() {}

    public var askTimeoutSeconds: TimeInterval = 10
    public var cooldownSeconds: TimeInterval = 60
    public var stopConfirmSeconds: TimeInterval = 5

    public var listeningWindowSeconds: TimeInterval = 6
    public var listeningSkipScore: Double = 0.80
    public var listeningCueText = String(localized: "Stay quiet for a moment, listening to your surroundings")

    public var autoSosSeconds: TimeInterval = 5
    public var distressCooldownSeconds: TimeInterval = 10
    public var distressWords = [
        "help", "help me", "bachao", "bacho", "bachaao", "madad", "madad karo",
        "save me", "somebody help", "please help", "leave me", "chhodo mujhe",
        "बचाओ", "बचाओ बचाओ", "मदद", "मदद करो", "छोड़ो मुझे",
    ]

    public var askPhrase = "Are you safe?"
    public var askVolume: Float = 0.5
    public var speechStrongThreshold: Double = 0.7

    public var safePhrases = [
        "open calculator", "calculator kholo", "calculator khol do",
        "ओपन कैलकुलेटर", "कैलकुलेटर खोलो", "कैलकुलेटर खोल दो", "कैलकुलेटर खोलिए",
    ]
    public var unsafePhrases = [
        "open app store", "app store kholo", "app store khol do",
        "ओपन ऐप स्टोर", "ओपन एप स्टोर", "ऐप स्टोर खोलो", "एप स्टोर खोलो",
        "ऐप स्टोर खोल दो", "ऐप स्टोर खोलिए", "ओपन ऐप्प स्टोर",
    ]
}

public struct SafetyStateMachine: Sendable {
    public private(set) var state: SafetyState = .idle
    public private(set) var suspicionSources: Set<SuspicionSource> = []
    public private(set) var unsafeCause: UnsafeCause?
    public private(set) var askSpeechDue = false

    private let config: SafetyConfig
    private var listeningUntil: TimeInterval?
    private var askDeadline: TimeInterval?
    private var countdownUntil: TimeInterval?
    private var distressIgnoredUntil: TimeInterval = -.infinity

    public private(set) var cooldownUntil: TimeInterval?

    public init(config: SafetyConfig = SafetyConfig()) {
        self.config = config
    }

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

    public mutating func noteDistressWord(at time: TimeInterval) {
        guard time >= distressIgnoredUntil else { return }
        switch state {
        case .monitoring, .listening, .asking, .safe:
            listeningUntil = nil
            askDeadline = nil
            askSpeechDue = false
            cooldownUntil = nil
            countdownUntil = time + config.autoSosSeconds
            state = .countdown
        case .idle, .countdown, .unsafe:
            break
        }
    }

    public func countdownRemaining(at time: TimeInterval) -> TimeInterval? {
        guard state == .countdown, let until = countdownUntil else { return nil }
        return max(0, until - time)
    }

    public mutating func cancelCountdown(at time: TimeInterval) {
        guard state == .countdown else { return }
        countdownUntil = nil
        suspicionSources = []
        distressIgnoredUntil = time + config.distressCooldownSeconds
        state = .monitoring
    }

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
        case .idle, .asking, .safe, .unsafe, .countdown:
            break
        }
    }

    public mutating func noteMuseVerdict(_ level: MuseVerdictLevel, at time: TimeInterval) {
        switch level {
        case .low:
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
                suspicionSources = [.muse]
                cooldownUntil = nil
                enterAsking()
            case .idle, .safe, .unsafe, .countdown:
                break
            }
        }
    }

    public mutating func noteSpeech(severity: Double, at time: TimeInterval) {
        guard severity >= config.speechStrongThreshold else { return }
        switch state {
        case .monitoring:
            suspicionSources.insert(.speech)
            enterSuspicionOrAsking(skip: false, at: time)
        case .listening, .asking:
            suspicionSources.insert(.speech)
        case .idle, .safe, .unsafe, .countdown:
            break
        }
    }

    public mutating func noteReply(_ reply: UserReply, at time: TimeInterval) {
        switch reply {
        case .unsafePhrase:
            switch state {
            case .monitoring, .listening, .asking, .safe, .countdown:
                enterUnsafe(cause: .unsafePhrase)
            case .idle, .unsafe:
                break
            }
        case .safePhrase:
            if state == .asking {
                enterSafe(at: time)
            } else if state == .countdown {
                cancelCountdown(at: time)
            } else if state == .unsafe {
                endUnsafe(at: time)
            }
        case .tap:
            switch state {
            case .listening:
                enterAsking()
            case .asking:
                enterSafe(at: time)
            case .countdown:
                cancelCountdown(at: time)
            case .idle, .monitoring, .safe, .unsafe:
                break
            }
        }
    }

    public mutating func noteAskSpeechStarted(at time: TimeInterval) {
        guard state == .asking, askDeadline == nil else { return }
        askDeadline = time + config.askTimeoutSeconds
    }

    public mutating func tick(at time: TimeInterval) {
        switch state {
        case .listening:
            if let until = listeningUntil, time >= until {
                enterAsking()
            }
        case .asking:
            if let deadline = askDeadline, time >= deadline {
                enterUnsafe(cause: .noReply)
            }
        case .safe:
            if let until = cooldownUntil, time >= until {
                cooldownUntil = nil
                suspicionSources = []
                state = .monitoring
            }
        case .countdown:
            if let until = countdownUntil, time >= until {
                enterUnsafe(cause: .distressWord)
            }
        case .idle, .monitoring, .unsafe:
            break
        }
    }

    public mutating func takeAskSpeechDue() -> Bool {
        let due = askSpeechDue
        askSpeechDue = false
        return due
    }

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

    public mutating func endUnsafe(at time: TimeInterval) {
        guard state == .unsafe else { return }
        enterSafe(at: time)
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
        countdownUntil = nil
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
        countdownUntil = nil
        distressIgnoredUntil = -.infinity
    }
}

public struct DistressMatcher: Sendable {
    private let phrases: [[String]]

    public init(config: SafetyConfig = SafetyConfig()) {
        phrases = config.distressWords.map { SpeechText.words(in: $0).map(SpeechText.fuzzyKey) }
    }

    public func matches(_ transcript: String) -> Bool {
        let keys = SpeechText.words(in: transcript).map(SpeechText.fuzzyKey)
        guard !keys.isEmpty else { return false }
        return phrases.contains { phrase in
            guard !phrase.isEmpty, keys.count >= phrase.count else { return false }
            return (0...(keys.count - phrase.count)).contains { start in
                zip(keys[start..<(start + phrase.count)], phrase).allSatisfy {
                    SpeechText.keysEqual($0, $1)
                }
            }
        }
    }
}

public struct CodePhraseMatcher: Sendable {
    private let safe: [[String]]
    private let unsafe: [[String]]

    public init(config: SafetyConfig = SafetyConfig()) {
        self.init(safePhrases: config.safePhrases, unsafePhrases: config.unsafePhrases)
    }

    public init(safePhrases: [String], unsafePhrases: [String]) {
        self.safe = safePhrases.map(Self.words(in:))
        self.unsafe = unsafePhrases.map(Self.words(in:))
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
        SpeechText.words(in: text)
    }
}
