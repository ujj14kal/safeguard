import Foundation

/// Hands-free commands. Every one has an on-screen equivalent; the parser
/// is pure and fully tested, the view model executes.
public enum VoiceCommand: Sendable, Equatable {
    case startProtecting
    case stopProtecting
    case status
    case dim
    case brighten
    case openSettings
    case goBack
    case callEmergency
    case shareLocation
    case help
}

/// Wake word ("safeguard", "safe guard", "save guard") must LEAD the
/// transcript; the remainder matches a command phrase as a whole-word
/// subsequence, so polite wrapping ("please ... now") still parses while
/// "undim" never matches "dim". Anything else — no wake word, wake word
/// mid-sentence, unknown words — returns nil and the transcript falls
/// through to the threat matcher.
public struct VoiceCommandParser: Sendable {
    public init() {}

    public func parse(_ transcript: String) -> VoiceCommand? {
        let words = Self.words(in: transcript)
        let rest: [String]
        if words.first == "safeguard" {
            rest = Array(words.dropFirst())
        } else if words.count >= 2,
                  words[0] == "safe" || words[0] == "save", words[1] == "guard"
        {
            rest = Array(words.dropFirst(2))
        } else {
            return nil
        }
        for (command, phrases) in Self.commands {
            if phrases.contains(where: { Self.containsPhrase(rest, phrase: $0) }) {
                return command
            }
        }
        return nil
    }

    /// Whole-word subsequence: "undim" must not match "dim", while "please
    /// dim the screen now" still matches "dim the screen".
    private static func containsPhrase(_ words: [String], phrase: String) -> Bool {
        let want = phrase.split(separator: " ").map(String.init)
        guard !want.isEmpty, words.count >= want.count else { return false }
        return (0...(words.count - want.count)).contains { start in
            words[start..<(start + want.count)].elementsEqual(want)
        }
    }

    private static let commands: [(VoiceCommand, [String])] = [
        (.stopProtecting, ["stop protecting", "stop protection", "stop"]),
        (.startProtecting, ["start protecting", "start protection", "begin protecting", "start"]),
        (.status, ["status", "what s happening", "what is happening", "report", "how am i"]),
        (.dim, ["dim the screen", "darken the screen", "darken", "dim"]),
        (.brighten, ["brighten the screen", "brighten", "undim"]),
        (.openSettings, ["open settings", "settings"]),
        (.goBack, ["go back", "back"]),
        (.callEmergency, [
            "call 112", "call one one two", "call one twelve",
            "call emergency", "emergency call",
        ]),
        (.shareLocation, ["share my location", "share location"]),
        (.help, ["what can you say", "what can i say", "list commands", "commands", "help"]),
    ]

    private static func words(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}

/// "Stop protecting" needs a spoken "yes" within a few seconds: stopping
/// protection by accident (a misheard podcast) must be hard.
public struct StopConfirmation: Sendable {
    public private(set) var pendingUntil: TimeInterval?
    private let windowSeconds: TimeInterval

    public init(windowSeconds: TimeInterval = 5) {
        self.windowSeconds = windowSeconds
    }

    public mutating func request(at time: TimeInterval) {
        pendingUntil = time + windowSeconds
    }

    public mutating func cancel() {
        pendingUntil = nil
    }

    public func isPending(at time: TimeInterval) -> Bool {
        if let until = pendingUntil, time <= until {
            return true
        }
        return false
    }

    public enum Result: Sendable, Equatable {
        case confirmed
        case denied
        case waiting
        case expired
    }

    /// A direct answer (no wake word): yes-words confirm, no-words deny,
    /// anything else keeps waiting until the window lapses.
    public mutating func answer(_ transcript: String, at time: TimeInterval) -> Result {
        guard let until = pendingUntil else { return .expired }
        if time > until {
            pendingUntil = nil
            return .expired
        }
        let words = Set(transcript.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty })
        // Deny first: uncertainty keeps protection on ("do not confirm"
        // must not confirm). Words only — "don't" tokenizes to don+t, so
        // "not" carries the negations ("do not stop", "not sure" → deny,
        // which is the safe direction).
        if !words.intersection(["no", "nope", "nah", "cancel", "not"]).isEmpty {
            pendingUntil = nil
            return .denied
        }
        if !words.intersection(["yes", "yeah", "yep", "yup", "confirm", "affirmative"]).isEmpty {
            pendingUntil = nil
            return .confirmed
        }
        return .waiting
    }
}

extension Notification.Name {
    /// Voice command "open settings": ContentView switches to the tab.
    public static let safeguardOpenSettings = Notification.Name("SafeguardOpenSettings")
    /// Voice command "go back": ContentView returns to Protect.
    public static let safeguardGoBack = Notification.Name("SafeguardGoBack")
}
