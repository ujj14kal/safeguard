import CoreGraphics
import XCTest

/// Feature math on synthetic histories. Times are explicit seconds at a
/// simulated 5 Hz; boxes are normalized Vision coordinates.
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

    /// Feed one track's samples (plus `others` background tracks); returns
    /// the track's features at the last sample time.
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

    // MARK: - Distance trend / approach speed

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

    // MARK: - Persistence

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

    // MARK: - Facing

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
        // No face keypoints at all, wide shoulders: must not count as facing.
        let pose = BodyPose(
            leftShoulder: .init(point: CGPoint(x: 0.44, y: 0.55), confidence: 0.9),
            rightShoulder: .init(point: CGPoint(x: 0.56, y: 0.55), confidence: 0.9)
        )
        XCTAssertEqual(pose.facingScore(using: ThreatConfig()), 0)
    }

    // MARK: - Isolation

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

    // MARK: - Blocking / cornering

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
        // Approaching fast but moving sideways: bearing not stable, no intercept.
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

    // MARK: - Housekeeping

    func testNoSamplesReturnsNil() {
        XCTAssertNil(FeatureExtractor().features(for: 999, at: 10))
    }

    func testResetClearsHistory() {
        let extractor = FeatureExtractor()
        feed(extractor, id: 1, samples: [(0, box(cx: 0.5, h: 0.25))])
        extractor.reset()
        XCTAssertNil(extractor.features(for: 1, at: 0))
    }
}
