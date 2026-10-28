import XCTest

final class TranscriptWindowTests: XCTestCase {
    func testAppendsAndJoins() {
        var window = TranscriptWindow(windowSeconds: 20)
        window.append("hello there", at: 0)
        window.append("general kenobi", at: 1)
        XCTAssertEqual(window.transcript, "hello there general kenobi")
    }

    func testOldTextDropsOut() {
        var window = TranscriptWindow(windowSeconds: 20)
        window.append("ancient history", at: 0)
        window.append("fresh words", at: 25)
        XCTAssertEqual(window.transcript, "fresh words")
    }

    func testBoundaryTextSurvives() {
        var window = TranscriptWindow(windowSeconds: 20)
        window.append("edge", at: 0)
        window.append("fresh", at: 20)
        XCTAssertEqual(window.transcript, "edge fresh")
    }

    func testEmptyAppendsIgnored() {
        var window = TranscriptWindow(windowSeconds: 20)
        window.append("   ", at: 0)
        XCTAssertTrue(window.isEmpty)
        window.clear()
        XCTAssertTrue(window.isEmpty)
    }

    func testSnippetCentresTriggerSentence() {
        var window = TranscriptWindow(windowSeconds: 20)
        window.append("Nice weather today. Come with me now! See you later.", at: 0)
        let snippet = window.snippet(matchWordIndex: 4, maxChars: 400)
        XCTAssertTrue(snippet.contains("Come with me now!"), snippet)
    }

    func testSnippetCapsLength() {
        var window = TranscriptWindow(windowSeconds: 20)
        window.append(String(repeating: "word ", count: 200) + "come with me", at: 0)
        let snippet = window.snippet(matchWordIndex: 201, maxChars: 100)
        XCTAssertLessThanOrEqual(snippet.count, 100)
        XCTAssertTrue(snippet.contains("come with me"), snippet)
    }

    func testSnippetFallsBackToTail() {
        var window = TranscriptWindow(windowSeconds: 20)
        window.append("short tail here", at: 0)
        XCTAssertEqual(window.snippet(matchWordIndex: 99, maxChars: 400), "short tail here")
        XCTAssertEqual(TranscriptWindow().snippet(matchWordIndex: 0), "")
    }

    func testPipelineWritesNothingToDisk() {
        let manager = FileManager.default
        let roots = [manager.temporaryDirectory]
            + manager.urls(for: .cachesDirectory, in: .userDomainMask)
            + manager.urls(for: .documentDirectory, in: .userDomainMask)
        func snapshot() -> Set<String> {
            var paths = Set<String>()
            for root in roots {
                let items = (try? manager.subpathsOfDirectory(atPath: root.path)) ?? []
                for item in items {
                    paths.insert(root.appendingPathComponent(item).path)
                }
            }
            return paths
        }
        let before = snapshot()

        var window = TranscriptWindow(windowSeconds: 20)
        let matcher = SpeechMatcher()
        for step in 0..<50 {
            window.append("come with me at step \(step). ordinary filler words here.", at: Double(step))
            let text = window.transcript
            if let found = matcher.match(text) {
                _ = window.snippet(matchWordIndex: found.wordIndex)
            }
        }

        XCTAssertEqual(snapshot(), before, "transcript handling created files")
    }
}

final class ListeningSessionTests: XCTestCase {
    func testStartStop() {
        var session = ListeningSession()
        XCTAssertFalse(session.isLive)
        session.start(at: 100)
        XCTAssertTrue(session.isLive)
        session.stop()
        XCTAssertFalse(session.isLive)
        XCTAssertEqual(session.state, .idle)
    }

    func testRestartCadence() {
        var session = ListeningSession()
        session.start(at: 100)
        XCTAssertFalse(session.restartIfDue(at: 149.9))
        XCTAssertTrue(session.restartIfDue(at: 150))
        XCTAssertEqual(session.state, .listening(generation: 1, requestStart: 150))
        XCTAssertTrue(session.isLive)
    }

    func testRepeatedRestartsBumpGeneration() {
        var session = ListeningSession()
        session.start(at: 0)
        XCTAssertTrue(session.restartIfDue(at: 50))
        XCTAssertTrue(session.restartIfDue(at: 100))
        XCTAssertEqual(session.state, .listening(generation: 2, requestStart: 100))
    }

    func testErrorReportsDeaf() {
        var session = ListeningSession()
        session.start(at: 100)
        session.noteError("recognizer unavailable")
        XCTAssertFalse(session.isLive, "never look active while deaf")
        XCTAssertEqual(session.state, .deaf(reason: "recognizer unavailable"))
        session.start(at: 200)
        XCTAssertTrue(session.isLive, "recovers on restart")
    }

    func testInterruptionReportsDeaf() {
        var session = ListeningSession()
        session.start(at: 100)
        session.noteInterruption()
        XCTAssertEqual(session.state, .deaf(reason: "Microphone interrupted"))
        XCTAssertFalse(session.isLive)
    }

    func testStopFromDeaf() {
        var session = ListeningSession()
        session.start(at: 100)
        session.noteError("boom")
        session.stop()
        XCTAssertEqual(session.state, .idle)
    }
}

final class PartialReplyGateTests: XCTestCase {
    func testPhraseActsOnceAcrossGrowingPartials() {
        var gate = PartialReplyGate()
        XCTAssertNil(gate.consume(nil))
        XCTAssertEqual(gate.consume(.unsafePhrase), .unsafePhrase)
        XCTAssertNil(gate.consume(.unsafePhrase))
    }

    func testFinalSeesWhatPartialsAlreadyHandled() {
        var gate = PartialReplyGate()
        _ = gate.consume(.safePhrase)
        XCTAssertEqual(gate.finishUtterance(), .safePhrase)
        XCTAssertEqual(gate.consume(.safePhrase), .safePhrase)
    }

    func testFinalWithoutPartialsHandlesNothingEarly() {
        var gate = PartialReplyGate()
        XCTAssertNil(gate.finishUtterance())
    }

    func testUnsafeAfterSafeInSameUtteranceStillActs() {
        var gate = PartialReplyGate()
        XCTAssertEqual(gate.consume(.safePhrase), .safePhrase)
        XCTAssertEqual(gate.consume(.unsafePhrase), .unsafePhrase)
    }
}
