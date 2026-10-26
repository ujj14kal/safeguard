import Foundation

/// What the on-device speech matcher heard. A small, visible category set —
/// whitebox, no hidden logic. Categories cross to /verify-speech unchanged.
public enum SpeechCategory: String, Sendable, Equatable, CaseIterable, Codable {
    case threat
    case coercion
    case pursuit
    case proposition
    case abuse
    case distress
}

/// One matchable phrase: lowercase words, matched whole-word and
/// case-insensitively. Severity is pre-guard (quotation/negation discount it).
public struct SpeechPattern: Sendable, Equatable {
    public var phrase: String
    public var category: SpeechCategory
    public var severity: Double

    public init(phrase: String, category: SpeechCategory, severity: Double) {
        self.phrase = phrase
        self.category = category
        self.severity = severity
    }
}

/// Every knob for the conversation listener. ThreatConfig-style: tune here,
/// never at call sites. The pattern list is a starter set — real-world
/// tuning (accents, phrasing, languages) is unverified until device testing.
public struct SpeechConfig: Sendable {
    public init() {}

    // MARK: - Window and snippet

    /// Seconds of transcript kept in the in-memory rolling window.
    public var windowSeconds: TimeInterval = 20
    /// Max snippet characters sent to /verify-speech on a trigger.
    public var snippetMaxChars: Int = 400

    // MARK: - Recognition restarts

    /// The system ends a recognition request after ~60 s; restart before
    /// that with no gap (each audio buffer reaches exactly one request).
    public var restartIntervalSeconds: TimeInterval = 50

    // MARK: - Backend calls

    /// Minimum seconds between /verify-speech calls: a continuous rant
    /// sends one snippet, then refires only with fresh speech.
    public var speechVerifyMinInterval: TimeInterval = 30

    // MARK: - Guards

    /// Severity multiplier when the match sits inside double quotes
    /// (reported speech: she said "come with me").
    public var quotationFactor: Double = 0.3
    /// Severity multiplier when a negation phrase stands within
    /// `negationDistance` words before a non-distress match
    /// ("I would never hurt you"). Distress is NEVER discounted:
    /// "don't touch me" from the wearer is danger, not safety.
    public var negationFactor: Double = 0.3
    public var negationDistance: Int = 2
    public var negationPhrases: [String] = [
        "don't", "do not", "won't", "will not", "would never", "could never", "never",
    ]

    /// Benign frames that CANCEL a match they contain ("killing time"
    /// contains "kill" talk but is not a threat; the film quote is the
    /// classic false positive).
    public var benignPhrases: [String] = [
        "kill time", "killing time", "hurt feelings", "dying of laughter",
        "dead tired", "dead battery", "follow me on instagram",
        "come with me if you want to live",
    ]

    // MARK: - Patterns (starter set; tune on real transcripts)

    public var patterns: [SpeechPattern] = SpeechConfig.defaultPatterns()

