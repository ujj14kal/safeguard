import AVFoundation
import XCTest

/// On-device speech matcher: threats flagged with the right category,
/// ordinary talk (including substring traps) ignored, quotation/negation/
/// benign-frame guards, and the /verify-speech edge gate. No audio, no keys.
final class SpeechMatcherTests: XCTestCase {
    private let matcher = SpeechMatcher()

    // MARK: - Flags

    func testExplicitThreat() {
        let found = matcher.match("I will kill you if you move")
        XCTAssertEqual(found?.category, .threat)
        XCTAssertEqual(found?.severity ?? 0, 1.0, accuracy: 1e-9)
    }

    func testCoercion() {
        let found = matcher.match("Come with me right now")
        XCTAssertEqual(found?.category, .coercion)
        XCTAssertEqual(found?.severity ?? 0, 0.9, accuracy: 1e-9)
    }

    func testPursuit() {
        XCTAssertEqual(matcher.match("Don't run from me")?.category, .pursuit)
    }

    func testProposition() {
        XCTAssertEqual(
            matcher.match("Hey baby, give me your number")?.category, .proposition
        )
    }

    func testAbuse() {
        let found = matcher.match("Shut up, nobody will help you")
        // Strongest wins: the nobody-phrase outranks "shut up".
        XCTAssertEqual(found?.category, .abuse)
        XCTAssertEqual(found?.severity ?? 0, 0.85, accuracy: 1e-9)
    }

    func testDistress() {
        let found = matcher.match("Please, leave me alone!")
        XCTAssertEqual(found?.category, .distress)
        XCTAssertEqual(found?.severity ?? 0, 0.95, accuracy: 1e-9)
    }

    func testStrongestMatchWins() {
        let found = matcher.match("shut up and come with me")
        XCTAssertEqual(found?.category, .coercion)
    }

    func testCaseInsensitive() {
        XCTAssertEqual(matcher.match("COME WITH ME")?.category, .coercion)
    }

    func testWordIndexAnchorsSnippet() {
        let found = matcher.match("hello there come with me please")
        XCTAssertEqual(found?.wordIndex, 2)
    }

    // MARK: - Ordinary talk stays silent

    func testOrdinaryConversationIgnored() {
        for line in [
            "What time is dinner tonight?",
            "I love this song, turn it up",
            "The manager staged an image review", // image/manage/stage traps
            "Did you manage to image the stage?",
            "Let's follow the recipe step by step",
        ] {
            XCTAssertNil(matcher.match(line), line)
        }
    }

    func testBenignInvitationMatchesAndReliesOnBackend() {
        // "Come with me to the shops" matches on-device; Muse's context +
        // directed_at_wearer downgrades it. An accepted, documented gap.
        XCTAssertEqual(
            matcher.match("Come with me to the shops tomorrow?")?.category, .coercion
        )
    }

    func testWholeWordsOnly() {
        XCTAssertNil(matcher.match("shutup"))
        XCTAssertNil(matcher.match("killer whales are beautiful"))
        XCTAssertNil(matcher.match("open calculators")) // code-phrase-shaped, not speech
    }

    func testEmptyTranscript() {
        XCTAssertNil(matcher.match(""))
        XCTAssertNil(matcher.match("   "))
    }

    func testOwnSpokenTextsMatchNothing() {
        // The app never pauses the mic for TTS (the unsafe phrase must work
        // at ANY time), so our own spoken texts must match no pattern and
        // no code phrase — TTS echo can never trigger us.
        let safety = SafetyConfig()
        let phrases = CodePhraseMatcher(config: safety)
        XCTAssertNil(matcher.match(safety.askPhrase))
        XCTAssertNil(phrases.match(safety.askPhrase))
        XCTAssertNil(matcher.match(safety.listeningCueText))
        XCTAssertNil(phrases.match(safety.listeningCueText))
    }

    // MARK: - Guards

    func testQuotationDiscounts() {
        let found = matcher.match("She said \"come with me\" loudly")
        XCTAssertEqual(found?.category, .coercion)
        XCTAssertEqual(found?.severity ?? 0, 0.9 * 0.3, accuracy: 1e-9)
    }

