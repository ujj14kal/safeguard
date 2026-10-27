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

    /// Spelling-tolerant key for Latin words. Hinglish has no fixed spelling
    /// (chutiya / chutia / chootiya), so repeated letters, long vowels and
    /// trailing vowels are folded away on both sides before comparing.
    /// Non-Latin words are returned unchanged.
    public static func fuzzyKey(_ word: String) -> String {
        guard word.unicodeScalars.allSatisfy({ $0.isASCII }) else { return word }
        var s = word
        for (from, to) in [
            ("chh", "ch"), ("ph", "f"), ("sh", "s"), ("w", "v"), ("z", "j"), ("q", "k"),
            ("aa", "a"), ("ee", "i"), ("ii", "i"), ("oo", "u"), ("uu", "u"), ("ai", "e"),
            ("au", "o"), ("ei", "e"), ("iy", "i"), ("ay", "a"),
        ] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        var folded = ""
        for ch in s where folded.last != ch { folded.append(ch) }
        // Drop trailing vowels on longer words: saala / saale / sala, chutiya / chutia.
        while folded.count > 4, let last = folded.last, "aeiouh".contains(last) {
            folded.removeLast()
        }
        return folded
    }

    /// Words match when their fuzzy keys are equal, or within one edit for
    /// keys of six or more letters (bhosdike / bhosadike).
    public static func wordsEqual(_ a: String, _ b: String) -> Bool {
        a == b || keysEqual(fuzzyKey(a), fuzzyKey(b))
    }

    /// Same comparison on keys already computed by `fuzzyKey` (the matcher
    /// computes each key once instead of per comparison).
    public static func keysEqual(_ ka: String, _ kb: String) -> Bool {
        if ka == kb { return true }
        guard ka.count >= 6, kb.count >= 6, abs(ka.count - kb.count) <= 1,
              ka.unicodeScalars.allSatisfy({ $0.isASCII }) else { return false }
        return editDistanceAtMostOne(Array(ka), Array(kb))
    }

    private static func editDistanceAtMostOne(_ a: [Character], _ b: [Character]) -> Bool {
        var i = 0, j = 0, edits = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] { i += 1; j += 1; continue }
            edits += 1
            if edits > 1 { return false }
            if a.count == b.count { i += 1; j += 1 }
            else if a.count > b.count { i += 1 }
            else { j += 1 }
        }
        return edits + (a.count - i) + (b.count - j) <= 1
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
        englishPatterns + hindiPatterns + angerPatterns + extraVocabulary + englishCussWords
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

    /// Large second vocabulary: Hinglish (Latin) spellings first, because the
    /// speech model writes Hinglish in Latin letters, then Devanagari. Spelling
    /// variants are absorbed by the matcher's fuzzy key, so one spelling of a
    /// word covers chutiya / chutia / chootiya.
    static var extraVocabulary: [SpeechPattern] {
        func a(_ phrase: String, _ severity: Double = 0.55) -> SpeechPattern {
            SpeechPattern(phrase: phrase, category: .anger, severity: severity)
        }
        func q(_ phrase: String, _ severity: Double = 0.7) -> SpeechPattern {
            SpeechPattern(phrase: phrase, category: .proposition, severity: severity)
        }
        func t(_ phrase: String, _ severity: Double = 0.95) -> SpeechPattern {
            SpeechPattern(phrase: phrase, category: .threat, severity: severity)
        }
        func c(_ phrase: String, _ severity: Double = 0.9) -> SpeechPattern {
            SpeechPattern(phrase: phrase, category: .coercion, severity: severity)
        }
        func p(_ phrase: String, _ severity: Double = 0.8) -> SpeechPattern {
            SpeechPattern(phrase: phrase, category: .pursuit, severity: severity)
        }
        return [
            // ---- Unwanted propositions / harassment (Hinglish)
            q("free ho kya"), q("free ho aap"), q("free hai kya"), q("aaj raat ko free"),
            q("raat ko free"), q("aaj raat free"), q("aaj raat kya kar rahi ho"),
            q("raat ko milte hain"), q("raat ko milo"), q("aaj raat milo"),
            q("kitna loge"), q("kitne paise loge"), q("rate kya hai"), q("kitna rate hai"),
            q("chalogi kya"), q("chalegi kya"), q("chalti hai kya"), q("mere saath chalogi"),
            q("mere sath chalogi"), q("hotel chalte hain"), q("hotel chalo"), q("room pe chalo"),
            q("room chalte hain"), q("ghar chhod dun"), q("ghar chhod du"), q("lift de dun"),
            q("lift chahiye"), q("date pe chalo"), q("date pe chalogi"), q("dinner pe chalo"),
            q("coffee pe chalo"), q("number do na"), q("number dena"), q("whatsapp number do"),
            q("instagram id do"), q("akeli ho kya"), q("akele ho kya"), q("akeli kyun ho"),
            q("kya mast lag rahi"), q("kya mast lag rahi ho", 0.75), q("bahut sexy"),
            q("tum bahut sexy"), q("kya figure hai"), q("kya item hai"), q("kya maal hai"),
            q("mast maal"), q("patakha", 0.7), q("line maar"), q("line maar raha"),
            q("smile do"), q("ek kiss do"), q("kiss de do"), q("gale lag jao"),
            q("paas aao", 0.75), q("paas aa jao", 0.75), q("mere paas aao", 0.8),
            q("baat to karo"), q("baat karo na"), q("ignore mat karo"), q("ignore kyun kar rahi"),
            q("bhav kyun kha rahi"), q("itna attitude"), q("itna attitude kyun"),
            q("sunna zara", 0.6), q("sun na", 0.55), q("ae sun", 0.6), q("oye sun", 0.6),
            q("hello madam", 0.55), q("hello baby", 0.7), q("hey sexy", 0.75),
            q("are you free tonight"), q("are you free"), q("tonight are you free"),
            q("how much for the night"), q("how much do you charge"), q("what is your rate"),
            q("come with me tonight"), q("let's go to a hotel"), q("want to have fun"),
            q("you look sexy"), q("nice figure"), q("nice body"), q("send me pics"),
            q("send nudes"), q("show me your"), q("sleep with me"), q("sleep with me tonight"),
            // ---- Unwanted propositions (Devanagari)
            q("फ्री हो क्या"), q("फ्री हो आप"), q("फ्री है क्या"), q("आज रात को फ्री"),
            q("रात को फ्री"), q("आज रात फ्री"), q("आज रात क्या कर रही हो"),
            q("रात को मिलते हैं"), q("रात को मिलो"), q("कितना लोगी"), q("कितने पैसे लोगी"),
            q("रेट क्या है"), q("चलोगी क्या"), q("चलेगी क्या"), q("चलती है क्या"),
            q("मेरे साथ चलोगी"), q("होटल चलते हैं"), q("होटल चलो"), q("रूम पे चलो"),
            q("घर छोड़ दूं"), q("लिफ्ट दे दूं"), q("डेट पे चलो"), q("नंबर दो ना"),
            q("नंबर देना"), q("अकेली हो क्या"), q("अकेले हो क्या"), q("क्या मस्त लग रही हो", 0.75),
            q("बहुत सेक्सी"), q("तुम बहुत सेक्सी"), q("क्या फिगर है"), q("क्या आइटम है"),
            q("क्या माल है"), q("मस्त माल"), q("पटाखा", 0.7), q("लाइन मार"),
            q("किस दो"), q("गले लग जाओ"), q("पास आओ", 0.75), q("मेरे पास आओ", 0.8),
            q("बात तो करो"), q("बात करो ना"), q("इग्नोर मत करो"), q("इतना एटीट्यूड"),
            q("हेलो मैडम", 0.55), q("हेलो बेबी", 0.7),
            // ---- Threats / coercion / pursuit (more)
            t("tujhe utha lunga"), t("utha ke le jaunga"), t("utha ke le jayenge"),
            t("jaan se khatam kar dunga"), t("khatam kar dunga"), t("khatam kar denge"),
            t("tujhe maar dalunga"), t("tera khoon pi jaunga"), t("tujhe chhodunga nahi"),
            t("bacha ke dikha"), t("dekh kaise bachti hai"), t("kaise bachegi"), t("bach ke dikha"),
            t("tera rape kar dunga"), t("rape kar dunga"), t("rape karunga"), t("izzat loot lunga"),
            t("izzat lut lunga"), t("acid daal dunga"), t("acid fek dunga"), t("chaku maar dunga"),
            t("goli maar dunga"), t("goli maar dega"), t("jala dunga"), t("jala denge"),
            t("टांगें तोड़ दूंगा"), t("तेरा रेप कर दूंगा"), t("रेप कर दूंगा"), t("इज्जत लूट लूंगा"),
            t("तेजाब डाल दूंगा"), t("चाकू मार दूंगा"), t("गोली मार दूंगा"), t("खत्म कर दूंगा"),
            t("कैसे बचेगी"), t("बचके दिखा"), t("उठा के ले जाऊंगा"), t("जला दूंगा"),
            c("chup chap chal"), c("chupchap chal"), c("chup chap baith"), c("shor mat kar"),
            c("shor mat machana"), c("awaaz nikali to"), c("awaaz mat nikal"), c("munh band rakh"),
            c("muh band rakh"), c("muh band kar"), c("hilna mat"), c("hilo mat"), c("idhar aa"),
            c("idhar aao"), c("andar chal"), c("andar baith"), c("gaadi mein baith ja"),
            c("car mein baith"), c("chal mere saath abhi"), c("zyada hoshiyari mat kar"),
            c("hoshiyari mat dikha"), c("chup chaap chal"), c("चुप चाप चल"), c("चुपचाप चल"),
            c("शोर मत कर"), c("आवाज़ निकाली तो"), c("मुँह बंद रख"), c("मुंह बंद रख"),
            c("मुंह बंद कर"), c("हिलना मत"), c("इधर आ"), c("इधर आओ"), c("अंदर चल"),
            c("गाड़ी में बैठ जा"), c("ज्यादा होशियारी मत कर"),
            p("ruk jao zara", 0.75), p("ruk ruk"), p("ruko zara", 0.75), p("kahan bhaag rahi"),
            p("kahan bhag rahi"), p("bhaag mat"), p("bhag mat"), p("peeche aa raha"),
            p("peeche peeche"), p("tera peecha"), p("peecha nahi chhodunga", 0.9),
            p("ghar tak chhod dunga"), p("ghar tak aaunga"), p("tere ghar tak"),
            p("रुक जाओ ज़रा", 0.75), p("रुको ज़रा", 0.75), p("कहाँ भाग रही"), p("भाग मत"),
            p("पीछे आ रहा"), p("पीछे पीछे"), p("तेरा पीछा"), p("घर तक छोड़ दूंगा"),
            // ---- Cuss words and abuse (Hinglish; fuzzy key absorbs spelling)
            a("madarchod", 0.65), a("maderchod", 0.65), a("mc", 0.45), a("bc", 0.45),
            a("behnchod", 0.65), a("bhosdiwale", 0.65), a("bhosadi", 0.6), a("bhosada", 0.6),
            a("bhosdika", 0.65), a("bhosri", 0.6), a("chutiyapa", 0.5), a("chutmarike", 0.65),
            a("gaandu", 0.6), a("gand", 0.55), a("gaand", 0.6), a("gaand mara", 0.65),
            a("gaand mein", 0.6), a("lauda", 0.6), a("lavda", 0.6), a("laude", 0.6),
            a("loda", 0.55), a("lund", 0.55), a("lunds", 0.55), a("lawda", 0.6),
            a("choot", 0.65), a("chut", 0.55), a("chutad", 0.6), a("chodna", 0.6),
            a("chod dunga", 0.7), a("chod dena", 0.65), a("chodunga", 0.7), a("chudai", 0.6),
            a("chudwana", 0.6), a("chud gayi", 0.55), a("tatte", 0.55), a("tatti", 0.45),
            a("hijra", 0.55), a("hijde", 0.55), a("chakka", 0.55), a("randwa", 0.6),
            a("raand", 0.65), a("randi", 0.65), a("randikhana", 0.65), a("veshya", 0.6),
            a("kanjri", 0.55), a("kanjar", 0.55), a("bazaru", 0.55), a("bazaaru", 0.55),
            a("dhandhe wali", 0.6), a("dhandhewali", 0.6), a("call girl", 0.55),
            a("kutiya", 0.6), a("kutti ke bachche", 0.6), a("kutte ki aulad", 0.6),
            a("kutte ke bachche", 0.6), a("haramkhor", 0.55), a("harami", 0.55),
            a("haramzadi", 0.6), a("haramzada", 0.6), a("nalayak", 0.45), a("nikamma", 0.4),
            a("kamina", 0.5), a("kamini", 0.5), a("kamine", 0.5), a("badtameez", 0.45),
            a("besharam", 0.45), a("behaya", 0.5), a("badchalan", 0.55), a("ghatiya", 0.45),
            a("gadha", 0.4), a("ullu ka pattha", 0.45), a("ullu", 0.35), a("pagal", 0.3),
            a("bewakoof", 0.35), a("jahil", 0.35), a("saale", 0.4), a("sale", 0.35),
            a("sali", 0.4), a("bhadwa", 0.6), a("bhadwe", 0.6), a("bhadva", 0.6),
            a("dalla", 0.55), a("dalal", 0.4), a("gashti", 0.55), a("gandi aulad", 0.55),
            a("maa ki", 0.6), a("maa ka", 0.55), a("teri maa", 0.6), a("teri maa ki", 0.7),
            a("teri behen", 0.6), a("teri behen ki", 0.7), a("behen ke", 0.6), a("maa chod", 0.65),
            a("behen chod", 0.65), a("maa ke", 0.5), a("tere baap", 0.45), a("baap ka", 0.4),
            a("nikal yahan se", 0.5), a("dafa ho ja", 0.5), a("dafa ho jao", 0.5),
            a("door hat", 0.45), a("chal nikal", 0.5), a("bhaad mein ja", 0.55),
            a("bhad mein ja", 0.55), a("jahannum mein ja", 0.5), a("mar ja", 0.65),
            a("mar jao", 0.65), a("marna chahiye", 0.5), a("shakal dekh", 0.5),
            a("aukaat dikha", 0.6), a("aukaat mein", 0.55), a("zubaan sambhal", 0.6),
            a("zubaan sambhal ke", 0.6), a("jubaan sambhal", 0.6), a("tameez se", 0.4),
            a("bakwaas", 0.4), a("bakwas", 0.4), a("bakchodi", 0.45), a("chup kar", 0.55),
            a("chup ho ja", 0.55), a("chup baith", 0.55), a("shut your mouth", 0.6),
            a("stfu", 0.55), a("get out", 0.4), a("go to hell", 0.55), a("drop dead", 0.65),
            a("son of a bitch", 0.65), a("motherfucker", 0.65), a("mother fucker", 0.65),
            a("fucking bitch", 0.7), a("dickhead", 0.55), a("dick head", 0.55), a("prick", 0.5),
            a("scumbag", 0.5), a("pervert", 0.5), a("creep", 0.45), a("loser", 0.35),
            a("moron", 0.4), a("stupid", 0.35), a("ugly", 0.4), a("fat", 0.3), a("trash", 0.4),
            a("wanker", 0.5), a("twat", 0.55), a("slag", 0.55), a("tramp", 0.5), a("skank", 0.55),
            a("hoe", 0.55), a("bloody hell", 0.35), a("damn you", 0.4), a("piece of shit", 0.6),
            // ---- Cuss words (Devanagari)
            a("मादरचोद", 0.65), a("मादर चोद", 0.65), a("बहन चोद", 0.65), a("बहनचोद", 0.65),
            a("भोसड़ी", 0.6), a("भोसड़ीके", 0.65), a("भोसड़ीवाले", 0.65), a("भोंसड़ी", 0.6),
            a("चूतिया", 0.6), a("चूतियापा", 0.5), a("चुतमारिके", 0.65), a("गांडू", 0.6),
            a("गांड", 0.6), a("गांड मारा", 0.65), a("लौड़ा", 0.6), a("लवड़ा", 0.6), a("लौड़े", 0.6),
            a("लंड", 0.55), a("चूत", 0.65), a("चुत", 0.55), a("चोदना", 0.6), a("चोद दूंगा", 0.7),
            a("चुदाई", 0.6), a("टट्टी", 0.45), a("हिजड़ा", 0.55), a("हिजड़े", 0.55), a("छक्का", 0.55),
            a("रांड", 0.65), a("रंडी", 0.65), a("रंडीखाना", 0.65), a("वेश्या", 0.6),
            a("कंजरी", 0.55), a("बाज़ारू", 0.55), a("बाजारू", 0.55), a("कुतिया", 0.6),
            a("कुत्ते की औलाद", 0.6), a("कुत्ते के बच्चे", 0.6), a("हरामखोर", 0.55),
            a("हरामी", 0.55), a("हरामज़ादी", 0.6), a("हरामज़ादा", 0.6), a("हरामजादा", 0.6),
            a("नालायक", 0.45), a("निकम्मा", 0.4), a("कमीना", 0.5), a("कमीनी", 0.5),
            a("बदतमीज़", 0.45), a("बदतमीज", 0.45), a("बेशर्म", 0.45), a("बेहया", 0.5),
            a("बदचलन", 0.55), a("घटिया", 0.45), a("गधा", 0.4), a("उल्लू का पट्ठा", 0.45),
            a("भड़वा", 0.6), a("भड़वे", 0.6), a("दल्ला", 0.55), a("गश्ती", 0.55),
            a("तेरी माँ", 0.6), a("तेरी मां", 0.6), a("तेरी माँ की", 0.7), a("तेरी बहन की", 0.7),
            a("माँ चोद", 0.65), a("तेरी बहन", 0.6), a("निकल यहाँ से", 0.5), a("दफा हो जा", 0.5),
            a("चल निकल", 0.5), a("भाड़ में जा", 0.55), a("मर जा", 0.65), a("मर जाओ", 0.65),
            a("औकात दिखा", 0.6), a("औकात में", 0.55), a("ज़बान संभाल", 0.6), a("जुबान संभाल", 0.6),
            a("बकवास", 0.4), a("बकचोदी", 0.45), a("चुप हो जा", 0.55), a("चुप बैठ", 0.55),
        ]
    }

    /// English cuss words, slurs for women, sexual insults and angry
    /// phrases. Mild words score low on purpose: one is a nudge, a run of
    /// them (or one with a threat) is what triggers a check-in.
    static var englishCussWords: [SpeechPattern] {
        func a(_ phrase: String, _ severity: Double) -> SpeechPattern {
            SpeechPattern(phrase: phrase, category: .anger, severity: severity)
        }
        return [
            // Strong
            a("fuck", 0.55), a("fucked", 0.55), a("fucker", 0.6), a("fuckers", 0.6),
            a("fucking", 0.55), a("fuckin", 0.55), a("fuck off", 0.65), a("fuck you", 0.7),
            a("fuck yourself", 0.7), a("fuck her", 0.7), a("fuck me", 0.6), a("fucktard", 0.6),
            a("motherfucker", 0.65), a("motherfucking", 0.65), a("mf", 0.4),
            a("cunt", 0.65), a("cunts", 0.65), a("twat", 0.55), a("bitch", 0.6),
            a("bitches", 0.6), a("bitchy", 0.5), a("slut", 0.65), a("sluts", 0.65),
            a("slutty", 0.6), a("whore", 0.65), a("whores", 0.65), a("hooker", 0.55),
            a("prostitute", 0.5), a("escort", 0.4), a("skank", 0.55), a("tramp", 0.5),
            a("slag", 0.55), a("hoe", 0.55), a("thot", 0.55), a("cumslut", 0.7),
            a("cum", 0.45), a("cock", 0.55), a("cocksucker", 0.65), a("dick", 0.5),
            a("dickhead", 0.55), a("dicks", 0.5), a("pussy", 0.6), a("pussies", 0.6),
            a("tits", 0.5), a("boobs", 0.45), a("jerk off", 0.55), a("wank", 0.5),
            a("wanker", 0.5), a("blowjob", 0.6), a("blow job", 0.6), a("handjob", 0.6),
            a("anal", 0.5), a("porn", 0.4), a("horny", 0.55), a("get laid", 0.5),
            a("rape", 0.7), a("raped", 0.7), a("rapist", 0.65), a("molest", 0.7),
            a("nigger", 0.7), a("nigga", 0.55), a("faggot", 0.65), a("fag", 0.55),
            a("retard", 0.5), a("retarded", 0.5), a("spastic", 0.5), a("tranny", 0.6),
            // Medium
            a("asshole", 0.6), a("assholes", 0.6), a("arsehole", 0.6), a("ass", 0.4),
            a("asshat", 0.5), a("bastard", 0.6), a("bastards", 0.6), a("bollocks", 0.45),
            a("bugger", 0.35), a("shit", 0.4), a("shitty", 0.4), a("bullshit", 0.45),
            a("shithead", 0.55), a("shitface", 0.55), a("dipshit", 0.5), a("horseshit", 0.45),
            a("piece of shit", 0.6), a("son of a bitch", 0.65), a("sob", 0.3),
            a("prick", 0.5), a("pricks", 0.5), a("douche", 0.45), a("douchebag", 0.5),
            a("jackass", 0.45), a("dumbass", 0.5), a("smartass", 0.4), a("badass", 0.2),
            a("scumbag", 0.5), a("sleazebag", 0.5), a("dirtbag", 0.5), a("lowlife", 0.45),
            a("creep", 0.45), a("creepy", 0.4), a("pervert", 0.5), a("perv", 0.5),
            a("pedo", 0.65), a("pedophile", 0.65), a("stalker", 0.5), a("psycho", 0.4),
            a("crap", 0.35), a("crappy", 0.3), a("damn", 0.3), a("damn you", 0.4),
            a("goddamn", 0.4), a("goddam", 0.4), a("hell", 0.2), a("go to hell", 0.55),
            a("burn in hell", 0.6), a("screw you", 0.55), a("screw off", 0.5),
            a("piss off", 0.5), a("pissed off", 0.35), a("piss", 0.35), a("sod off", 0.5),
            a("bugger off", 0.45), a("get lost", 0.5), a("get out", 0.4), a("go away", 0.35),
            a("shut up", 0.55), a("shut your mouth", 0.6), a("shut your trap", 0.6),
            a("shut the fuck up", 0.75), a("stfu", 0.55), a("gtfo", 0.55), a("wtf", 0.35),
            a("drop dead", 0.65), a("die", 0.35), a("go die", 0.65), a("kill yourself", 0.7),
            a("kys", 0.65), a("i hate you", 0.5), a("hate you", 0.5), a("you disgust me", 0.5),
            // Insults and contempt
            a("idiot", 0.4), a("idiots", 0.4), a("moron", 0.4), a("morons", 0.4),
            a("imbecile", 0.4), a("dumb", 0.3), a("dumbo", 0.3), a("stupid", 0.35),
            a("stupid bitch", 0.7), a("dumb bitch", 0.7), a("fat bitch", 0.7), a("ugly bitch", 0.7),
            a("loser", 0.35), a("losers", 0.35), a("jerk", 0.35), a("jerks", 0.35),
            a("clown", 0.25), a("trash", 0.4), a("garbage", 0.3), a("worthless", 0.5),
            a("pathetic", 0.4), a("disgusting", 0.4), a("ugly", 0.4), a("fatso", 0.45),
            a("slob", 0.35), a("cow", 0.35), a("pig", 0.35), a("dog", 0.15),
            a("you bitch", 0.7), a("you whore", 0.75), a("you slut", 0.75), a("you cunt", 0.75),
            a("you bastard", 0.65), a("you asshole", 0.65), a("you idiot", 0.5),
            a("you stupid", 0.5), a("you dirty", 0.5), a("dirty whore", 0.75),
            a("dirty slut", 0.75), a("filthy", 0.4), a("nasty bitch", 0.7),
            // Sexual harassment phrases
            a("suck my", 0.7), a("suck it", 0.6), a("suck me", 0.7), a("lick my", 0.7),
            a("show me your", 0.6), a("take it off", 0.55), a("take off your", 0.6),
            a("get naked", 0.65), a("strip for me", 0.65), a("want to fuck", 0.75),
            a("wanna fuck", 0.75), a("let me fuck", 0.8), a("i will fuck", 0.8),
            a("fuck you up", 0.8), a("beat the shit", 0.8), a("beat you up", 0.8),
            a("smash your face", 0.8), a("shut it", 0.45), a("you owe me", 0.4),
            a("you asked for it", 0.65), a("you deserve it", 0.55), a("you will regret", 0.65),
            a("you'll regret", 0.65), a("you'll pay", 0.7), a("you will pay for", 0.7),
            // Angry shouting phrases
            a("what the fuck", 0.5), a("what the hell", 0.3), a("who the fuck", 0.55),
            a("how dare you", 0.4), a("watch your mouth", 0.55), a("watch it", 0.4),
            a("back off", 0.4), a("get away", 0.35), a("get off me", 0.5), a("piss me off", 0.4),
            a("i swear", 0.2), a("i'm warning you", 0.55), a("i am warning you", 0.55),
            a("don't test me", 0.55), a("do not test me", 0.55), a("try me", 0.45),
            a("you're dead", 0.9), a("you are dead meat", 0.9), a("dead meat", 0.8),
        ]
    }
}