    public static func defaultPatterns() -> [SpeechPattern] {
        [
            // Explicit threats, second person (first-person versions like
            // "don't hurt me" live under distress instead).
            SpeechPattern(phrase: "kill you", category: .threat, severity: 1.0),
            SpeechPattern(phrase: "hurt you", category: .threat, severity: 1.0),
            SpeechPattern(phrase: "i will kill you", category: .threat, severity: 1.0),
            SpeechPattern(phrase: "i will hurt you", category: .threat, severity: 1.0),
            SpeechPattern(phrase: "gonna kill you", category: .threat, severity: 1.0),
            SpeechPattern(phrase: "going to kill you", category: .threat, severity: 1.0),
            SpeechPattern(phrase: "you are dead", category: .threat, severity: 1.0),
            SpeechPattern(phrase: "you're dead", category: .threat, severity: 1.0),
            SpeechPattern(
                phrase: "i know where you live", category: .threat, severity: 1.0
            ),
            SpeechPattern(phrase: "you will pay", category: .threat, severity: 0.9),
            // Coercion: orders to follow, come along, or stay silent.
            SpeechPattern(phrase: "come with me", category: .coercion, severity: 0.9),
            SpeechPattern(phrase: "come with us", category: .coercion, severity: 0.9),
            SpeechPattern(phrase: "get in the car", category: .coercion, severity: 0.9),
            SpeechPattern(phrase: "get into the car", category: .coercion, severity: 0.9),
            SpeechPattern(phrase: "get in the van", category: .coercion, severity: 0.9),
            SpeechPattern(phrase: "go with me", category: .coercion, severity: 0.85),
            SpeechPattern(phrase: "don't scream", category: .coercion, severity: 0.9),
            SpeechPattern(phrase: "do not scream", category: .coercion, severity: 0.9),
            SpeechPattern(phrase: "don't shout", category: .coercion, severity: 0.85),
            // Pursuit: following, or blocking the wearer's leaving.
            SpeechPattern(phrase: "follow you", category: .pursuit, severity: 0.85),
            SpeechPattern(phrase: "following you", category: .pursuit, severity: 0.85),
            SpeechPattern(phrase: "don't run", category: .pursuit, severity: 0.85),
            SpeechPattern(phrase: "do not run", category: .pursuit, severity: 0.85),
            SpeechPattern(phrase: "don't walk away", category: .pursuit, severity: 0.85),
            SpeechPattern(phrase: "come back here", category: .pursuit, severity: 0.8),
            SpeechPattern(phrase: "get back here", category: .pursuit, severity: 0.8),
            SpeechPattern(
                phrase: "where are you going", category: .pursuit, severity: 0.75
            ),
            // Persistent unwanted propositions.
            SpeechPattern(
                phrase: "give me your number", category: .proposition, severity: 0.7
            ),
            SpeechPattern(
                phrase: "come home with me", category: .proposition, severity: 0.75
            ),
            SpeechPattern(phrase: "hey baby", category: .proposition, severity: 0.7),
            SpeechPattern(phrase: "don't ignore me", category: .proposition, severity: 0.65),
            SpeechPattern(phrase: "do not ignore me", category: .proposition, severity: 0.65),
            SpeechPattern(phrase: "talk to me", category: .proposition, severity: 0.6),
            // Abuse directed at the wearer.
            SpeechPattern(phrase: "shut up", category: .abuse, severity: 0.6),
            SpeechPattern(
                phrase: "nobody will help you", category: .abuse, severity: 0.85
            ),
            SpeechPattern(
                phrase: "no one will help you", category: .abuse, severity: 0.85
            ),
            SpeechPattern(
                phrase: "nobody can hear you", category: .abuse, severity: 0.85
            ),
            SpeechPattern(
                phrase: "no one can hear you", category: .abuse, severity: 0.85
            ),
            SpeechPattern(
                phrase: "scream all you want", category: .abuse, severity: 0.8
            ),
            // Distress: the WEARER's own cries for help. High severity,
            // never negation-discounted.
            SpeechPattern(phrase: "help me", category: .distress, severity: 0.95),
            SpeechPattern(phrase: "somebody help", category: .distress, severity: 0.9),
            SpeechPattern(phrase: "please help", category: .distress, severity: 0.85),
            SpeechPattern(phrase: "call the police", category: .distress, severity: 0.95),
            SpeechPattern(phrase: "call 112", category: .distress, severity: 0.95),
            SpeechPattern(phrase: "leave me alone", category: .distress, severity: 0.95),
            SpeechPattern(phrase: "don't touch me", category: .distress, severity: 0.95),
            SpeechPattern(phrase: "do not touch me", category: .distress, severity: 0.95),
            SpeechPattern(phrase: "don't hurt me", category: .distress, severity: 0.95),
            SpeechPattern(phrase: "do not hurt me", category: .distress, severity: 0.95),
            SpeechPattern(phrase: "get away from me", category: .distress, severity: 0.9),
            SpeechPattern(phrase: "let me go", category: .distress, severity: 0.9),
            SpeechPattern(phrase: "stop it", category: .distress, severity: 0.7),
        ]
    }
}