    func testQuotationNeedsBothMarks() {
        // One stray quote is punctuation, not reported speech.
        let found = matcher.match("She said come with me\" loudly")
        XCTAssertEqual(found?.severity ?? 0, 0.9, accuracy: 1e-9)
    }

    func testNegationDiscountsThreats() {
        let found = matcher.match("I would never hurt you, I promise")
        XCTAssertEqual(found?.category, .threat)
        XCTAssertEqual(found?.severity ?? 0, 0.3, accuracy: 1e-9)
    }

    func testDistressNeverNegationDiscounted() {
        // "Don't touch me" is the wearer in danger, not a negated threat.
        for line in ["Don't touch me!", "Do not hurt me, please"] {
            let found = matcher.match(line)
            XCTAssertEqual(found?.category, .distress, line)
            XCTAssertEqual(found?.severity ?? 0, 0.95, accuracy: 1e-9, line)
        }
    }

    func testBenignFilmQuoteIgnored() {
        XCTAssertNil(matcher.match("Come with me if you want to live"))
    }

    func testBenignFrameMechanism() {
        // Synthetic overlap proving containment-cancelling works.
        var config = SpeechConfig()
        config.patterns = [SpeechPattern(phrase: "battery", category: .abuse, severity: 1.0)]
        XCTAssertNil(SpeechMatcher(config: config).match("dead battery"))
        XCTAssertNotNil(SpeechMatcher(config: config).match("battery low warning"))
    }

    func testBackendSeverityMapping() {
        XCTAssertEqual(SpeechMatcher.backendSeverity("high"), 0.9, accuracy: 1e-9)
        XCTAssertEqual(SpeechMatcher.backendSeverity("medium"), 0.6, accuracy: 1e-9)
        let low = SpeechMatcher.backendSeverity("low")
        XCTAssertLessThan(low, SafetyConfig().speechStrongThreshold)
        XCTAssertEqual(SpeechMatcher.backendSeverity("extreme"), 0, accuracy: 1e-9)
    }

    func testConfigurablePatterns() {
        var config = SpeechConfig()
        config.patterns = [SpeechPattern(phrase: "marco polo", category: .abuse, severity: 0.5)]
        XCTAssertNotNil(SpeechMatcher(config: config).match("marco polo!"))
        XCTAssertNil(SpeechMatcher(config: config).match("come with me"))
    }
}

/// /verify-speech edge gate: fires on strong speech, at most once per
/// interval, so a continuous rant sends one snippet.
final class SpeechVerifyGateTests: XCTestCase {
    func testFiresOnStrong() {
        var gate = SpeechVerifyGate(triggerSeverity: 0.7, minInterval: 30)
        XCTAssertTrue(gate.consume(severity: 0.9, at: 100))
    }

    func testWeakNeverFires() {
        var gate = SpeechVerifyGate(triggerSeverity: 0.7, minInterval: 30)
        for _ in 0..<10 {
            XCTAssertFalse(gate.consume(severity: 0.5, at: 100))
        }
    }

    func testMinIntervalSuppressesRefire() {
        var gate = SpeechVerifyGate(triggerSeverity: 0.7, minInterval: 30)
        XCTAssertTrue(gate.consume(severity: 0.9, at: 100))
        XCTAssertFalse(gate.consume(severity: 1.0, at: 129.9))
        XCTAssertTrue(gate.consume(severity: 1.0, at: 130))
    }

    func testReset() {
        var gate = SpeechVerifyGate(triggerSeverity: 0.7, minInterval: 30)
        XCTAssertTrue(gate.consume(severity: 0.9, at: 100))
        gate.reset()
        XCTAssertTrue(gate.consume(severity: 0.9, at: 101))
    }
}

/// Hindi, Hinglish and cuss-word/anger tracking.
final class HindiSpeechTests: XCTestCase {
    private let matcher = SpeechMatcher()

