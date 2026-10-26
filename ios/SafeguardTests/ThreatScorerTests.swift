import CoreGraphics
import XCTest

/// End-to-end behaviour scenarios through tracker + extractor + scorer on
/// synthetic 5 Hz ticks: following, fast approach and cornering must alert;
/// a normal crowd (and a passerby) must not.
final class ThreatScorerTests: XCTestCase {
    private func frontalPose() -> BodyPose {
        BodyPose(
            nose: .init(point: CGPoint(x: 0.5, y: 0.7), confidence: 0.95),
            leftEye: .init(point: CGPoint(x: 0.48, y: 0.72), confidence: 0.9),
            rightEye: .init(point: CGPoint(x: 0.52, y: 0.72), confidence: 0.9),
            leftShoulder: .init(point: CGPoint(x: 0.44, y: 0.55), confidence: 0.9),
            rightShoulder: .init(point: CGPoint(x: 0.56, y: 0.55), confidence: 0.9)
        )
    }

    private func profilePose() -> BodyPose {
        BodyPose(
            nose: .init(point: CGPoint(x: 0.5, y: 0.7), confidence: 0.2),
            leftEye: .init(point: CGPoint(x: 0.49, y: 0.72), confidence: 0.15),
            leftShoulder: .init(point: CGPoint(x: 0.495, y: 0.55), confidence: 0.7),
            rightShoulder: .init(point: CGPoint(x: 0.525, y: 0.55), confidence: 0.7)
        )
    }

    private func person(cx: Double, h: Double, pose: BodyPose?) -> DetectedPerson {
        DetectedPerson(
            box: CGRect(x: cx - 0.3 * h, y: 0.5 - h / 2, width: 0.6 * h, height: h),
            confidence: 0.9,
            pose: pose
        )
    }

    /// Drive ticks through a fresh pipeline; returns the final live scores.
    private func run(
        ticks: [(time: Double, people: [DetectedPerson])],
        config: ThreatConfig = ThreatConfig()
    ) -> [Int: ThreatScore] {
        let tracker = IoUTracker()
        let extractor = FeatureExtractor(config: config)
        let scorer = ThreatScorer(config: config)
        var live: [Track] = []
        var lastTime = 0.0
        for tick in ticks {
            live = tracker.update(detections: tick.people).filter { $0.missed == 0 }
            extractor.update(tracks: live, at: tick.time)
            lastTime = tick.time
        }
        var scores: [Int: ThreatScore] = [:]
        for track in live {
            if let features = extractor.features(for: track.id, at: lastTime) {
                scores[track.id] = scorer.score(features)
            }
        }
        return scores
    }

    func testFollowingAlerts() {
        var ticks: [(Double, [DetectedPerson])] = []
        for step in 0..<40 {
            let t = Double(step) * 0.2
            let x = 0.42 + 0.08 * (t / 8)
            let h = 0.20 + 0.14 * (t / 8)
            ticks.append((t, [person(cx: x, h: h, pose: frontalPose())]))
        }
        let scores = run(ticks: ticks)
        XCTAssertEqual(scores.count, 1)
        XCTAssertEqual(scores.values.first?.alert, true)
    }

    func testFastApproachAlerts() {
        var ticks: [(Double, [DetectedPerson])] = []
        for step in 0..<13 {
            let t = Double(step) * 0.2
            let h = 0.15 + 0.35 * (t / 2.4)
            ticks.append((t, [person(cx: 0.5, h: h, pose: frontalPose())]))
        }
        let scores = run(ticks: ticks)
        XCTAssertEqual(scores.values.first?.alert, true)
    }

    func testCorneringAlerts() {
        var ticks: [(Double, [DetectedPerson])] = []
        for step in 0..<25 {
            let t = Double(step) * 0.2
            let h = 0.22 + 0.18 * (t / 4.8)
            ticks.append((t, [person(cx: 0.5, h: h, pose: frontalPose())]))
        }
        let scores = run(ticks: ticks)
        XCTAssertEqual(scores.values.first?.alert, true)
    }

