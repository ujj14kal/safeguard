import XCTest
@testable import Safeguard

final class DashboardTests: XCTestCase {
    private func input(
        camera: PermissionStatus = .granted, microphone: PermissionStatus = .granted,
        speech: PermissionStatus = .granted, location: PermissionStatus = .granted,
        backend: Bool? = true, contacts: Int = 2, linked: Int = 2, real: Bool = true
    ) -> ReadinessInput {
        ReadinessInput(
            camera: camera, microphone: microphone, speech: speech, location: location,
            backendReachable: backend, contactCount: contacts, linkedCount: linked,
            sendsRealAlerts: real
        )
    }

    private func level(_ id: String, _ input: ReadinessInput) -> ReadinessLevel? {
        Readiness.items(input).first { $0.id == id }?.level
    }

    func testAllGoodIsFullyReady() {
        let items = Readiness.items(input())
        XCTAssertEqual(items.count, 7)
        XCTAssertEqual(Readiness.readyCount(items), 7)
    }

    func testDeniedPermissionIsAProblemWithFix() {
        let items = Readiness.items(input(camera: .denied))
        let camera = items.first { $0.id == "camera" }
        XCTAssertEqual(camera?.level, .problem)
        XCTAssertEqual(camera?.fix, .systemSettings)
    }

    func testNotAskedIsAWarning() {
        XCTAssertEqual(level("location", input(location: .notAsked)), .warning)
    }

    func testBackendStates() {
        XCTAssertEqual(level("backend", input(backend: true)), .ok)
        XCTAssertEqual(level("backend", input(backend: false)), .problem)
        XCTAssertEqual(level("backend", input(backend: nil)), .warning)
    }

    func testContactRules() {
        XCTAssertEqual(level("contacts", input(contacts: 0, linked: 0)), .problem)
        XCTAssertEqual(level("contacts", input(contacts: 3, linked: 1)), .warning)
        XCTAssertEqual(level("contacts", input(contacts: 2, linked: 2)), .ok)
    }

    func testDryRunIsAWarning() {
        XCTAssertEqual(level("alerts", input(real: false)), .warning)
    }

    func testStatsCountOnlyLast30Days() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func entry(daysAgo: Double, seconds: Double, alerted: Int, saved: Int) -> IncidentHistoryEntry {
            let start = now.addingTimeInterval(-daysAgo * 86400)
            return IncidentHistoryEntry(
                startedAt: start, endedAt: start.addingTimeInterval(seconds), cause: "noReply",
                contactsAlerted: alerted, evidenceSaved: saved
            )
        }
        let stats = DashboardStats.from([
            entry(daysAgo: 2, seconds: 60, alerted: 2, saved: 3),
            entry(daysAgo: 10, seconds: 120, alerted: 1, saved: 1),
            entry(daysAgo: 40, seconds: 999, alerted: 9, saved: 9),
        ], now: now)
        XCTAssertEqual(stats.eventsLast30Days, 2)
        XCTAssertEqual(stats.contactsAlerted, 3)
        XCTAssertEqual(stats.evidenceSaved, 4)
        XCTAssertEqual(stats.averageDurationSeconds, 90)
    }

    func testEmptyStats() {
        let stats = DashboardStats.from([])
        XCTAssertEqual(stats.eventsLast30Days, 0)
        XCTAssertNil(stats.lastEventDate)
        XCTAssertEqual(stats.averageDurationSeconds, 0)
    }
}

final class PhoneContactsTests: XCTestCase {
    private let people = [
        PhoneContact(id: "1", name: "Zara Khan", phone: "+1 555 0101"),
        PhoneContact(id: "2", name: "amit Sharma", phone: "+1 555 0102"),
        PhoneContact(id: "3", name: "Meera", phone: nil),
    ]

    func testBlankQueryReturnsEveryoneSortedAToZ() {
        let names = PhoneContactList.filter(people, query: "  ").map(\.name)
        XCTAssertEqual(names, ["amit Sharma", "Meera", "Zara Khan"])
    }

    func testSearchByNameIsCaseInsensitive() {
        XCTAssertEqual(PhoneContactList.filter(people, query: "ZARA").map(\.id), ["1"])
    }

    func testSearchByNumberDigits() {
        XCTAssertEqual(PhoneContactList.filter(people, query: "0102").map(\.id), ["2"])
    }

    func testNumberKeyMatchesAcrossFormats() {
        XCTAssertEqual(PhoneNumber.key("+91 98765 43210"), PhoneNumber.key("098765-43210"))
        XCTAssertNil(PhoneNumber.key("123"))
        XCTAssertNil(PhoneNumber.key(nil))
    }

    func testStoreRecordsPhoneAndSpotsDuplicates() {
        var store = SOSContactStore()
        XCTAssertTrue(store.add(name: "Zara", code: "c1", phone: "+1 555 0101"))
        XCTAssertEqual(store.contacts.first?.phone, "+1 555 0101")
        XCTAssertTrue(store.containsPhone("1-555-0101"))
        XCTAssertFalse(store.containsPhone("+1 555 0199"))
    }

    func testOldSavedContactsWithoutPhoneStillLoad() throws {
        let json = #"[{"name":"Old","code":"x","linked":true}]"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode([SOSContact].self, from: json)
        XCTAssertNil(decoded.first?.phone)
        XCTAssertEqual(decoded.first?.name, "Old")
    }
}