    func testDevanagariThreatIsFlagged() {
        let match = matcher.match("तुझे जान से मार दूंगा")
        XCTAssertEqual(match?.category, .threat)
        XCTAssertGreaterThanOrEqual(match?.severity ?? 0, 0.9)
    }

    func testRomanisedHindiThreatIsFlagged() {
        XCTAssertEqual(matcher.match("main tujhe jaan se maar dunga")?.category, .threat)
    }

    func testHindiCoercionPursuitAndDistress() {
        XCTAssertEqual(matcher.match("चल मेरे साथ गाड़ी में बैठ")?.category, .coercion)
        XCTAssertEqual(matcher.match("ruk ja kahan ja rahi hai")?.category, .pursuit)
        XCTAssertEqual(matcher.match("बचाओ मुझे छोड़ दो")?.category, .distress)
        XCTAssertEqual(matcher.match("police ko bulao")?.category, .distress)
    }

    func testNuktaAndChandrabinduSpellingsMatch() {
        // Recognisers write the same words with and without nukta/chandrabindu.
        XCTAssertNotNil(matcher.match("आवाज मत करना"))
        XCTAssertNotNil(matcher.match("आवाज़ मत करना"))
        XCTAssertNotNil(matcher.match("कहां जा रही है"))
        XCTAssertNotNil(matcher.match("कहाँ जा रही है"))
    }

    func testSingleCussWordIsTrackedButBelowCheckInThreshold() {
        for text in ["bitch", "अबे साले", "kamina hai tu", "madarchod"] {
            let match = matcher.match(text)
            XCTAssertEqual(match?.category, .anger, text)
            XCTAssertLessThan(match?.severity ?? 1, SafetyConfig().speechStrongThreshold, text)
        }
    }

    func testRepeatedCussingEscalatesToCheckInSeverity() {
        let match = matcher.match("chutiya saala kamina gandu harami")
        XCTAssertEqual(match?.category, .anger)
        XCTAssertGreaterThanOrEqual(
            match?.severity ?? 0, SafetyConfig().speechStrongThreshold
        )
    }

    func testEnglishRepeatedCussingEscalates() {
        let match = matcher.match("you fucking bitch asshole")
        XCTAssertGreaterThanOrEqual(
            match?.severity ?? 0, SafetyConfig().speechStrongThreshold
        )
    }

    func testOrdinaryHindiAndHinglishIsNotFlagged() {
        for text in [
            "आज मौसम बहुत अच्छा है", "kal chai peene chalte hain", "mujhe bhookh lagi hai",
            "time pass kar raha hoon", "तुम कैसे हो",
        ] {
            XCTAssertNil(matcher.match(text), text)
        }
    }

    func testDevanagariQuotationIsDiscounted() {
        let quoted = matcher.match("उसने कहा \"मार दूंगा\" फिल्म में")
        let plain = matcher.match("मार दूंगा")
        XCTAssertLessThan(quoted?.severity ?? 1, plain?.severity ?? 0)
    }

    func testHindiCodePhrasesWorkInBothScripts() {
        let codes = CodePhraseMatcher()
        XCTAssertEqual(codes.match("कैलकुलेटर खोलो"), .safePhrase)
        XCTAssertEqual(codes.match("ओपन कैलकुलेटर"), .safePhrase)
        XCTAssertEqual(codes.match("calculator kholo"), .safePhrase)
        XCTAssertEqual(codes.match("ऐप स्टोर खोलो"), .unsafePhrase)
        XCTAssertEqual(codes.match("ओपन ऐप स्टोर"), .unsafePhrase)
        XCTAssertEqual(codes.match("app store kholo please"), .unsafePhrase)
        XCTAssertNil(codes.match("मुझे कैलकुलेटर चाहिए"))
    }