    func testCrowdDoesNotAlert() {
        var ticks: [(Double, [DetectedPerson])] = []
        for step in 0..<40 {
            let t = Double(step) * 0.2
            var people: [DetectedPerson] = []
            for index in 0..<5 {
                let base = 0.1 + 0.18 * Double(index)
                let x = base + 0.05 * sin(t * 0.8 + Double(index))
                let pose = index % 2 == 0 ? frontalPose() : profilePose()
                people.append(person(cx: x, h: 0.24, pose: pose))
            }
            ticks.append((t, people))
        }
        let scores = run(ticks: ticks)
        XCTAssertEqual(scores.count, 5)
        for score in scores.values {
            XCTAssertEqual(score.alert, false)
        }
    }

    func testPasserbyDoesNotAlert() {
        var ticks: [(Double, [DetectedPerson])] = []
        for step in 0..<15 {
            let t = Double(step) * 0.2
            let x = 0.05 + 0.90 * (t / 2.8)
            ticks.append((t, [person(cx: x, h: 0.3, pose: profilePose())]))
        }
        let scores = run(ticks: ticks)
        XCTAssertEqual(scores.values.first?.alert, false)
    }

    func testReasonsNameFiringFeatures() {
        var ticks: [(Double, [DetectedPerson])] = []
        for step in 0..<40 {
            let t = Double(step) * 0.2
            let x = 0.42 + 0.08 * (t / 8)
            let h = 0.20 + 0.14 * (t / 8)
            ticks.append((t, [person(cx: x, h: h, pose: frontalPose())]))
        }
        let reasons = run(ticks: ticks).values.first?.reasons ?? []
        XCTAssertTrue(reasons.contains("persistent"))
        XCTAssertTrue(reasons.contains("facing you"))
    }

    // MARK: - Guards found by probing real-world cases

    func testStationaryFacingPersonDoesNotAlert() {
        // A stranger standing still in front of you, alone, facing you, for 8 s,
        // with ordinary box jitter. Presence-only features used to score
        // 0.49-0.50 against the 0.50 threshold. It must now clear by a margin.
        let config = ThreatConfig()
        var ticks: [(Double, [DetectedPerson])] = []
        for step in 0..<40 {
            let t = Double(step) * 0.2
            let h = 0.35 + 0.004 * sin(t * 7)
            ticks.append((t, [person(cx: 0.5 + 0.003 * cos(t * 5), h: h, pose: frontalPose())]))
        }
        let score = run(ticks: ticks).values.first
        XCTAssertEqual(score?.alert, false)
        XCTAssertLessThanOrEqual(score?.value ?? 1, config.alertThreshold - 0.10)
    }

    func testNewPersonAppearingDoesNotAlertDuringFirstSecond() {
        // Probe case: someone steps into the middle of view. Every prefix up
        // to the minimum history must stay quiet.
        let config = ThreatConfig()
        for count in 2...5 {
            var ticks: [(Double, [DetectedPerson])] = []
            for step in 0..<count {
                let t = Double(step) * 0.2
                ticks.append((t, [person(cx: 0.5, h: 0.30 + 0.015 * Double(step), pose: frontalPose())]))
            }
            let score = run(ticks: ticks).values.first
            XCTAssertEqual(score?.alert, false, "alerted with \(count) samples")
            XCTAssertLessThanOrEqual(score?.value ?? 1, config.staticScoreCap)
        }
    }

    func testStaticCapAppliesOnlyWithoutClosingInOrReappearing() {
        let config = ThreatConfig()
        let scorer = ThreatScorer(config: config)
        let presenceOnly = PersonFeatures(
            persistence: 1, facing: 1, isolation: 1, blocking: 1
        )
        XCTAssertLessThanOrEqual(scorer.score(presenceOnly).value, config.staticScoreCap)
        XCTAssertFalse(scorer.score(presenceOnly).alert)

        // Same features plus reappearing: the cap no longer applies.
        var reappeared = presenceOnly
        reappeared.reappearing = true
        XCTAssertGreaterThan(scorer.score(reappeared).value, config.staticScoreCap)

        // Same features plus a real closing-in signal: not capped, and it alerts.
        var closing = presenceOnly
        closing.trend = 0.4
        closing.speed = 0.4
        XCTAssertGreaterThan(scorer.score(closing).value, config.staticScoreCap)
        XCTAssertTrue(scorer.score(closing).alert)
    }

