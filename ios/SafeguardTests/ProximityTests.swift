import XCTest

final class ProximityTests: XCTestCase {
    func testRisesOnlyAfterHold() {
        var tracker = ProximityTracker()
        XCTAssertEqual(tracker.update(nearestHeight: 0.35, at: 0), .clear)
        XCTAssertEqual(tracker.update(nearestHeight: 0.35, at: 0.2), .clear)
        XCTAssertEqual(tracker.update(nearestHeight: 0.35, at: 0.4), .clear)
        XCTAssertEqual(tracker.update(nearestHeight: 0.35, at: 0.6), .near)
    }

    func testDoesNotFlickerOnOneNoisySample() {
        var tracker = ProximityTracker()
        XCTAssertEqual(tracker.update(nearestHeight: 0.1, at: 0), .clear)
        XCTAssertEqual(tracker.update(nearestHeight: 0.1, at: 0.2), .clear)
        XCTAssertEqual(tracker.update(nearestHeight: 0.5, at: 0.4), .clear)
        XCTAssertEqual(tracker.update(nearestHeight: 0.1, at: 0.6), .clear)
        XCTAssertEqual(tracker.update(nearestHeight: 0.1, at: 1.2), .clear)
    }

    func testFallsOnlyAfterHoldBelowThresholdMinusHysteresis() {
        var tracker = ProximityTracker()
        tracker.update(nearestHeight: 0.35, at: 0)
        tracker.update(nearestHeight: 0.35, at: 0.6)
        XCTAssertEqual(tracker.level, .near)
        XCTAssertEqual(tracker.update(nearestHeight: 0.27, at: 1.0), .near)
        XCTAssertEqual(tracker.update(nearestHeight: 0.27, at: 2.5), .near)
        XCTAssertEqual(tracker.update(nearestHeight: 0.2, at: 3.0), .near)
        XCTAssertEqual(tracker.update(nearestHeight: 0.2, at: 3.5), .near)
        XCTAssertEqual(tracker.update(nearestHeight: 0.2, at: 4.0), .clear)
    }

    func testNoPeopleFallsToClear() {
        var tracker = ProximityTracker()
        tracker.update(nearestHeight: 0.5, at: 0)
        tracker.update(nearestHeight: 0.5, at: 0.6)
        XCTAssertEqual(tracker.level, .tooClose)
        XCTAssertEqual(tracker.update(nearestHeight: nil, at: 1.0), .tooClose)
        XCTAssertEqual(tracker.update(nearestHeight: nil, at: 2.0), .clear)
    }

    func testUsesTimestampsNotFrameCounts() {
        var tracker = ProximityTracker()
        for step in 0..<10 {
            let level = tracker.update(nearestHeight: 0.35, at: Double(step) * 0.03)
            XCTAssertEqual(level, .clear)
        }
        XCTAssertEqual(tracker.update(nearestHeight: 0.35, at: 0.65), .near)
    }

    func testDirectJumpToTooClose() {
        var tracker = ProximityTracker()
        tracker.update(nearestHeight: 0.5, at: 0)
        XCTAssertEqual(tracker.update(nearestHeight: 0.5, at: 0.6), .tooClose)
    }

    func testFallFromTooCloseToNear() {
        var tracker = ProximityTracker()
        tracker.update(nearestHeight: 0.5, at: 0)
        tracker.update(nearestHeight: 0.5, at: 0.6)
        XCTAssertEqual(tracker.level, .tooClose)
        XCTAssertEqual(tracker.update(nearestHeight: 0.35, at: 1.0), .tooClose)
        XCTAssertEqual(tracker.update(nearestHeight: 0.35, at: 2.0), .near)
    }
}