    func testHindiVoiceCommandsAndAnswers() {
        let parser = VoiceCommandParser()
        XCTAssertEqual(parser.parse("सेफगार्ड स्थिति बताओ"), .status)
        XCTAssertEqual(parser.parse("safeguard band karo"), .stopProtecting)
        XCTAssertNil(parser.parse("सुरक्षा शुरू करो"), "wake word still required")
        var confirm = StopConfirmation()
        confirm.request(at: 0)
        XCTAssertEqual(confirm.answer("हाँ", at: 1), .confirmed)
        confirm.request(at: 2)
        XCTAssertEqual(confirm.answer("नहीं", at: 3), .denied)
    }

    func testLocaleResolution() {
        XCTAssertEqual(SpeechLocale.resolve(setting: "hi", preferredLanguages: ["en-IN"]), "hi-IN")
        XCTAssertEqual(SpeechLocale.resolve(setting: "en", preferredLanguages: ["hi-IN"]), "en-IN")
        XCTAssertEqual(SpeechLocale.resolve(setting: "auto", preferredLanguages: ["hi-IN"]), "hi-IN")
        XCTAssertEqual(SpeechLocale.resolve(setting: "auto", preferredLanguages: ["en-GB"]), "en-IN")
    }
}

/// Bigger vocabulary, spelling tolerance and silent rating.
final class VocabularyAndRatingTests: XCTestCase {
    private let matcher = SpeechMatcher()

    func testUserExamplePropositionIsFlagged() {
        let match = matcher.match("free ho kya aap aaj raat ko")
        XCTAssertEqual(match?.category, .proposition)
        XCTAssertGreaterThanOrEqual(match?.severity ?? 0, SafetyConfig().speechStrongThreshold)
    }

    func testUserExampleCussWordsAreAllTracked() {
        for word in ["chutiya", "bhosdike", "randi"] {
            XCTAssertEqual(matcher.match(word)?.category, .anger, word)
        }
        let run = matcher.match("chutiya bhosdike randi")
        XCTAssertGreaterThanOrEqual(run?.severity ?? 0, SafetyConfig().speechStrongThreshold)
    }

    func testSpellingVariantsMatchTheSameWord() {
        for variant in ["chutia", "chootiya", "bhosadike", "bhosdika", "madarchod", "maderchod", "randii", "saala", "sala"] {
            XCTAssertNotNil(matcher.match(variant), variant)
        }
    }

    func testFuzzyKeyDoesNotMergeUnrelatedEverydayWords() {
        for text in [
            "hum kal market ja rahe hain", "tum kaisi ho", "main ghar ja raha hoon",
            "khana kha liya kya", "aaj raat ko khana banega", "meeting ka time kya hai",
            "kitne baje aana hai", "free time mein kya karte ho",
        ] {
            XCTAssertNil(matcher.match(text), text)
        }
    }

    func testMoreHarassmentAndThreatPhrases() {
        XCTAssertEqual(matcher.match("kitna loge raat ke liye")?.category, .proposition)
        XCTAssertEqual(matcher.match("चलोगी क्या मेरे साथ")?.category, .proposition)
        XCTAssertEqual(matcher.match("tujhe utha ke le jaunga")?.category, .threat)
        XCTAssertEqual(matcher.match("chup chap chal warna")?.category, .coercion)
    }

    func testHapticLevels() {
        XCTAssertEqual(SpeechHapticLevel.level(for: 0.1), .none)
        XCTAssertEqual(SpeechHapticLevel.level(for: 0.45), .nudge)
        XCTAssertEqual(SpeechHapticLevel.level(for: 0.6), .elevated)
        XCTAssertEqual(SpeechHapticLevel.level(for: 0.9), .strong)
    }

    func testHapticGateThrottlesRepeatsButLetsHeavierThrough() {
        var gate = SpeechHapticGate(minInterval: 2.5)
        XCTAssertEqual(gate.consume(.nudge, at: 0), .nudge)
        XCTAssertEqual(gate.consume(.nudge, at: 1), .none)
        XCTAssertEqual(gate.consume(.strong, at: 1.2), .strong)
        XCTAssertEqual(gate.consume(.elevated, at: 2), .none)
        XCTAssertEqual(gate.consume(.nudge, at: 5), .nudge)
        XCTAssertEqual(gate.consume(.none, at: 6), .none)
    }
}

