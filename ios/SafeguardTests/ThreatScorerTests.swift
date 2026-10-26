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
