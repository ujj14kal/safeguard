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
