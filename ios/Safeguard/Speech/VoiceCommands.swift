import Foundation

public enum VoiceCommand: Sendable, Equatable {
    case stopProtecting
    case status
    case dim
    case brighten
    case openSettings
    case goBack
    case callEmergency
    case shareLocation
}

public struct VoiceCommandParser: Sendable {
    public init() {}

    public func parse(_ transcript: String) -> VoiceCommand? {
        let words = Self.words(in: transcript)
        let rest: [String]
        if words.first == "safeguard" || words.first == "सेफगार्ड" {
            rest = Array(words.dropFirst())
        } else if words.count >= 2,
                  words[0] == "safe" || words[0] == "save" || words[0] == "सेफ",
                  words[1] == "guard" || words[1] == "गार्ड"
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

    private static func containsPhrase(_ words: [String], phrase: String) -> Bool {
        let want = phrase.split(separator: " ").map(String.init)
        guard !want.isEmpty, words.count >= want.count else { return false }
        return (0...(words.count - want.count)).contains { start in
            words[start..<(start + want.count)].elementsEqual(want)
        }
    }

    private static let commands: [(VoiceCommand, [String])] = [
        (.stopProtecting, [
            "stop protecting", "stop protection", "stop",
            "suraksha band karo", "band karo", "सुरक्षा बंद करो", "बंद करो",
        ]),
        (.status, [
            "status", "what s happening", "what is happening", "report", "how am i",
            "haal batao", "स्थिति बताओ", "हाल बताओ",
        ]),
        (.dim, [
            "dim the screen", "darken the screen", "darken", "dim",
            "screen dim karo", "स्क्रीन धीमी करो",
        ]),
        (.brighten, [
            "brighten the screen", "brighten", "undim",
            "screen tez karo", "स्क्रीन तेज़ करो",
        ]),
        (.openSettings, ["open settings", "settings", "settings kholo", "सेटिंग्स खोलो"]),
        (.goBack, ["go back", "back", "peeche jao", "पीछे जाओ"]),
        (.callEmergency, [
            "call 112", "call one one two", "call one twelve",
            "call emergency", "emergency call",
            "112 call karo", "police ko bulao", "पुलिस को बुलाओ", "112 पर कॉल करो",
        ]),
        (.shareLocation, [
            "share my location", "share location",
            "location bhejo", "meri location bhejo", "लोकेशन भेजो",
        ]),
    ]

    private static func words(in text: String) -> [String] {
        SpeechText.words(in: text)
    }
}

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

    public mutating func answer(_ transcript: String, at time: TimeInterval) -> Result {
        guard let until = pendingUntil else { return .expired }
        if time > until {
            pendingUntil = nil
            return .expired
        }
        let words = Set(SpeechText.words(in: transcript))
        if !words.intersection(["no", "nope", "nah", "cancel", "not", "nahi", "nahin", "नहीं", "मत", "रुको"]).isEmpty {
            pendingUntil = nil
            return .denied
        }
        if !words.intersection(["yes", "yeah", "yep", "yup", "confirm", "affirmative", "haan", "han", "ji", "haanji", "हाँ", "हां", "जी", "ठीक"]).isEmpty {
            pendingUntil = nil
            return .confirmed
        }
        return .waiting
    }
}

extension Notification.Name {
    public static let safeguardOpenSettings = Notification.Name("SafeguardOpenSettings")
    public static let safeguardGoBack = Notification.Name("SafeguardGoBack")
    public static let safeguardRunSetup = Notification.Name("SafeguardRunSetup")
    public static let safeguardOpenContacts = Notification.Name("SafeguardOpenContacts")
    public static let safeguardOpenActivity = Notification.Name("SafeguardOpenActivity")
    public static let safeguardOpenDashboard = Notification.Name("SafeguardOpenDashboard")
}
