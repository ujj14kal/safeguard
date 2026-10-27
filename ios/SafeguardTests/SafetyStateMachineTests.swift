import XCTest

/// Safety state machine: every transition, the 10 s no-reply clock, the
/// cooldown, the always-on unsafe phrase, Muse-low cancellation, failed
/// verify never suppressing, and speech never going straight to Unsafe.
/// Pure timestamps throughout: no waiting, no audio, no network.
final class SafetyStateMachineTests: XCTestCase {
    private func protecting(at time: TimeInterval = 100) -> SafetyStateMachine {
        var machine = SafetyStateMachine()
        machine.startProtecting(at: time)
        return machine
    }

    // MARK: - Session

    func testStartsIdle() {
        XCTAssertEqual(SafetyStateMachine().state, .idle)
    }

    func testStartStop() {
        var machine = protecting()
        XCTAssertEqual(machine.state, .monitoring)
        machine.stopProtecting()
        XCTAssertEqual(machine.state, .idle)
    }

    func testStopClearsUnsafe() {
        var machine = protecting()
        machine.noteReply(.unsafePhrase, at: 101)
        XCTAssertEqual(machine.state, .unsafe)
        machine.stopProtecting()
        XCTAssertEqual(machine.state, .idle)
        XCTAssertNil(machine.unsafeCause)
    }

    func testInputsIgnoredWhileIdle() {
        var machine = SafetyStateMachine()
        machine.noteMovementAlert(score: 0.9, at: 1)
        machine.noteMuseVerdict(.high, at: 1)
        machine.noteSpeech(severity: 1, at: 1)
        machine.noteReply(.unsafePhrase, at: 1)
        machine.tick(at: 1000)
        XCTAssertEqual(machine.state, .idle)
    }

    // MARK: - Movement path

    func testMovementAlertEntersListeningFirst() {
        var machine = protecting()
        machine.noteMovementAlert(score: 0.6, at: 100)
        XCTAssertEqual(machine.state, .listening)
        XCTAssertEqual(machine.suspicionSources, [.movement])
        XCTAssertFalse(machine.takeAskSpeechDue(), "silent during the window")
    }

    func testListeningWindowEndsInAsking() {
        var machine = protecting()
        machine.noteMovementAlert(score: 0.6, at: 100)
        machine.tick(at: 100 + 6)
        XCTAssertEqual(machine.state, .asking)
        XCTAssertTrue(machine.takeAskSpeechDue())
        XCTAssertFalse(machine.takeAskSpeechDue(), "one TTS call per Asking entry")
    }

    func testHighScoreSkipsWindow() {
        var machine = protecting()
        machine.noteMovementAlert(score: 0.85, at: 100)
        XCTAssertEqual(machine.state, .asking)
        XCTAssertTrue(machine.takeAskSpeechDue())
    }

    // MARK: - 10 s no-reply clock

    func testNoReplyBecomesUnsafe() {
        var machine = protecting()
        machine.noteMovementAlert(score: 0.85, at: 100)
        machine.noteAskSpeechStarted(at: 102)
        machine.tick(at: 111.9)
        XCTAssertEqual(machine.state, .asking)
        machine.tick(at: 112)
        XCTAssertEqual(machine.state, .unsafe)
        XCTAssertEqual(machine.unsafeCause, .noReply)
    }

    func testClockStartsWithSpeechNotWithAsking() {
        var machine = protecting()
        machine.noteMovementAlert(score: 0.85, at: 100)
        // TTS lags 30 s (slow device): no deadline until audio starts.
        machine.tick(at: 130)
        XCTAssertEqual(machine.state, .asking)
        machine.noteAskSpeechStarted(at: 130)
        machine.tick(at: 139.9)
        XCTAssertEqual(machine.state, .asking)
        machine.tick(at: 140)
        XCTAssertEqual(machine.state, .unsafe)
    }