/// The wearer walking toward a still person must not look like an approach.
final class EgoMotionTests: XCTestCase {
    private let config = ThreatConfig()

    private func growingTrack(_ i: Int) -> Track {
        let h = 0.20 + 0.03 * Double(i)
        return Track(
            id: 1, box: CGRect(x: 0.4, y: 0.2, width: 0.3, height: h),
            confidence: 0.9, age: 10, missed: 0
        )
    }

    private func features(accel: Double?) -> PersonFeatures? {
        let extractor = FeatureExtractor(config: config)
        for i in 0..<12 {
            let t = Double(i) * 0.2
            if let accel { extractor.setEgoMotion(accelRMS: accel, at: t) }
            extractor.update(tracks: [growingTrack(i)], at: t)
        }
        return extractor.features(for: 1, at: 2.2)
    }

    func testStillWearerKeepsFullApproachScore() {
        let still = features(accel: 0.0)
        let none = features(accel: nil)
        XCTAssertGreaterThan(still?.trend ?? 0, 0.5)
        XCTAssertEqual(still?.trend ?? 0, none?.trend ?? 1, accuracy: 0.001)
    }

    func testWalkingWearerDiscountsApproach() {
        let still = features(accel: 0.0)
        let walking = features(accel: 0.4)
        XCTAssertLessThan(walking?.trend ?? 1, (still?.trend ?? 0) * 0.3)
        XCTAssertLessThan(walking?.speed ?? 1, (still?.speed ?? 0) * 0.3)
    }

    func testWalkingTowardStillPersonDoesNotAlert() {
        let scorer = ThreatScorer(config: config)
        let walking = features(accel: 0.4)!
        let still = features(accel: 0.0)!
        XCTAssertFalse(scorer.score(walking).alert)
        XCTAssertTrue(scorer.score(still).value > scorer.score(walking).value)
    }
}

final class MatcherSpeedTests: XCTestCase {
    func testMatchingALongWindowIsFastEnoughToRunPerChunk() {
        let matcher = SpeechMatcher()
        let text = String(repeating: "aaj mausam bahut accha hai hum kal market ja rahe hain ", count: 8)
        let start = Date()
        for _ in 0..<5 { _ = matcher.match(text) }
        let perCall = Date().timeIntervalSince(start) / 5
        XCTAssertLessThan(perCall, 0.15, "one match over ~90 words must stay well under a chunk")
    }
}

final class ConversationFlagTests: XCTestCase {
    func testFlagLabelsAndExpiry() {
        let flag = ConversationFlag(category: .proposition, severity: 0.7, at: 10)
        XCTAssertEqual(flag.label, "Unwanted advances")
        XCTAssertTrue(flag.isActive(at: 20))
        XCTAssertFalse(flag.isActive(at: 23))
    }

    func testHeavierFlagReplacesLighterOne() {
        let light = ConversationFlag(category: .anger, severity: 0.5, at: 0)
        let heavy = ConversationFlag(category: .threat, severity: 0.95, at: 2)
        XCTAssertEqual(ConversationFlag.merged(light, with: heavy).category, .threat)
    }

    func testLighterFlagKeepsBannerButRefreshesTime() {
        let heavy = ConversationFlag(category: .threat, severity: 0.95, at: 0)
        let light = ConversationFlag(category: .anger, severity: 0.5, at: 3)
        let merged = ConversationFlag.merged(heavy, with: light)
        XCTAssertEqual(merged.category, .threat)
        XCTAssertEqual(merged.at, 3)
    }

    func testExpiredFlagIsReplaced() {
        let old = ConversationFlag(category: .threat, severity: 0.95, at: 0)
        let new = ConversationFlag(category: .anger, severity: 0.5, at: 30)
        XCTAssertEqual(ConversationFlag.merged(old, with: new).category, .anger)
    }

    func testEveryCategoryHasALabel() {
        for category in SpeechCategory.allCases {
            XCTAssertFalse(ConversationFlag(category: category, severity: 0.5, at: 0).label.isEmpty)
        }
    }
}

