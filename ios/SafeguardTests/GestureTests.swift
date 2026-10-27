import CoreGraphics
import XCTest

/// Hand gesture and expression classifiers on synthetic landmarks and
/// blendshapes (no camera, no model).
final class GestureTests: XCTestCase {
    private let box = CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1)

    /// 21 hand points: wrist at the origin, four fingers up the y axis.
    /// `extended` flags are thumb, index, middle, ring, pinky.
    private func hand(
        thumb: Bool = false, index: Bool = false, middle: Bool = false,
        ring: Bool = false, pinky: Bool = false, middleLength: CGFloat = 2.3
    ) -> [CGPoint] {
        var points = [CGPoint](repeating: .zero, count: 21)
        func finger(_ firstIndex: Int, x: CGFloat, extended: Bool, length: CGFloat = 2.3) {
            points[firstIndex] = CGPoint(x: x, y: 1.0)           // mcp
            points[firstIndex + 1] = CGPoint(x: x, y: 1.6)       // pip
            if extended {
                points[firstIndex + 2] = CGPoint(x: x, y: 2.0)   // dip
                points[firstIndex + 3] = CGPoint(x: x, y: length) // tip
            } else {
                points[firstIndex + 2] = CGPoint(x: x, y: 1.3)
                points[firstIndex + 3] = CGPoint(x: x, y: 0.9)   // curled back
            }
        }
        finger(5, x: -0.5, extended: index)
        finger(9, x: 0, extended: middle, length: middleLength)
        finger(13, x: 0.5, extended: ring)
        finger(17, x: 1.0, extended: pinky)
        // Thumb off to the left of the index base.
        points[1] = CGPoint(x: -0.8, y: 0.3)
        points[2] = CGPoint(x: -1.0, y: 0.6)
        points[3] = thumb ? CGPoint(x: -1.5, y: 0.9) : CGPoint(x: -0.6, y: 0.8)
        points[4] = thumb ? CGPoint(x: -2.1, y: 1.1) : CGPoint(x: -0.5, y: 0.9)
        return points
    }

    func testMiddleFingerFromGeometry() throws {
        let cue = try XCTUnwrap(HandGestureClassifier.classify(
            points: hand(middle: true), cannedLabel: nil, cannedScore: 0, box: box
        ))
        XCTAssertEqual(cue.kind, .middleFinger)
        XCTAssertTrue(cue.isHostile)
        XCTAssertGreaterThan(cue.score, 0.6)
    }

    func testMiddleFingerBeatsCannedFistAndPointing() throws {
        for canned in ["Closed_Fist", "Pointing_Up", "Open_Palm"] {
            let cue = try XCTUnwrap(HandGestureClassifier.classify(
                points: hand(middle: true), cannedLabel: canned, cannedScore: 0.95, box: box
            ))
            XCTAssertEqual(cue.kind, .middleFinger, "canned \(canned) must not hide it")
        }
    }

    func testThumbOutDoesNotHideMiddleFinger() throws {
        let cue = try XCTUnwrap(HandGestureClassifier.classify(
            points: hand(thumb: true, middle: true), cannedLabel: nil, cannedScore: 0, box: box
        ))
        XCTAssertEqual(cue.kind, .middleFinger)
    }

    func testIndexAndMiddleTogetherIsNotMiddleFinger() throws {
        let cue = try XCTUnwrap(HandGestureClassifier.classify(
            points: hand(index: true, middle: true), cannedLabel: "Victory", cannedScore: 0.9, box: box
        ))
        XCTAssertEqual(cue.kind, .peace)
        XCTAssertFalse(cue.isHostile)
    }

    func testFistOpenPalmAndPointingByGeometry() throws {
        func kind(_ points: [CGPoint]) throws -> HandGestureKind {
            try XCTUnwrap(HandGestureClassifier.classify(
                points: points, cannedLabel: nil, cannedScore: 0, box: box
            )).kind
        }
        XCTAssertEqual(try kind(hand()), .fist)
        XCTAssertEqual(try kind(hand(thumb: true, index: true, middle: true, ring: true, pinky: true)), .openPalm)
        XCTAssertEqual(try kind(hand(index: true)), .pointing)
    }

    func testCannedThumbsUpIsTrustedWhenSure() throws {
        let cue = try XCTUnwrap(HandGestureClassifier.classify(
            points: hand(thumb: true), cannedLabel: "Thumb_Up", cannedScore: 0.9, box: box
        ))
        XCTAssertEqual(cue.kind, .thumbsUp)
    }

    func testTooFewPointsGivesNothing() {
        XCTAssertNil(HandGestureClassifier.classify(
            points: [CGPoint](repeating: .zero, count: 10), cannedLabel: nil, cannedScore: 0, box: box
        ))
    }

    // MARK: Expressions

    func testHappy() {
        let cue = ExpressionClassifier.classify(blendshapes: [
            "mouthSmileLeft": 0.8, "mouthSmileRight": 0.8, "cheekSquintLeft": 0.4, "cheekSquintRight": 0.4,
        ])
        XCTAssertEqual(cue.kind, .happy)
    }

    func testAngry() {
        let cue = ExpressionClassifier.classify(blendshapes: [
            "browDownLeft": 0.8, "browDownRight": 0.7, "noseSneerLeft": 0.4, "noseSneerRight": 0.4,
            "mouthPressLeft": 0.3, "mouthPressRight": 0.3,
        ])
        XCTAssertEqual(cue.kind, .angry)
    }

    func testSad() {
        let cue = ExpressionClassifier.classify(blendshapes: [
            "mouthFrownLeft": 0.6, "mouthFrownRight": 0.6, "browInnerUp": 0.6,
        ])
        XCTAssertEqual(cue.kind, .sad)
    }

    func testSurprised() {
        let cue = ExpressionClassifier.classify(blendshapes: [
            "eyeWideLeft": 0.8, "eyeWideRight": 0.8, "jawOpen": 0.7, "browInnerUp": 0.7,
        ])
        XCTAssertEqual(cue.kind, .surprised)
    }

    func testNeutralAndNoise() {
        XCTAssertEqual(ExpressionClassifier.classify(blendshapes: [:]).kind, .neutral)
        XCTAssertEqual(ExpressionClassifier.classify(blendshapes: ["mouthSmileLeft": 0.1]).kind, .neutral)
    }

    func testSmilingCancelsAngerBrows() {
        let cue = ExpressionClassifier.classify(blendshapes: [
            "browDownLeft": 0.5, "browDownRight": 0.5, "mouthSmileLeft": 0.9, "mouthSmileRight": 0.9,
        ])
        XCTAssertNotEqual(cue.kind, .angry)
    }
}