    func testCapKeepsSafetyMarginBelowThreshold() {
        let config = ThreatConfig()
        XCTAssertLessThanOrEqual(config.staticScoreCap, config.alertThreshold - 0.10)
        XCTAssertGreaterThan(config.motionMin, 0)
        XCTAssertGreaterThanOrEqual(config.minTrendSamples, 2)
    }

    // MARK: - Speech signal (additive; silent speech changes nothing)

    func testSilentSpeechLeavesValueIdentical() {
        let scorer = ThreatScorer()
        let base = scorer.score(PersonFeatures(trend: 0.8, persistence: 0.7))
        let silent = scorer.score(PersonFeatures(trend: 0.8, persistence: 0.7, speech: 0))
        XCTAssertEqual(base.value, silent.value)
        XCTAssertEqual(base.reasons, silent.reasons)
        XCTAssertFalse(silent.reasons.contains("threatening speech"))
    }

    func testSpeechAddsBonus() {
        let config = ThreatConfig()
        let scorer = ThreatScorer(config: config)
        let scored = scorer.score(PersonFeatures(speech: 1.0))
        XCTAssertEqual(scored.value, config.weightSpeech, accuracy: 1e-9)
        XCTAssertEqual(scored.reasons, ["threatening speech"])
        XCTAssertFalse(scored.alert, "speech alone (0.30) must not alert")
    }

    func testSpeechPushesMovementOverThreshold() {
        // Trend 1.0 scores 0.20 alone; full speech adds 0.30 -> 0.50 alert.
        let scored = ThreatScorer().score(PersonFeatures(trend: 1.0, speech: 1.0))
        XCTAssertEqual(scored.value, 0.5, accuracy: 1e-9)
        XCTAssertTrue(scored.alert)
    }

    func testStrongSpeechBypassesStaticCap() {
        let config = ThreatConfig()
        let scorer = ThreatScorer(config: config)
        let presenceOnly = PersonFeatures(
            persistence: 1, facing: 1, isolation: 1, blocking: 1
        )
        XCTAssertLessThanOrEqual(scorer.score(presenceOnly).value, config.staticScoreCap)
        var withSpeech = presenceOnly
        withSpeech.speech = 0.6
        let scored = scorer.score(withSpeech)
        XCTAssertGreaterThan(scored.value, config.staticScoreCap)
        XCTAssertTrue(scored.alert)
        XCTAssertTrue(scored.reasons.contains("threatening speech"))
    }

    func testWeakSpeechEarnsNoReason() {
        let scored = ThreatScorer().score(PersonFeatures(speech: 0.3))
        XCTAssertFalse(scored.reasons.contains("threatening speech"))
        XCTAssertEqual(scored.value, 0.3 * ThreatConfig().weightSpeech, accuracy: 1e-9)
    }

    func testConfigIsSane() {
        let config = ThreatConfig()
        let weights = [
            config.weightTrend, config.weightSpeed, config.weightPersistence,
            config.weightFacing, config.weightIsolation, config.weightBlocking,
            config.weightCornering,
        ]
        XCTAssertGreaterThan(weights.reduce(0, +), 0)
        XCTAssertGreaterThan(config.alertThreshold, 0)
        XCTAssertLessThan(config.alertThreshold, 1)
        XCTAssertGreaterThan(config.featureWindow, 0)
        XCTAssertGreaterThan(config.approachWindow, 0)
        XCTAssertGreaterThan(config.persistenceWindow, 0)
        XCTAssertGreaterThan(config.corridorWindow, 0)
    }
}