final class EnglishCussTests: XCTestCase {
    private let matcher = SpeechMatcher()

    func testEnglishCussWordsAreTrackedAsAnger() {
        for text in ["you bitch", "what an asshole", "fuck off", "stupid idiot", "that bastard", "shut up", "pervert"] {
            let match = matcher.match(text)
            XCTAssertNotNil(match, text)
            XCTAssertTrue([.anger, .abuse].contains(match?.category), text)
        }
    }

    func testDirectedSexualInsultsReachTheCheckInLevel() {
        for text in ["you slut", "fuck you", "shut the fuck up", "you dirty whore", "i will fuck you up"] {
            XCTAssertGreaterThanOrEqual(
                matcher.match(text)?.severity ?? 0, SafetyConfig().speechStrongThreshold, text
            )
        }
    }

    func testRunOfMildCussingEscalates() {
        XCTAssertGreaterThanOrEqual(
            matcher.match("shit crap damn asshole")?.severity ?? 0, SafetyConfig().speechStrongThreshold
        )
    }

    func testOrdinaryEnglishWithSubstringTrapsIsNotFlagged() {
        for text in [
            "the class assignment is due", "I passed the bass guitar exam", "assume the best",
            "he is a classic cocktail bartender", "scunthorpe is a town", "grass is green",
            "the document is hell to read", "please manage the stage", "pass the salt",
            "I am dumbfounded by the analysis", "the title was a mistake",
        ] {
            XCTAssertNil(matcher.match(text) .flatMap { $0.severity >= 0.45 ? $0 : nil }, text)
        }
    }
}

final class JudgeScheduleTests: XCTestCase {
    func testSendsNewTalkOnceAndThrottles() {
        var s = SpeechJudgeSchedule(minInterval: 3)
        XCTAssertTrue(s.shouldSend("free ho kya aap", at: 0))
        XCTAssertFalse(s.shouldSend("free ho kya aap aaj raat", at: 1), "one call at a time")
        s.finished()
        XCTAssertFalse(s.shouldSend("free ho kya aap aaj raat", at: 2), "too soon")
        XCTAssertTrue(s.shouldSend("free ho kya aap aaj raat", at: 3.5))
    }

    func testSameTextIsNotSentTwiceAndTinyTalkIsSkipped() {
        var s = SpeechJudgeSchedule(minInterval: 1)
        XCTAssertFalse(s.shouldSend("hello", at: 0), "one word is not enough")
        XCTAssertTrue(s.shouldSend("hello there friend", at: 0))
        s.finished()
        XCTAssertFalse(s.shouldSend("hello there friend", at: 5))
    }

    func testTailKeepsNewestWordsWithinTheLimit() {
        var window = TranscriptWindow(windowSeconds: 20)
        window.append(String(repeating: "old ", count: 200), at: 0)
        window.append("the newest sentence", at: 1)
        let tail = window.tail(maxChars: 60)
        XCTAssertLessThanOrEqual(tail.count, 60)
        XCTAssertTrue(tail.hasSuffix("the newest sentence"))
    }
}

final class HearingTests: XCTestCase {
    func testQuietSpeechIsLiftedTowardTheTarget() {
        var gain = AutoGain()
        var applied: Float = 1
        for _ in 0..<40 { applied = gain.update(rms: 0.02) }
        XCTAssertGreaterThan(applied, 5, "0.02 -> about 0.14 needs ~7x")
        XCTAssertLessThanOrEqual(applied, 20)
    }

    func testSilenceAndRoomNoiseAreNotAmplified() {
        var gain = AutoGain()
        for _ in 0..<40 { XCTAssertEqual(gain.update(rms: 0.001), 1, accuracy: 0.0001) }
    }

    func testLoudSpeechIsNotBoostedAndGainFallsQuickly() {
        var gain = AutoGain()
        for _ in 0..<40 { _ = gain.update(rms: 0.02) }
        let afterLoud = gain.update(rms: 0.4)
        XCTAssertLessThan(afterLoud, 4)
        for _ in 0..<10 { _ = gain.update(rms: 0.4) }
        XCTAssertEqual(gain.gain, 1, accuracy: 0.05)
    }