    func testSafeReplyBeforeDeadline() {
        var machine = protecting()
        machine.noteMovementAlert(score: 0.85, at: 100)
        machine.noteAskSpeechStarted(at: 100)
        machine.noteReply(.safePhrase, at: 105)
        XCTAssertEqual(machine.state, .safe)
        machine.tick(at: 1000)
        XCTAssertEqual(machine.state, .monitoring, "cooldown expires back to Monitoring")
    }

    func testTapIsNonVerbalOKWhenAsking() {
        var machine = protecting()
        machine.noteMovementAlert(score: 0.85, at: 100)
        machine.noteReply(.tap, at: 101)
        XCTAssertEqual(machine.state, .safe)
    }

    func testTapEndsWindowEarlyButStillAsks() {
        var machine = protecting()
        machine.noteMovementAlert(score: 0.6, at: 100)
        machine.noteReply(.tap, at: 101)
        XCTAssertEqual(machine.state, .asking)
        XCTAssertTrue(machine.takeAskSpeechDue())
    }

    // MARK: - Cooldown

    func testCooldownSuppressesNagging() {
        var machine = protecting()
        machine.noteMovementAlert(score: 0.85, at: 100)
        machine.noteReply(.safePhrase, at: 101) // safe until 161
        machine.noteMovementAlert(score: 0.9, at: 110)
        machine.noteMuseVerdict(.medium, at: 110)
        machine.noteSpeech(severity: 1, at: 110)
        XCTAssertEqual(machine.state, .safe)
    }

    func testMuseHighBreaksCooldown() {
        var machine = protecting()
        machine.noteMovementAlert(score: 0.85, at: 100)
        machine.noteReply(.safePhrase, at: 101)
        machine.noteMuseVerdict(.high, at: 110)
        XCTAssertEqual(machine.state, .asking)
    }

    // MARK: - Unsafe phrase, always on

    func testUnsafePhraseStraightToUnsafe() {
        // From Monitoring (no incident at all).
        var machine = protecting()
        machine.noteReply(.unsafePhrase, at: 101)
        XCTAssertEqual(machine.state, .unsafe)
        XCTAssertEqual(machine.unsafeCause, .unsafePhrase)
        // From Listening.
        machine = protecting()
        machine.noteMovementAlert(score: 0.6, at: 100)
        machine.noteReply(.unsafePhrase, at: 101)
        XCTAssertEqual(machine.state, .unsafe)
        // From Asking.
        machine = protecting()
        machine.noteMovementAlert(score: 0.85, at: 100)
        machine.noteReply(.unsafePhrase, at: 101)
        XCTAssertEqual(machine.state, .unsafe)
        // From Safe (cooldown does not block it).
        machine = protecting()
        machine.noteMovementAlert(score: 0.85, at: 100)
        machine.noteReply(.safePhrase, at: 101)
        machine.noteReply(.unsafePhrase, at: 102)
        XCTAssertEqual(machine.state, .unsafe)
    }

    func testSafePhraseOnlyCountsWhenAsking() {
        var machine = protecting()
        machine.noteReply(.safePhrase, at: 101)
        XCTAssertEqual(machine.state, .monitoring)
        machine.noteMovementAlert(score: 0.6, at: 102)
        machine.noteReply(.safePhrase, at: 103)
        XCTAssertEqual(machine.state, .listening, "window still runs; question still asked")
    }

    // MARK: - Muse verdicts

    func testMuseLowCancelsMovementOnlySuspicion() {
        // The known false alert: walking up to someone standing still
        // scores ~0.74 on-device, but Muse says low.
        var machine = protecting()
        machine.noteMovementAlert(score: 0.74, at: 100)
        XCTAssertEqual(machine.state, .listening)
        machine.noteMuseVerdict(.low, at: 101)
        XCTAssertEqual(machine.state, .monitoring)
        XCTAssertTrue(machine.suspicionSources.isEmpty)
    }

