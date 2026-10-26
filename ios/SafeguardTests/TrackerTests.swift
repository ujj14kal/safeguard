import CoreGraphics
import XCTest

/// Tracker behaviour on synthetic boxes. Runs under `xcodebuild test`.
final class TrackerTests: XCTestCase {
    private func person(
        _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: Float = 0.9
    ) -> DetectedPerson {
        DetectedPerson(box: CGRect(x: x, y: y, width: w, height: h), confidence: c)
    }

    func testIoUIdentical() {
        let box = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        XCTAssertEqual(intersectionOverUnion(box, box), 1.0, accuracy: 1e-9)
    }

    func testIoUDisjoint() {
        let a = CGRect(x: 0, y: 0, width: 0.2, height: 0.2)
        let b = CGRect(x: 0.8, y: 0.8, width: 0.2, height: 0.2)
        XCTAssertEqual(intersectionOverUnion(a, b), 0.0, accuracy: 1e-9)
    }

    func testIoUPartial() {
        let a = CGRect(x: 0, y: 0, width: 1, height: 1)
        let b = CGRect(x: 0.5, y: 0, width: 1, height: 1)
        XCTAssertEqual(intersectionOverUnion(a, b), 1.0 / 3.0, accuracy: 1e-9)
    }

    func testStableIDAcrossFrames() {
        let tracker = IoUTracker()
        for _ in 0..<5 {
            let tracks = tracker.update(detections: [person(0.2, 0.2, 0.2, 0.4)])
            XCTAssertEqual(tracks.count, 1)
            XCTAssertEqual(tracks[0].id, 1)
        }
    }

    func testTwoPeopleKeepIDs() {
        let tracker = IoUTracker()
        let frames = [
            [person(0.1, 0.2, 0.2, 0.4), person(0.7, 0.2, 0.2, 0.4)],
            [person(0.12, 0.21, 0.2, 0.4), person(0.68, 0.19, 0.2, 0.4)],
            [person(0.14, 0.2, 0.2, 0.4), person(0.66, 0.2, 0.2, 0.4)],
        ]
        for detections in frames {
            let tracks = tracker.update(detections: detections)
            XCTAssertEqual(tracks.map(\.id), [1, 2])
            XCTAssertLessThan(tracks[0].box.minX, tracks[1].box.minX)
        }
    }

    func testNewDetectionSpawnsTrack() {
        let tracker = IoUTracker()
        XCTAssertEqual(tracker.update(detections: [person(0.1, 0.1, 0.2, 0.2)]).map(\.id), [1])
        let tracks = tracker.update(detections: [
            person(0.1, 0.1, 0.2, 0.2), person(0.7, 0.7, 0.2, 0.2),
        ])
        XCTAssertEqual(tracks.map(\.id), [1, 2])
    }

    func testCoastsThroughBriefGap() {
        let tracker = IoUTracker(maxMissedFrames: 3)
        XCTAssertEqual(tracker.update(detections: [person(0.2, 0.2, 0.2, 0.4)]).map(\.id), [1])
        XCTAssertEqual(tracker.update(detections: []).map(\.id), [1])
        let coasted = tracker.update(detections: [])
        XCTAssertEqual(coasted.map(\.id), [1])
        XCTAssertEqual(coasted[0].missed, 2)
        let recovered = tracker.update(detections: [person(0.21, 0.2, 0.2, 0.4)])
        XCTAssertEqual(recovered.map(\.id), [1])
        XCTAssertEqual(recovered[0].missed, 0)
    }

    func testDropsAfterMaxMissed() {
        let tracker = IoUTracker(maxMissedFrames: 2)
        tracker.update(detections: [person(0.2, 0.2, 0.2, 0.4)])
        tracker.update(detections: [])
        tracker.update(detections: [])
        XCTAssertEqual(tracker.update(detections: []).count, 0)
        let tracks = tracker.update(detections: [person(0.2, 0.2, 0.2, 0.4)])
        XCTAssertEqual(tracks.map(\.id), [2])
    }

    func testFarDetectionDoesNotMatch() {
        let tracker = IoUTracker()
        tracker.update(detections: [person(0.05, 0.05, 0.1, 0.1)])
        let tracks = tracker.update(detections: [person(0.8, 0.8, 0.1, 0.1)])
        XCTAssertEqual(tracks.count, 2)
    }

    func testEmptyDetectionsCoast() {
        let tracker = IoUTracker()
        tracker.update(detections: [person(0.2, 0.2, 0.2, 0.4)])
        let tracks = tracker.update(detections: [])
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks[0].missed, 1)
    }

    func testPassingWithClearanceKeepsIDs() {
        // A travels left-to-right along the top, B right-to-left along the
        // bottom; rows never overlap, so IDs must stay put. Steps overlap
        // frame-to-frame (IoU 0.5), matching how real detections move.
        let tracker = IoUTracker()
        for step in 0..<15 {
            let t = CGFloat(step) * 0.05
            let tracks = tracker.update(detections: [
                person(0.05 + t, 0.55, 0.15, 0.3),
                person(0.75 - t, 0.10, 0.15, 0.3),
            ])
            XCTAssertEqual(tracks.map(\.id), [1, 2])
            XCTAssertGreaterThan(tracks[0].box.minY, tracks[1].box.minY)
        }
    }

}
