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
    /// Cuss words and angry shouting aimed at the wearer. Tracked always;
    /// one word is only a nudge, repetition is what escalates.
    case anger
}

/// One tokeniser for every speech consumer (matcher, code phrases, voice
/// commands). Hindi recognisers vary in spelling the same word: nukta,
/// chandrabindu and zero-width joiners are normalised away on BOTH the
/// patterns and the transcript, so "ज़ोर" and "जोर" match each other.
public enum SpeechText {
    public static func words(in text: String) -> [String] {
        normalised(text)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    public static func normalised(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.lowercased().decomposedStringWithCanonicalMapping.unicodeScalars {
            switch scalar.value {
            case 0x093C, 0x200C, 0x200D: continue // nukta, ZWNJ, ZWJ
            case 0x0901: scalars.append(Unicode.Scalar(0x0902)!) // chandrabindu -> anusvara
            default: scalars.append(scalar)
            }
        }
        return String(scalars).precomposedStringWithCanonicalMapping
    }
}

/// Languages the listener can transcribe. One recognizer runs at a time;
/// Hindi (hi-IN) writes English words in Latin, so Hinglish still works, and
/// the pattern list covers Devanagari AND romanised Hindi.
public enum SpeechLocale {
    public static let english = "en-IN"
    public static let hindi = "hi-IN"

    /// "auto" follows the iPhone's first language (Hindi -> hi-IN, else en-IN).
    public static func resolve(setting: String, preferredLanguages: [String]) -> String {
        switch setting {
        case "hi", hindi: return hindi
        case "en", english: return english
        default:
            return preferredLanguages.first?.lowercased().hasPrefix("hi") == true ? hindi : english
        }
    }
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
        "nahi", "nahin", "kabhi nahi", "नहीं", "कभी नहीं",
    ]

    /// This many abuse/anger matches inside the window count as sustained
    /// hostility: severity is raised to `repeatedAngerSeverity` (a single
    /// cuss word stays a nudge, because ordinary swearing is common).
    public var repeatedAngerCount: Int = 3
    public var repeatedAngerSeverity: Double = 0.75

    /// Benign frames that CANCEL a match they contain ("killing time"
    /// contains "kill" talk but is not a threat; the film quote is the
    /// classic false positive).
    public var benignPhrases: [String] = [
        "kill time", "killing time", "hurt feelings", "dying of laughter",
        "dead tired", "dead battery", "follow me on instagram",
        "come with me if you want to live", "time pass",
    ]

    // MARK: - Patterns (starter set; tune on real transcripts)

    public var patterns: [SpeechPattern] = SpeechConfig.defaultPatterns()

    public static func defaultPatterns() -> [SpeechPattern] {
        englishPatterns + hindiPatterns + angerPatterns
    }