    func testMuseLowKeepsSpeechBackedSuspicion() {
        var machine = protecting()
        machine.noteMovementAlert(score: 0.6, at: 100)
        machine.noteSpeech(severity: 0.9, at: 101)
        machine.noteMuseVerdict(.low, at: 102)
        XCTAssertEqual(machine.state, .listening)
    }

    func testMuseLowKeepsMuseBackedSuspicion() {
        var machine = protecting()
        machine.noteMuseVerdict(.medium, at: 100)
        machine.noteMuseVerdict(.low, at: 101)
        XCTAssertEqual(machine.state, .listening)
    }

    func testMuseLowDoesNotYankQuestion() {
        var machine = protecting()
        machine.noteMovementAlert(score: 0.85, at: 100)
        machine.noteMuseVerdict(.low, at: 101)
        XCTAssertEqual(machine.state, .asking, "finish the check-in once asked")
    }

    func testMuseMediumTriggersCheckIn() {
        var machine = protecting()
        machine.noteMuseVerdict(.medium, at: 100)
        XCTAssertEqual(machine.state, .listening)
        XCTAssertEqual(machine.suspicionSources, [.muse])
    }

    func testMuseHighSkipsWindow() {
        var machine = protecting()
        machine.noteMuseVerdict(.high, at: 100)
        XCTAssertEqual(machine.state, .asking)
    }

    func testMuseHighDuringWindowJumpsToAsking() {
        var machine = protecting()
        machine.noteMovementAlert(score: 0.6, at: 100)
        machine.noteMuseVerdict(.high, at: 101)
        XCTAssertEqual(machine.state, .asking)
    }

    // MARK: - Failed verify never suppresses

    func testMissingVerdictKeepsOnDeviceSuspicion() {
        // Backend down / 503 / timeout / rate limit: no verdict ever
        // arrives. The on-device suspicion must still run its course.
        var machine = protecting()
        machine.noteMovementAlert(score: 0.6, at: 100)
        machine.tick(at: 106)
        XCTAssertEqual(machine.state, .asking)
        machine.noteAskSpeechStarted(at: 106)
        machine.tick(at: 116)
        XCTAssertEqual(machine.state, .unsafe)
        XCTAssertEqual(machine.unsafeCause, .noReply)
    }

    // MARK: - Speech input

    func testSpeechTriggersAskingButNeverUnsafe() {
        var machine = protecting()
        machine.noteSpeech(severity: 1.0, at: 100)
        XCTAssertEqual(machine.state, .listening)
        XCTAssertEqual(machine.suspicionSources, [.speech])
        machine.tick(at: 106)
        XCTAssertEqual(machine.state, .asking, "speech leads to a question, not SOS")
    }

    func testWeakSpeechIgnored() {
        var machine = protecting()
        machine.noteSpeech(severity: 0.3, at: 100)
        XCTAssertEqual(machine.state, .monitoring)
    }

    // MARK: - Listening window (Part C)

    func testWindowSilentUntilItEnds() {
        var machine = protecting()
        machine.noteMovementAlert(score: 0.6, at: 100)
        machine.tick(at: 105.9)
        XCTAssertEqual(machine.state, .listening)
        XCTAssertFalse(machine.takeAskSpeechDue(), "no TTS call during the window")
        machine.tick(at: 106)
        XCTAssertEqual(machine.state, .asking)
        XCTAssertTrue(machine.takeAskSpeechDue())
    }

    func testWindowLastsConfiguredTime() {
        var config = SafetyConfig()
        config.listeningWindowSeconds = 10
        var machine = SafetyStateMachine(config: config)
        machine.startProtecting(at: 100)
        machine.noteMovementAlert(score: 0.6, at: 100)
        machine.tick(at: 109.9)
        XCTAssertEqual(machine.state, .listening)
        machine.tick(at: 110)
        XCTAssertEqual(machine.state, .asking)
    }