    func testHigherSensitivityHearsQuieterSpeech() {
        // A faint voice at RMS 0.003 (about -50 dBFS).
        var normal = AutoGain(sensitivity: .normal)
        var high = AutoGain(sensitivity: .high)
        var max = AutoGain(sensitivity: .max)
        for _ in 0..<60 {
            _ = normal.update(rms: 0.003)
            _ = high.update(rms: 0.003)
            _ = max.update(rms: 0.003)
        }
        XCTAssertEqual(normal.gain, 1, accuracy: 0.001, "normal treats it as room noise")
        XCTAssertGreaterThan(high.gain, 5)
        XCTAssertGreaterThan(max.gain, high.gain)
        XCTAssertLessThanOrEqual(max.gain, 30)
    }

    func testSensitivityLowersTheShoutThreshold() {
        func fires(_ level: ListenSensitivity, db: Float) -> Bool {
            var d = LoudnessDetector(sensitivity: level)
            for i in 0..<80 where d.feed(levelDB: db, at: Double(i) * 0.025) { return true }
            return false
        }
        XCTAssertFalse(fires(.normal, db: -17))
        XCTAssertTrue(fires(.high, db: -17))
        XCTAssertFalse(fires(.high, db: -19))
        XCTAssertTrue(fires(.max, db: -19))
        XCTAssertFalse(fires(.max, db: -30), "ordinary talking never counts as shouting")
    }

    func testSensitivityChangesMidStreamKeepTheGain() {
        var gain = AutoGain(sensitivity: .normal)
        for _ in 0..<40 { _ = gain.update(rms: 0.02) }
        let before = gain.gain
        gain.apply(.max)
        XCTAssertEqual(gain.gain, before, accuracy: 0.0001)
    }

    func testShoutNeedsSustainedLoudSound() {
        var d = LoudnessDetector()
        // A single loud clap.
        XCTAssertFalse(d.feed(levelDB: -5, at: 0))
        XCTAssertFalse(d.feed(levelDB: -40, at: 0.05))
        // A second of ordinary talking.
        for i in 0..<40 { XCTAssertFalse(d.feed(levelDB: -28, at: 1 + Double(i) * 0.025)) }
        // Sustained shouting.
        var fired = false
        for i in 0..<60 where d.feed(levelDB: -10, at: 3 + Double(i) * 0.025) { fired = true }
        XCTAssertTrue(fired)
    }

    func testShoutFiresOnceThenCoolsDown() {
        var d = LoudnessDetector()
        var count = 0
        for i in 0..<200 where d.feed(levelDB: -8, at: Double(i) * 0.025) { count += 1 }
        XCTAssertEqual(count, 1, "5 s of continuous shouting is one trigger, not a stream")
    }
}

