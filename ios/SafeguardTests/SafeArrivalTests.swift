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
    func testAlertDoesNotFlapAroundTheThreshold() {
        let config = ThreatConfig()
        var on = false
        var changes = 0
        for score in [0.50, 0.46, 0.54, 0.43, 0.51, 0.44, 0.41] {
            let next = config.nextAlert(wasAlert: on, topScore: score)
            if next != on { changes += 1 }
            on = next
        }
        XCTAssertEqual(changes, 1, "once on, scores just under 0.50 keep the alert on")
        XCTAssertTrue(on)
        XCTAssertFalse(config.nextAlert(wasAlert: true, topScore: 0.39))
        XCTAssertFalse(config.nextAlert(wasAlert: false, topScore: 0.49))
    }
}