    func testSkipScoreBoundary() {
        XCTAssertEqual(SafetyConfig().listeningSkipScore, 0.80)
        var machine = protecting()
        machine.noteMovementAlert(score: 0.79, at: 100)
        XCTAssertEqual(machine.state, .listening)
        machine = protecting()
        machine.noteMovementAlert(score: 0.80, at: 100)
        XCTAssertEqual(machine.state, .asking)
    }

    func testWindowDoesNotStartAskClock() {
        var machine = protecting()
        machine.noteMovementAlert(score: 0.6, at: 100)
        machine.tick(at: 106) // window ends, asking begins
        // TTS hasn't started: even far past window + 10 s, no timeout.
        machine.tick(at: 120)
        XCTAssertEqual(machine.state, .asking)
        machine.noteAskSpeechStarted(at: 120)
        machine.tick(at: 129.9)
        XCTAssertEqual(machine.state, .asking)
        machine.tick(at: 130)
        XCTAssertEqual(machine.state, .unsafe)
    }

    func testWindowRespectsCooldown() {
        var machine = protecting()
        machine.noteMovementAlert(score: 0.6, at: 100)
        machine.tick(at: 106)
        machine.noteReply(.safePhrase, at: 107) // safe until 167
        machine.noteMovementAlert(score: 0.9, at: 110)
        XCTAssertEqual(machine.state, .safe, "no window during cooldown")
        machine.tick(at: 167)
        XCTAssertEqual(machine.state, .monitoring)
        machine.noteMovementAlert(score: 0.6, at: 168)
        XCTAssertEqual(machine.state, .listening, "window works after cooldown")
    }

    func testSpeechSuspicionAlsoWaitsWindow() {
        var machine = protecting()
        machine.noteSpeech(severity: 0.9, at: 100)
        XCTAssertEqual(machine.state, .listening)
        machine.tick(at: 105.9)
        XCTAssertEqual(machine.state, .listening)
        machine.tick(at: 106)
        XCTAssertEqual(machine.state, .asking)
    }

    // MARK: - Code phrases

    func testCodePhraseExact() {
        let matcher = CodePhraseMatcher()
        XCTAssertEqual(matcher.match("open calculator"), .safePhrase)
        XCTAssertEqual(matcher.match("open app store"), .unsafePhrase)
    }

    func testCodePhraseCloseVariants() {
        let matcher = CodePhraseMatcher()
        XCTAssertEqual(matcher.match("Please, open calculator now!"), .safePhrase)
        XCTAssertEqual(matcher.match("OPEN APP STORE"), .unsafePhrase)
        XCTAssertEqual(matcher.match("hmm... open, calculator?"), .safePhrase)
    }

    func testCodePhraseWordBoundaries() {
        let matcher = CodePhraseMatcher()
        XCTAssertNil(matcher.match("open calculators"))
        XCTAssertNil(matcher.match("reopen calculator app"))
        XCTAssertNil(matcher.match("the app store is open"))
        XCTAssertNil(matcher.match("open the app"))
    }

    func testCodePhraseUnsafeWins() {
        let matcher = CodePhraseMatcher()
        XCTAssertEqual(
            matcher.match("open calculator no wait open app store"), .unsafePhrase
        )
    }

    func testCodePhraseConfigurable() {
        var config = SafetyConfig()
        config.safePhrases = ["all good"]
        config.unsafePhrases = ["red alert"]
        let matcher = CodePhraseMatcher(config: config)
        XCTAssertEqual(matcher.match("we are all good here"), .safePhrase)
        XCTAssertEqual(matcher.match("red alert red alert"), .unsafePhrase)
        XCTAssertNil(matcher.match("open calculator"))
    }
}

/// Distress words: bachao / help start a 5 s countdown to auto-SOS.
final class AutoSOSCountdownTests: XCTestCase {
    private func protecting() -> SafetyStateMachine {
        var m = SafetyStateMachine()
        m.startProtecting(at: 0)
        return m
    }

