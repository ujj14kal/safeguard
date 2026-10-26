import XCTest

/// Proximity level behaviour on synthetic heights and explicit timestamps.
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
        // Reach near first.
        tracker.update(nearestHeight: 0.35, at: 0)
        tracker.update(nearestHeight: 0.35, at: 0.6)
        XCTAssertEqual(tracker.level, .near)
        // In the hysteresis band (0.25-0.30): holds near indefinitely.
        XCTAssertEqual(tracker.update(nearestHeight: 0.27, at: 1.0), .near)
        XCTAssertEqual(tracker.update(nearestHeight: 0.27, at: 2.5), .near)
        // Below 0.25: falls only after the 1 s hold.
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
        // A burst of 10 samples inside 0.3 s must not rise (count-based would).
        var tracker = ProximityTracker()
        for step in 0..<10 {
            let level = tracker.update(nearestHeight: 0.35, at: Double(step) * 0.03)
            XCTAssertEqual(level, .clear)
        }
        // ...while sparse samples spanning the hold do rise.
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
        // 0.35 is below 0.45 - 0.05 but still near: lands on near, not clear.
        XCTAssertEqual(tracker.update(nearestHeight: 0.35, at: 1.0), .tooClose)
        XCTAssertEqual(tracker.update(nearestHeight: 0.35, at: 2.0), .near)
    }
}
