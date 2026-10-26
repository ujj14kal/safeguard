import XCTest

/// Voice commands: wake-word parsing with variants, the stop confirmation
/// flow, and code-phrase conflict resolution. Execution feedback (speech +
/// haptic + toast) lives in the view model; parsing here is pure.
final class VoiceCommandTests: XCTestCase {
    private let parser = VoiceCommandParser()

    // MARK: - Parsing

    func testEachCommand() {
        let cases: [(String, VoiceCommand)] = [
            ("Safeguard, start protecting", .startProtecting),
            ("Safeguard, stop protecting", .stopProtecting),
            ("Safeguard, status", .status),
            ("Safeguard, dim the screen", .dim),
            ("Safeguard, brighten", .brighten),
            ("Safeguard, open settings", .openSettings),
            ("Safeguard, go back", .goBack),
            ("Safeguard, call 112", .callEmergency),
            ("Safeguard, share my location", .shareLocation),
            ("Safeguard, help", .help),
        ]
        for (heard, want) in cases {
            XCTAssertEqual(parser.parse(heard), want, heard)
        }
    }

    func testAliases() {
        XCTAssertEqual(parser.parse("safeguard stop"), .stopProtecting)
        XCTAssertEqual(parser.parse("Safeguard, begin protecting"), .startProtecting)
        XCTAssertEqual(parser.parse("safeguard undim"), .brighten)
        XCTAssertEqual(parser.parse("Safeguard, settings"), .openSettings)
        XCTAssertEqual(parser.parse("safeguard back"), .goBack)
        XCTAssertEqual(parser.parse("Safeguard, call emergency"), .callEmergency)
        XCTAssertEqual(parser.parse("safeguard share location"), .shareLocation)
        XCTAssertEqual(parser.parse("Safeguard, what can you say?"), .help)
        XCTAssertEqual(parser.parse("safeguard report"), .status)
    }

    func testWakeWordVariantsAndNoise() {
        // Mis-hearings of the wake word + polite wrapping + case/punct.
        XCTAssertEqual(parser.parse("safe guard stop"), .stopProtecting)
        XCTAssertEqual(parser.parse("save guard, status"), .status)
        XCTAssertEqual(parser.parse("SAFEGUARD, STOP!"), .stopProtecting)
        XCTAssertEqual(parser.parse("Safeguard, please dim the screen now"), .dim)
        XCTAssertEqual(parser.parse("safeguard... um... help?"), .help)
    }

    func testWakeWordRequired() {
        XCTAssertNil(parser.parse("stop protecting"))
        XCTAssertNil(parser.parse("status"))
        XCTAssertNil(parser.parse("help me"))
        XCTAssertNil(parser.parse(""))
    }

    func testWakeWordMustLead() {
        XCTAssertNil(parser.parse("please safeguard stop"))
        XCTAssertNil(parser.parse("hey safeguard, status"))
    }

    func testUnknownCommandFallsThrough() {
        // Returns nil: the view model then threat-scans the transcript.
        XCTAssertNil(parser.parse("safeguard, dance"))
        XCTAssertNil(parser.parse("safeguard"))
        XCTAssertNil(parser.parse("safeguard, I love you"))
    }

    func testCodePhraseBeatsWakeWordCommand() {
        // Conflict resolution lives in view-model order (code phrases
        // first), but both halves are pinned here: the parser claims no
        // command in a code-phrase transcript, and the phrase matcher
        // still fires with the wake word present.
        XCTAssertNil(parser.parse("safeguard open calculator"))
        XCTAssertEqual(
            CodePhraseMatcher().match("safeguard open calculator"), .safePhrase
        )
        XCTAssertNil(parser.parse("safeguard, open app store"))
        XCTAssertEqual(
            CodePhraseMatcher().match("safeguard, open app store"), .unsafePhrase
        )
    }

    func testDistressCallFallsThroughToMatcher() {
        // "Call 112" WITHOUT the wake word is a cry for help, not the
        // command: the parser stays out and the threat matcher fires.
        XCTAssertNil(parser.parse("somebody call 112!"))
        XCTAssertEqual(
            SpeechMatcher().match("somebody call 112!")?.category, .distress
        )
    }

    // MARK: - Stop confirmation

    func testConfirmFlow() {
        var confirmation = StopConfirmation(windowSeconds: 5)
        confirmation.request(at: 100)
        XCTAssertTrue(confirmation.isPending(at: 100))
        XCTAssertEqual(confirmation.answer("yes", at: 101), .confirmed)
        XCTAssertFalse(confirmation.isPending(at: 101))
    }

    func testYesVariants() {
        for heard in ["yes please", "yeah", "yep, stop", "confirm"] {
            var confirmation = StopConfirmation(windowSeconds: 5)
            confirmation.request(at: 100)
            XCTAssertEqual(confirmation.answer(heard, at: 101), .confirmed, heard)
        }
    }

    func testDenyKeepsProtecting() {
        for heard in ["no", "nope", "cancel", "do not stop", "not sure"] {
            var confirmation = StopConfirmation(windowSeconds: 5)
            confirmation.request(at: 100)
            XCTAssertEqual(confirmation.answer(heard, at: 101), .denied, heard)
            XCTAssertFalse(confirmation.isPending(at: 101))
        }
    }

    func testDenyBeatsConfirm() {
        var confirmation = StopConfirmation(windowSeconds: 5)
        confirmation.request(at: 100)
        XCTAssertEqual(confirmation.answer("do not confirm", at: 101), .denied)
    }

    func testGibberishKeepsWaiting() {
        var confirmation = StopConfirmation(windowSeconds: 5)
        confirmation.request(at: 100)
        XCTAssertEqual(confirmation.answer("hmm, let me think", at: 101), .waiting)
        XCTAssertTrue(confirmation.isPending(at: 101))
        // ...then the wearer answers in time.
        XCTAssertEqual(confirmation.answer("yes", at: 104), .confirmed)
    }

    func testWindowLapses() {
        var confirmation = StopConfirmation(windowSeconds: 5)
        confirmation.request(at: 100)
        XCTAssertTrue(confirmation.isPending(at: 105))
        XCTAssertFalse(confirmation.isPending(at: 105.1))
        XCTAssertEqual(confirmation.answer("yes", at: 105.1), .expired)
    }

    func testAnswerWithNothingPending() {
        var confirmation = StopConfirmation(windowSeconds: 5)
        XCTAssertEqual(confirmation.answer("yes", at: 100), .expired)
    }

    func testCancel() {
        var confirmation = StopConfirmation(windowSeconds: 5)
        confirmation.request(at: 100)
        confirmation.cancel()
        XCTAssertEqual(confirmation.answer("yes", at: 101), .expired)
    }
}