    static var englishPatterns: [SpeechPattern] {
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

    /// Hindi in Devanagari and romanised (Hinglish) spellings, because the
    /// recogniser may return either. Starter set: spellings vary widely, so
    /// real-world tuning on recorded speech is still needed.
    static var hindiPatterns: [SpeechPattern] {
        func p(_ phrase: String, _ category: SpeechCategory, _ severity: Double) -> SpeechPattern {
            SpeechPattern(phrase: phrase, category: category, severity: severity)
        }
        return [
            // Threats
            p("maar dunga", .threat, 1.0), p("maar dalunga", .threat, 1.0),
            p("jaan se maar dunga", .threat, 1.0), p("jaan se maar dalunga", .threat, 1.0),
            p("kaat dunga", .threat, 1.0), p("dekh lunga tujhe", .threat, 0.9),
            p("tujhe nahi chhodunga", .threat, 0.95), p("utha lunga", .threat, 0.95),
            p("मार दूंगा", .threat, 1.0), p("मार डालूंगा", .threat, 1.0),
            p("जान से मार दूंगा", .threat, 1.0), p("काट दूंगा", .threat, 1.0),
            p("देख लूंगा तुझे", .threat, 0.9), p("तुझे छोड़ूंगा नहीं", .threat, 0.95),
            p("उठा लूंगा", .threat, 0.95), p("जान से मार दूँगा", .threat, 1.0),
            // Coercion
            p("chal mere saath", .coercion, 0.9), p("gaadi mein baith", .coercion, 0.9),
            p("chup raho", .coercion, 0.85), p("chup kar", .coercion, 0.8),
            p("chillana mat", .coercion, 0.9), p("awaaz mat karna", .coercion, 0.9),
            p("चल मेरे साथ", .coercion, 0.9), p("गाड़ी में बैठ", .coercion, 0.9),
            p("चुप रहो", .coercion, 0.85), p("चुप कर", .coercion, 0.8),
            p("चिल्लाना मत", .coercion, 0.9), p("आवाज़ मत करना", .coercion, 0.9),
            // Pursuit
            p("peecha kar raha", .pursuit, 0.85), p("peechha mat karo", .pursuit, 0.85),
            p("ruk ja", .pursuit, 0.8), p("bhaagna mat", .pursuit, 0.85),
            p("kahan ja rahi hai", .pursuit, 0.75), p("kahan ja rahi ho", .pursuit, 0.75),
            p("पीछा कर रहा", .pursuit, 0.85), p("रुक जा", .pursuit, 0.8),
            p("भागना मत", .pursuit, 0.85), p("कहाँ जा रही है", .pursuit, 0.75),
            p("कहाँ जा रही हो", .pursuit, 0.75),
            // Unwanted propositions
            p("number de do", .proposition, 0.7), p("apna number do", .proposition, 0.7),
            p("mere saath chalo", .proposition, 0.75), p("ek baar baat kar", .proposition, 0.65),
            p("नंबर दे दो", .proposition, 0.7), p("अपना नंबर दो", .proposition, 0.7),
            p("मेरे साथ चलो", .proposition, 0.75), p("एक बार बात कर", .proposition, 0.65),
            // Distress (the wearer)
            p("bachao", .distress, 0.95), p("madad karo", .distress, 0.95),
            p("mujhe chhod do", .distress, 0.95), p("chhodo mujhe", .distress, 0.95),
            p("haath mat lagao", .distress, 0.95), p("door hato", .distress, 0.9),
            p("police ko bulao", .distress, 0.95),
            p("बचाओ", .distress, 0.95), p("मदद करो", .distress, 0.95),
            p("मुझे छोड़ दो", .distress, 0.95), p("छोड़ो मुझे", .distress, 0.95),
            p("हाथ मत लगाओ", .distress, 0.95), p("दूर हटो", .distress, 0.9),
            p("पुलिस को बुलाओ", .distress, 0.95),
        ]
    }

    /// Cuss words and anger, English and Hindi/Hinglish. Mild ones sit below
    /// the check-in threshold on their own; the matcher escalates on
    /// repetition (`repeatedAngerCount`).
    static var angerPatterns: [SpeechPattern] {
        func p(_ phrase: String, _ severity: Double) -> SpeechPattern {
            SpeechPattern(phrase: phrase, category: .anger, severity: severity)
        }
        return [
            p("fuck", 0.55), p("fucking", 0.55), p("fucker", 0.6), p("bitch", 0.6),
            p("bastard", 0.6), p("asshole", 0.6), p("slut", 0.65), p("whore", 0.65),
            p("cunt", 0.65), p("motherfucker", 0.65), p("shit", 0.4), p("idiot", 0.4),
            p("i hate you", 0.5), p("get lost", 0.5), p("piss off", 0.5),
            // Hinglish gaali
            p("madarchod", 0.65), p("behenchod", 0.65), p("bhenchod", 0.65),
            p("bhosdike", 0.65), p("bhosdi", 0.6), p("chutiya", 0.6), p("chutiye", 0.6),
            p("gandu", 0.6), p("harami", 0.55), p("haramzada", 0.6), p("haramzade", 0.6),
            p("kamina", 0.5), p("kamine", 0.5), p("kutte", 0.5), p("kutta", 0.5),
            p("kutti", 0.55), p("randi", 0.65), p("raand", 0.65), p("saali", 0.45),
            p("saala", 0.4), p("lodu", 0.55), p("lund", 0.55), p("chodu", 0.55),
            p("bakchod", 0.45), p("tatti", 0.4), p("saale", 0.4),
            // Devanagari gaali
            p("मादरचोद", 0.65), p("बहनचोद", 0.65), p("भोसड़ीके", 0.65),
            p("चूतिया", 0.6), p("चुतिया", 0.6), p("गांडू", 0.6), p("हरामी", 0.55),
            p("हरामज़ादा", 0.6), p("कमीना", 0.5), p("कमीने", 0.5), p("कुत्ते", 0.5),
            p("कुत्ता", 0.5), p("कुतिया", 0.55), p("रंडी", 0.65), p("साली", 0.45),
            p("साला", 0.4), p("साले", 0.4), p("कमीनी", 0.5), p("हरामखोर", 0.55), p("haramkhor", 0.55), p("लौडू", 0.55), p("लंड", 0.55), p("बकचोद", 0.45),
            p("चोदू", 0.55), p("भाड़ में जा", 0.5), p("चुप कर साली", 0.6),
            // Anger directed at the wearer
            p("tujhe chhodunga nahi", 0.8), p("teri aukaat", 0.55), p("aukaat mein reh", 0.6),
            p("तेरी औकात", 0.55), p("औकात में रह", 0.6),
        ]
    }
}
