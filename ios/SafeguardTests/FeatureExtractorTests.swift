import CoreGraphics
import XCTest

final class FeatureExtractorTests: XCTestCase {
    private func box(cx: Double, cy: Double = 0.5, w: Double = 0.15, h: Double) -> CGRect {
        CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    private func frontalPose(spread: Double = 0.12) -> BodyPose {
        BodyPose(
            nose: .init(point: CGPoint(x: 0.5, y: 0.7), confidence: 0.95),
            leftEye: .init(point: CGPoint(x: 0.48, y: 0.72), confidence: 0.9),
            rightEye: .init(point: CGPoint(x: 0.52, y: 0.72), confidence: 0.9),
            leftShoulder: .init(point: CGPoint(x: 0.5 - spread / 2, y: 0.55), confidence: 0.9),
            rightShoulder: .init(point: CGPoint(x: 0.5 + spread / 2, y: 0.55), confidence: 0.9)
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

    @discardableResult
    private func feed(
        _ extractor: FeatureExtractor,
        id: Int,
        samples: [(t: Double, box: CGRect)],
        pose: BodyPose? = nil,
        others: Int = 0
    ) -> PersonFeatures? {
        var lastT = 0.0
        for sample in samples {
            var tracks = [Track(
                id: id, box: sample.box, confidence: 0.9, age: 1, missed: 0, pose: pose
            )]
            for other in 0..<others {
                tracks.append(Track(
                    id: 1000 + other,
                    box: CGRect(x: 0.02 * Double(other), y: 0.05, width: 0.08, height: 0.15),
                    confidence: 0.8, age: 1, missed: 0
                ))
            }
            extractor.update(tracks: tracks, at: sample.t)
            lastT = sample.t
        }
        return extractor.features(for: id, at: lastT)
    }

    private func ramp(from start: Double, to end: Double, over seconds: Double) -> [(Double, CGRect)] {
        let count = Int(seconds / 0.2) + 1
        return (0..<count).map { step in
            let t = Double(step) * 0.2
            let h = start + (end - start) * (t / seconds)
            return (t, box(cx: 0.5, h: h))
        }
    }

    func testTrendGrowing() {
        let extractor = FeatureExtractor()
        let features = feed(extractor, id: 1, samples: ramp(from: 0.20, to: 0.38, over: 3))
        XCTAssertGreaterThan(features?.trend ?? 0, 0.9)
    }

    func testTrendStatic() {
        let extractor = FeatureExtractor()
        let samples = (0..<16).map { (Double($0) * 0.2, box(cx: 0.5, h: 0.25)) }
        let features = feed(extractor, id: 1, samples: samples)
        XCTAssertLessThan(features?.trend ?? 1, 0.05)
    }

    func testTrendReceding() {
        let extractor = FeatureExtractor()
        let features = feed(extractor, id: 1, samples: ramp(from: 0.40, to: 0.25, over: 3))
        XCTAssertEqual(features?.trend ?? -1, 0)
    }

    func testSpeedFast() {
        let extractor = FeatureExtractor()
        let features = feed(extractor, id: 1, samples: ramp(from: 0.15, to: 0.51, over: 3))
        XCTAssertGreaterThan(features?.speed ?? 0, 0.9)
    }

    func testSpeedSlow() {
        let extractor = FeatureExtractor()
        let features = feed(extractor, id: 1, samples: ramp(from: 0.20, to: 0.23, over: 3))
        XCTAssertLessThan(features?.speed ?? 1, 0.2)
    }

    func testPersistenceFull() {
        let extractor = FeatureExtractor()
        let samples = (0..<30).map { (Double($0) * 0.2, box(cx: 0.5, h: 0.25)) }
        let features = feed(extractor, id: 1, samples: samples)
        XCTAssertEqual(features?.persistence ?? 0, 1.0, accuracy: 1e-9)
    }

    func testPersistenceShort() {
        let extractor = FeatureExtractor()
        let samples = (0..<5).map { (Double($0) * 0.2, box(cx: 0.5, h: 0.25)) }
        let features = feed(extractor, id: 1, samples: samples)
        XCTAssertLessThan(features?.persistence ?? 1, 0.3)
    }

    func testReappearing() {
        let extractor = FeatureExtractor()
        var samples = (0..<11).map { (Double($0) * 0.2, box(cx: 0.5, h: 0.25)) }
        samples += (0..<11).map { (4.0 + Double($0) * 0.2, box(cx: 0.5, h: 0.25)) }
        let features = feed(extractor, id: 1, samples: samples)
        XCTAssertEqual(features?.reappearing, true)
        XCTAssertGreaterThan(features?.persistence ?? 0, 0.9)
    }

    func testContinuousNotReappearing() {
        let extractor = FeatureExtractor()
        let samples = (0..<30).map { (Double($0) * 0.2, box(cx: 0.5, h: 0.25)) }
        let features = feed(extractor, id: 1, samples: samples)
        XCTAssertEqual(features?.reappearing, false)
    }

    func testFacingFrontal() {
        let extractor = FeatureExtractor()
        let samples = (0..<5).map { (Double($0) * 0.2, box(cx: 0.5, h: 0.25)) }
        let features = feed(extractor, id: 1, samples: samples, pose: frontalPose())
        XCTAssertGreaterThan(features?.facing ?? 0, 0.8)
    }

    func testFacingProfile() {
        let extractor = FeatureExtractor()
        let samples = (0..<5).map { (Double($0) * 0.2, box(cx: 0.5, h: 0.25)) }
        let features = feed(extractor, id: 1, samples: samples, pose: profilePose())
        XCTAssertLessThan(features?.facing ?? 1, 0.2)
    }

    func testFacingUnknownWhenNoPose() {
        let extractor = FeatureExtractor()
        let samples = (0..<5).map { (Double($0) * 0.2, box(cx: 0.5, h: 0.25)) }
        let features = feed(extractor, id: 1, samples: samples)
        XCTAssertEqual(features?.facing ?? -1, 0)
    }

    func testFacingBackOfHead() {
        let pose = BodyPose(
            leftShoulder: .init(point: CGPoint(x: 0.44, y: 0.55), confidence: 0.9),
            rightShoulder: .init(point: CGPoint(x: 0.56, y: 0.55), confidence: 0.9)
        )
        XCTAssertEqual(pose.facingScore(using: ThreatConfig()), 0)
    }

    func testIsolationAlone() {
        let extractor = FeatureExtractor()
        let samples = (0..<5).map { (Double($0) * 0.2, box(cx: 0.5, h: 0.25)) }
        let features = feed(extractor, id: 1, samples: samples)
        XCTAssertEqual(features?.isolation ?? -1, 1)
    }

    func testIsolationCrowd() {
        let extractor = FeatureExtractor()
        let samples = (0..<5).map { (Double($0) * 0.2, box(cx: 0.5, h: 0.25)) }
        let features = feed(extractor, id: 1, samples: samples, others: 4)
        XCTAssertEqual(features?.isolation ?? -1, 0)
    }

    func testIsolationPair() {
        let extractor = FeatureExtractor()
        let samples = (0..<5).map { (Double($0) * 0.2, box(cx: 0.5, h: 0.25)) }
        let features = feed(extractor, id: 1, samples: samples, others: 1)
        XCTAssertEqual(features?.isolation ?? -1, 0.75, accuracy: 1e-9)
    }

    func testBlockingInCorridor() {
        let extractor = FeatureExtractor()
        let samples = (0..<20).map { (Double($0) * 0.2, box(cx: 0.5, h: 0.3)) }
        let features = feed(extractor, id: 1, samples: samples)
        XCTAssertEqual(features?.blocking ?? -1, 1)
    }

    func testBlockingOutsideCorridor() {
        let extractor = FeatureExtractor()
        let samples = (0..<20).map { (Double($0) * 0.2, box(cx: 0.1, h: 0.3)) }
        let features = feed(extractor, id: 1, samples: samples)
        XCTAssertEqual(features?.blocking ?? -1, 0)
    }

    func testBlockingFarDoesNotCount() {
        let extractor = FeatureExtractor()
        let samples = (0..<20).map { (Double($0) * 0.2, box(cx: 0.5, h: 0.1)) }
        let features = feed(extractor, id: 1, samples: samples)
        XCTAssertEqual(features?.blocking ?? -1, 0)
    }

    func testCorneringIntercept() {
        let extractor = FeatureExtractor()
        let features = feed(extractor, id: 1, samples: ramp(from: 0.22, to: 0.40, over: 3))
        XCTAssertGreaterThan(features?.cornering ?? 0, 0.4)
    }

    func testCorneringCrossing() {
        let extractor = FeatureExtractor()
        let samples = (0..<16).map { step -> (Double, CGRect) in
            let t = Double(step) * 0.2
            let x = 0.3 + 0.4 * (t / 3)
            let h = 0.20 + 0.18 * (t / 3)
            return (t, box(cx: x, w: 0.15, h: h))
        }
        let features = feed(extractor, id: 1, samples: samples)
        XCTAssertEqual(features?.cornering ?? -1, 0)
    }

    func testNewTrackWithTwoSamplesHasNoTrendOrSpeed() {
        let extractor = FeatureExtractor()
        let features = feed(extractor, id: 1, samples: [
            (0.0, box(cx: 0.5, h: 0.30)), (0.2, box(cx: 0.5, h: 0.32)),
        ])
        XCTAssertEqual(features?.trend ?? -1, 0)
        XCTAssertEqual(features?.speed ?? -1, 0)
        XCTAssertEqual(features?.cornering ?? -1, 0)
    }

    func testTrendNeedsMinimumSamplesAndSpan() {
        let config = ThreatConfig()
        let tooShort = feed(
            FeatureExtractor(), id: 1, samples: ramp(from: 0.20, to: 0.30, over: 0.8)
        )
        XCTAssertLessThan(0.8, config.minTrendSpan)
        XCTAssertEqual(tooShort?.trend ?? -1, 0)
        let enough = feed(
            FeatureExtractor(), id: 1, samples: ramp(from: 0.20, to: 0.35, over: 1.0)
        )
        XCTAssertGreaterThan(enough?.trend ?? 0, 0.9)
        XCTAssertGreaterThan(enough?.speed ?? 0, 0.9)
    }

    func testPersistenceIsIndependentOfDetectionRate() {
        let slow = feed(
            FeatureExtractor(), id: 1,
            samples: (0..<10).map { (Double($0) * 0.4, box(cx: 0.5, h: 0.25)) }
        )
        let fast = feed(
            FeatureExtractor(), id: 1,
            samples: (0..<19).map { (Double($0) * 0.2, box(cx: 0.5, h: 0.25)) }
        )
        let config = ThreatConfig()
        let expected = (3.6 + config.detectionPeriod) / config.persistenceTime
        XCTAssertEqual(slow?.persistence ?? -1, expected, accuracy: 1e-9)
        XCTAssertEqual(fast?.persistence ?? -1, expected, accuracy: 1e-9)
    }

    func testLongGapIsNotCountedAsPresence() {
        let extractor = FeatureExtractor()
        var samples = (0..<6).map { (Double($0) * 0.2, box(cx: 0.5, h: 0.25)) }
        samples += (0..<6).map { (6.0 + Double($0) * 0.2, box(cx: 0.5, h: 0.25)) }
        let features = feed(extractor, id: 1, samples: samples)
        let config = ThreatConfig()
        let matched = (1.0 + 1.0 + config.detectionPeriod) / config.persistenceTime
        XCTAssertEqual(features?.reappearing, true)
        XCTAssertEqual(
            features?.persistence ?? -1, matched + config.reappearBonus, accuracy: 1e-9
        )
    }

    func testNoSamplesReturnsNil() {
        XCTAssertNil(FeatureExtractor().features(for: 999, at: 10))
    }

    func testResetClearsHistory() {
        let extractor = FeatureExtractor()
        feed(extractor, id: 1, samples: [(0, box(cx: 0.5, h: 0.25))])
        extractor.reset()
        XCTAssertNil(extractor.features(for: 1, at: 0))
    }

    func testSpeechStampsWhileFresh() {
        let extractor = FeatureExtractor()
        feed(extractor, id: 1, samples: [(0, box(cx: 0.5, h: 0.25))])
        extractor.setSpeech(severity: 0.9, at: 0)
        XCTAssertEqual(extractor.features(for: 1, at: 0)?.speech ?? -1, 0.9, accuracy: 1e-9)
        XCTAssertEqual(
            extractor.features(for: 1, at: 20)?.speech ?? -1, 0.9, accuracy: 1e-9
        )
    }

    func testSpeechExpiresAfterWindow() {
        let extractor = FeatureExtractor()
        feed(extractor, id: 1, samples: [(0, box(cx: 0.5, h: 0.25))])
        extractor.setSpeech(severity: 0.9, at: 0)
        XCTAssertEqual(extractor.features(for: 1, at: 20.1)?.speech ?? -1, 0)
    }

    func testSpeechClampedAndReset() {
        let extractor = FeatureExtractor()
        feed(extractor, id: 1, samples: [(0, box(cx: 0.5, h: 0.25))])
        extractor.setSpeech(severity: 9, at: 0)
        XCTAssertEqual(extractor.features(for: 1, at: 0)?.speech ?? -1, 1.0, accuracy: 1e-9)
        extractor.reset()
        feed(extractor, id: 1, samples: [(1, box(cx: 0.5, h: 0.25))])
        XCTAssertEqual(extractor.features(for: 1, at: 1)?.speech ?? -1, 0)
    }
}

final class GestureFeatureTests: XCTestCase {
    private let config = ThreatConfig()

    private func track(_ cues: GestureCues?, id: Int = 1) -> Track {
        Track(
            id: id, box: CGRect(x: 0.3, y: 0.2, width: 0.4, height: 0.5),
            confidence: 0.9, age: 10, missed: 0, cues: cues
        )
    }

    private func hand(height: Double) -> HandCue {
        HandCue(box: CGRect(x: 0.4, y: 0.3, width: height, height: height))
    }

    func testNoCuesLeavesFeaturesAtZero() {
        let extractor = FeatureExtractor(config: config)
        for i in 0..<10 { extractor.update(tracks: [track(nil)], at: Double(i) * 0.2) }
        let f = extractor.features(for: 1, at: 1.8)
        XCTAssertEqual(f?.handReach, 0)
        XCTAssertEqual(f?.shouting, 0)
    }

    func testSmallDistantHandIsNotReach() {
        let extractor = FeatureExtractor(config: config)
        for i in 0..<10 {
            extractor.update(tracks: [track(GestureCues(hands: [hand(height: 0.05)]))], at: Double(i) * 0.2)
        }
        XCTAssertEqual(extractor.features(for: 1, at: 1.8)?.handReach ?? 1, 0, accuracy: 0.001)
    }

    func testLargeHandCloseToCameraIsReach() {
        let extractor = FeatureExtractor(config: config)
        for i in 0..<10 {
            extractor.update(tracks: [track(GestureCues(hands: [hand(height: 0.30)]))], at: Double(i) * 0.2)
        }
        XCTAssertGreaterThanOrEqual(extractor.features(for: 1, at: 1.8)?.handReach ?? 0, 0.5)
    }

    func testGrowingHandScoresHigherThanSteadyHand() {
        let steady = FeatureExtractor(config: config)
        let lunge = FeatureExtractor(config: config)
        for i in 0..<10 {
            let t = Double(i) * 0.2
            steady.update(tracks: [track(GestureCues(hands: [hand(height: 0.25)]))], at: t)
            lunge.update(tracks: [track(GestureCues(hands: [hand(height: 0.10 + 0.04 * Double(i))]))], at: t)
        }
        XCTAssertGreaterThan(
            lunge.features(for: 1, at: 1.8)?.handReach ?? 0,
            steady.features(for: 1, at: 1.8)?.handReach ?? 1
        )
    }

    func testMouthWideOpenOverTimeIsShouting() {
        let extractor = FeatureExtractor(config: config)
        for i in 0..<10 {
            extractor.update(tracks: [track(GestureCues(mouthOpen: 0.7))], at: Double(i) * 0.2)
        }
        XCTAssertEqual(extractor.features(for: 1, at: 1.8)?.shouting ?? 0, 1, accuracy: 0.001)
    }

    func testOneMouthSampleIsNotShouting() {
        let extractor = FeatureExtractor(config: config)
        extractor.update(tracks: [track(GestureCues(mouthOpen: 0.9))], at: 0)
        XCTAssertEqual(extractor.features(for: 1, at: 0.1)?.shouting ?? 1, 0, accuracy: 0.001)
    }

    func testHandReachBypassesStaticCapAndAddsReason() {
        let scorer = ThreatScorer(config: config)
        var f = PersonFeatures(persistence: 1, facing: 1, isolation: 1, blocking: 1)
        let still = scorer.score(f)
        XCTAssertLessThanOrEqual(still.value, config.staticScoreCap + 0.0001)
        f.handReach = 0.9
        let reaching = scorer.score(f)
        XCTAssertGreaterThan(reaching.value, still.value)
        XCTAssertTrue(reaching.reasons.contains("hand reaching toward you"))
    }

    func testNearSweepFiresAfterNearHoldThenAtInterval() {
        var gate = NearSweepGate(config: config)
        XCTAssertFalse(gate.consume(isNear: true, at: 0))
        XCTAssertFalse(gate.consume(isNear: true, at: 2.9))
        XCTAssertTrue(gate.consume(isNear: true, at: 3.1))
        XCTAssertFalse(gate.consume(isNear: true, at: 10))
        XCTAssertTrue(gate.consume(isNear: true, at: 24))
    }

    func testNearSweepResetsWhenPersonLeaves() {
        var gate = NearSweepGate(config: config)
        _ = gate.consume(isNear: true, at: 0)
        XCTAssertFalse(gate.consume(isNear: false, at: 2))
        XCTAssertFalse(gate.consume(isNear: true, at: 3))
        XCTAssertFalse(gate.consume(isNear: true, at: 5))
        XCTAssertTrue(gate.consume(isNear: true, at: 6.5))
    }

    func testAlertClipSuppressesImmediateSweep() {
        var gate = NearSweepGate(config: config)
        gate.noteSent(at: 3)
        _ = gate.consume(isNear: true, at: 0)
        XCTAssertFalse(gate.consume(isNear: true, at: 4))
    }
}

final class ListeningRestartTests: XCTestCase {
    func testTaskEndBumpsGenerationAndRestarts() {
        var session = ListeningSession()
        session.start(at: 0)
        XCTAssertEqual(session.noteTaskEnded(at: 5), .restart)
        XCTAssertEqual(session.generation, 1)
        XCTAssertTrue(session.isLive)
    }

    func testRapidEndingsReportDeafInsteadOfSpinning() {
        var session = ListeningSession()
        session.start(at: 0)
        var last = ListeningSession.TaskEndDecision.restart
        for i in 0..<8 { last = session.noteTaskEnded(at: Double(i) * 0.5) }
        XCTAssertEqual(last, .deaf(reason: "Speech recognition keeps stopping"))
        XCTAssertFalse(session.isLive)
    }

    func testSlowEndingsNeverGoDeaf() {
        var session = ListeningSession()
        session.start(at: 0)
        for i in 0..<30 { XCTAssertEqual(session.noteTaskEnded(at: Double(i) * 3), .restart) }
        XCTAssertTrue(session.isLive)
    }
}
