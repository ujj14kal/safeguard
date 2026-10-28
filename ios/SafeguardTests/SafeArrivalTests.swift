import XCTest
@testable import Safeguard

@MainActor
final class SafeArrivalTests: XCTestCase {
    private var suite: UserDefaults!
    private var scheduled: [(Date, Date)] = []
    private var cancelled = 0

    override func setUp() {
        super.setUp()
        let name = "safe-arrival-\(UUID().uuidString)"
        suite = UserDefaults(suiteName: name)
        suite.removePersistentDomain(forName: name)
        scheduled = []
        cancelled = 0
    }

    private func makeStore() -> SafeArrivalStore {
        SafeArrivalStore(defaults: suite, schedule: { _, _ in }, cancelScheduled: {})
    }

    func testTimerRunsThenMarkSafeEndsItQuietly() {
        let store = makeStore()
        let now = Date()
        store.start(minutes: 30, now: now)
        XCTAssertTrue(store.isActive)
        XCTAssertEqual(store.remaining(now: now) ?? 0, 1800, accuracy: 1)
        XCTAssertFalse(store.isOverdue(now: now.addingTimeInterval(1799)))
        store.markSafe()
        XCTAssertFalse(store.isActive)
        XCTAssertFalse(store.consumeOverdue(now: now.addingTimeInterval(4000)))
    }

    func testOverdueFiresExactlyOnce() {
        let store = makeStore()
        let now = Date()
        store.start(minutes: 15, now: now)
        XCTAssertFalse(store.consumeOverdue(now: now.addingTimeInterval(100)))
        XCTAssertTrue(store.consumeOverdue(now: now.addingTimeInterval(901)))
        XCTAssertFalse(store.consumeOverdue(now: now.addingTimeInterval(902)))
        XCTAssertFalse(store.isActive)
    }

    func testDeadlineSurvivesRelaunch() {
        let store = makeStore()
        store.start(minutes: 60)
        let again = makeStore()
        XCTAssertTrue(again.isActive)
        XCTAssertEqual(again.deadline?.timeIntervalSince1970 ?? 0,
                       store.deadline?.timeIntervalSince1970 ?? 1, accuracy: 0.01)
    }

    func testClockFormat() {
        XCTAssertEqual(SafeArrivalStore.clock(125), "2:05")
        XCTAssertEqual(SafeArrivalStore.clock(0), "0:00")
    }
}

final class AlertHysteresisTests: XCTestCase {
    func testAlertHoldsThroughShortDipsAndEndsAfterTheHold() {
        let config = ThreatConfig()
        var on = false
        var above = -Double.infinity
        var changes = 0
        let samples: [(Double, Double)] = [
            (0.0, 0.50), (0.2, 0.39), (0.4, 0.54), (0.6, 0.38), (0.8, 0.58), (1.0, 0.39),
            (1.4, 0.38), (2.0, 0.38), (2.6, 0.30),
        ]
        for (time, score) in samples {
            let next = config.nextAlert(wasAlert: on, topScore: score, now: time, lastAbove: above)
            if score >= config.alertThreshold { above = time }
            if next != on { changes += 1 }
            on = next
        }
        XCTAssertEqual(changes, 2, "one on, one off: dips below 0.40 inside the hold do not flap")
        XCTAssertFalse(on)
    }

    func testScoresBelowTheThresholdNeverStartAnAlert() {
        let config = ThreatConfig()
        XCTAssertFalse(config.nextAlert(wasAlert: false, topScore: 0.49, now: 5, lastAbove: 4.9))
        XCTAssertTrue(config.nextAlert(wasAlert: false, topScore: 0.50, now: 5, lastAbove: -.infinity))
    }
}

final class VerifyThrottleTests: XCTestCase {
    func testBurstsAreSpacedAndTheLastRequestIsNotLost() {
        var throttle = VerifyThrottle()
        XCTAssertTrue(throttle.consume(wanted: true, at: 10))
        XCTAssertFalse(throttle.consume(wanted: true, at: 11))
        XCTAssertFalse(throttle.consume(wanted: false, at: 12))
        XCTAssertTrue(throttle.consume(wanted: false, at: 13.1), "the held request goes out once the gap passes")
        XCTAssertFalse(throttle.consume(wanted: false, at: 14))
    }

    func testResetClearsEverything() {
        var throttle = VerifyThrottle()
        _ = throttle.consume(wanted: true, at: 1)
        _ = throttle.consume(wanted: true, at: 2)
        throttle.reset()
        XCTAssertTrue(throttle.consume(wanted: true, at: 2.1))
    }
}