final class CloudEarSupportTests: XCTestCase {
    func testParsesTheServiceEvents() {
        XCTAssertEqual(CloudEarEvent.parse(#"{"type":"ready","ack":{"sessionId":"x"}}"#), .ready)
        XCTAssertEqual(CloudEarEvent.parse(#"{"type":"transcript","transcript":"तुझे जान","final":false}"#), .partial("तुझे जान"))
        XCTAssertEqual(
            CloudEarEvent.parse(#"{"type":"speechComplete","turnId":1,"transcript":"free ho kya?"}"#),
            .turnComplete("free ho kya?")
        )
        XCTAssertEqual(CloudEarEvent.parse(#"{"type":"error","message":"rate limited"}"#), .error("rate limited"))
        XCTAssertEqual(CloudEarEvent.parse(#"{"type":"speechStart","turnId":2}"#), .other)
        XCTAssertEqual(CloudEarEvent.parse(#"{"type":"transcript","transcript":""}"#), .other)
        XCTAssertEqual(CloudEarEvent.parse("not json"), .other)
    }

    func testChunkerMakes80msLittleEndianFrames() {
        var chunker = PCMChunker()
        XCTAssertTrue(chunker.append([Int16](repeating: 1, count: 1000)).isEmpty)
        let frames = chunker.append([Int16](repeating: 2, count: 1600))
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].count, 2560)
        XCTAssertEqual(Array(frames[0].prefix(4)), [1, 0, 1, 0])
        XCTAssertEqual(chunker.append([Int16](repeating: 3, count: 1300)).count, 1, "the 40 leftover samples carry over")
    }

    func testBackoffGrowsThenCaps() {
        var b = CloudEarBackoff()
        XCTAssertEqual([b.nextDelay(), b.nextDelay(), b.nextDelay(), b.nextDelay()], [1, 2, 4, 8])
        for _ in 0..<5 { _ = b.nextDelay() }
        XCTAssertEqual(b.nextDelay(), 15)
        b.reset()
        XCTAssertEqual(b.nextDelay(), 1)
    }

    func testGateStaysOffUntilThereIsAReasonThenHolds() {
        var gate = CloudEarGate(holdSeconds: 45)
        XCTAssertFalse(gate.shouldListen(enabled: true, alwaysOn: false, personNear: false, flagged: false, escalated: false, at: 0))
        XCTAssertTrue(gate.shouldListen(enabled: true, alwaysOn: false, personNear: true, flagged: false, escalated: false, at: 10))
        XCTAssertTrue(gate.shouldListen(enabled: true, alwaysOn: false, personNear: false, flagged: false, escalated: false, at: 50))
        XCTAssertFalse(gate.shouldListen(enabled: true, alwaysOn: false, personNear: false, flagged: false, escalated: false, at: 56))
    }

    func testGateRespectsTheSwitchesAndDemoMode() {
        var gate = CloudEarGate()
        XCTAssertFalse(gate.shouldListen(enabled: false, alwaysOn: true, personNear: true, flagged: true, escalated: true, at: 0))
        XCTAssertTrue(gate.shouldListen(enabled: true, alwaysOn: true, personNear: false, flagged: false, escalated: false, at: 0))
        XCTAssertTrue(gate.shouldListen(enabled: true, alwaysOn: false, personNear: false, flagged: true, escalated: false, at: 100))
        XCTAssertTrue(gate.shouldListen(enabled: true, alwaysOn: false, personNear: false, flagged: false, escalated: true, at: 101))
    }

    func testAppleTextIsSkippedWhileTheCloudEarDelivers() {
        var policy = TranscriptSourcePolicy()
        XCTAssertTrue(policy.appleMayFeedConversation(at: 0))
        policy.noteCloud(at: 10)
        XCTAssertFalse(policy.appleMayFeedConversation(at: 14))
        XCTAssertTrue(policy.appleMayFeedConversation(at: 19), "cloud went quiet: Apple takes over again")
    }

    func testRelayURLUsesTheWebsocketScheme() {
        XCTAssertEqual(CloudEarURL.relay(from: URL(string: "http://10.0.0.5:8000")!)?.absoluteString, "ws://10.0.0.5:8000/asr")
        XCTAssertEqual(CloudEarURL.relay(from: URL(string: "https://sg.example.com")!)?.absoluteString, "wss://sg.example.com/asr")
    }

    func testResamplerMakes16kMonoInt16() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
        buffer.frameLength = 4800
        for i in 0..<4800 { buffer.floatChannelData![0][i] = sinf(Float(i) * 0.1) * 0.5 }
        let resampler = PCM16Resampler()
        var all: [Int16] = []
        // A streaming converter holds back a few samples at first, so judge
        // a second of audio, not a single buffer.
        for _ in 0..<10 { all += try XCTUnwrap(resampler.convert(buffer)) }
        XCTAssertEqual(Double(all.count), 16_000, accuracy: 400, "1 s at 16 kHz")
        XCTAssertGreaterThan(all.map { abs(Int($0)) }.max() ?? 0, 5000, "level is preserved")
    }
}