    func testDistressWordStartsCountdownFromMonitoring() {
        var m = protecting()
        m.noteDistressWord(at: 10)
        XCTAssertEqual(m.state, .countdown)
        XCTAssertEqual(m.countdownRemaining(at: 12) ?? 0, 3, accuracy: 0.001)
    }

    func testCountdownEndsInUnsafeWithDistressCause() {
        var m = protecting()
        m.noteDistressWord(at: 10)
        m.tick(at: 14.9)
        XCTAssertEqual(m.state, .countdown)
        m.tick(at: 15.0)
        XCTAssertEqual(m.state, .unsafe)
        XCTAssertEqual(m.unsafeCause, .distressWord)
    }

    func testSafePhraseDoubleTapAndButtonCancel() {
        for cancel in [
            { (m: inout SafetyStateMachine) in m.noteReply(.safePhrase, at: 12) },
            { (m: inout SafetyStateMachine) in m.noteReply(.tap, at: 12) },
            { (m: inout SafetyStateMachine) in m.cancelCountdown(at: 12) },
        ] {
            var m = protecting()
            m.noteDistressWord(at: 10)
            cancel(&m)
            XCTAssertEqual(m.state, .monitoring)
            m.tick(at: 30)
            XCTAssertEqual(m.state, .monitoring, "a cancelled countdown must never fire")
        }
    }

    func testUnsafePhraseSkipsTheCountdown() {
        var m = protecting()
        m.noteDistressWord(at: 10)
        m.noteReply(.unsafePhrase, at: 11)
        XCTAssertEqual(m.state, .unsafe)
        XCTAssertEqual(m.unsafeCause, .unsafePhrase)
    }

    func testSameWordsAreIgnoredRightAfterACancel() {
        var m = protecting()
        m.noteDistressWord(at: 10)
        m.cancelCountdown(at: 11)
        m.noteDistressWord(at: 15)
        XCTAssertEqual(m.state, .monitoring, "10 s cool-down after a cancel")
        m.noteDistressWord(at: 22)
        XCTAssertEqual(m.state, .countdown)
    }

    func testDistressOverridesAskingAndSafeCooldown() {
        var asking = protecting()
        asking.noteMovementAlert(score: 0.9, at: 1)
        XCTAssertEqual(asking.state, .asking)
        asking.noteDistressWord(at: 2)
        XCTAssertEqual(asking.state, .countdown)
        XCTAssertFalse(asking.takeAskSpeechDue(), "no spoken question over a countdown")

        var safe = protecting()
        safe.noteMovementAlert(score: 0.9, at: 1)
        safe.noteReply(.safePhrase, at: 2)
        XCTAssertEqual(safe.state, .safe)
        safe.noteDistressWord(at: 3)
        XCTAssertEqual(safe.state, .countdown)
    }

    func testOtherSignalsDoNotDisturbTheCountdown() {
        var m = protecting()
        m.noteDistressWord(at: 10)
        m.noteMovementAlert(score: 0.95, at: 11)
        m.noteMuseVerdict(.low, at: 11)
        m.noteSpeech(severity: 0.9, at: 11)
        XCTAssertEqual(m.state, .countdown)
    }

    func testIdleIgnoresDistressUntilProtecting() {
        var m = SafetyStateMachine()
        m.noteDistressWord(at: 1)
        XCTAssertEqual(m.state, .idle)
    }

    func testDistressMatcherEnglishHindiAndSpelling() {
        let matcher = DistressMatcher()
        for text in ["bachao", "bachaao bachaao", "help", "please help me", "बचाओ", "मदद करो", "madad karo koi", "SAVE ME"] {
            XCTAssertTrue(matcher.matches(text), text)
        }
        for text in ["hello there", "the helpful assistant", "chalo chai peete hain", "mujhe kuch nahi chahiye", "bachpan ki yaad"] {
            XCTAssertFalse(matcher.matches(text), text)
        }
    }
}