/// The cues reach the score: a sustained middle finger adds, one frame does
/// not, and an angry face alone never alerts.
final class GestureScoringTests: XCTestCase {
    private let config = ThreatConfig()

    func testSustainedMiddleFingerRaisesScore() {
        var base = PersonFeatures()
        base.trend = 0.5
        var with = base
        with.hostileGesture = 0.9
        let scorer = ThreatScorer(config: config)
        XCTAssertGreaterThan(scorer.score(with).value, scorer.score(base).value + 0.2)
        XCTAssertTrue(scorer.score(with).reasons.contains("hostile hand gesture"))
    }

    func testAngryFaceAloneNeverAlerts() {
        var features = PersonFeatures()
        features.angryFace = 1
        let result = ThreatScorer(config: config).score(features)
        XCTAssertFalse(result.alert)
    }

    func testAbsentCuesChangeNothing() {
        let features = PersonFeatures(trend: 0.6, speed: 0.3)
        XCTAssertEqual(
            ThreatScorer(config: config).score(features).value,
            ThreatScorer(config: config).score(PersonFeatures(trend: 0.6, speed: 0.3, hostileGesture: 0, angryFace: 0)).value
        )
    }
}

final class LatencyMeterTests: XCTestCase {
    func testMeanAndP95OverRollingWindow() {
        let meter = LatencyMeter(capacity: 100)
        for ms in 1...100 { meter.record("hands", ms: Double(ms)) }
        let stats = meter.stats("hands")
        XCTAssertEqual(stats?.count, 100)
        XCTAssertEqual(stats?.meanMs ?? 0, 50.5, accuracy: 0.01)
        XCTAssertEqual(stats?.p95Ms ?? 0, 96, accuracy: 1)
        XCTAssertEqual(stats?.maxMs, 100)
    }

    func testOldSamplesRollOff() {
        let meter = LatencyMeter(capacity: 5)
        for _ in 0..<5 { meter.record("face", ms: 1000) }
        for _ in 0..<5 { meter.record("face", ms: 10) }
        XCTAssertEqual(meter.stats("face")?.meanMs ?? 0, 10, accuracy: 0.001)
    }

    func testMeasureRecordsAndReturnsTheValue() {
        let meter = LatencyMeter()
        let value = meter.measure("persons") { 42 }
        XCTAssertEqual(value, 42)
        XCTAssertEqual(meter.stats("persons")?.count, 1)
    }

    func testSummarySkipsStagesWithNoData() {
        let meter = LatencyMeter()
        meter.record("hands", ms: 12)
        let text = meter.summary(stages: ["persons", "hands"])
        XCTAssertTrue(text.hasPrefix("hands 12 ms"))
        XCTAssertFalse(text.contains("persons"))
    }
}
