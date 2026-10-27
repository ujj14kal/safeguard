import XCTest

/// SOS escalation core: the four tracks start together and fail
/// independently, retries back off, the end flow freezes honestly.
/// Timestamps are explicit: no waiting.
final class EscalationCoordinatorTests: XCTestCase {
    func testStartsAllFourTogether() {
        var coordinator = EscalationCoordinator()
        XCTAssertFalse(coordinator.started)
        coordinator.start()
        XCTAssertTrue(coordinator.started)
        for track in EscalationTrack.allCases {
            XCTAssertEqual(coordinator.status(of: track), .running, "\(track)")
        }
        coordinator.start() // idempotent
        XCTAssertEqual(coordinator.status(of: .route), .running)
    }

    func testOneFailureDoesNotStopTheRest() {
        var coordinator = EscalationCoordinator()
        coordinator.start()
        // Exhaust route's retries: 1 initial + 3 waits = terminal.
        coordinator.fail(.route, reason: "no network", at: 100)
        coordinator.fail(.route, reason: "no network", at: 102)
        coordinator.fail(.route, reason: "no network", at: 110)
        coordinator.fail(.route, reason: "no network", at: 140)
        XCTAssertEqual(coordinator.status(of: .route), .failed(reason: "no network"))
        for track: EscalationTrack in [.contacts, .stream, .cab] {
            XCTAssertEqual(coordinator.status(of: track), .running, "\(track)")
        }
    }

    func testRetryBackoffSchedule() {
        var coordinator = EscalationCoordinator()
        coordinator.start()
        coordinator.fail(.contacts, reason: "timeout", at: 100)
        XCTAssertEqual(coordinator.status(of: .contacts), .running, "waiting to retry")
        XCTAssertEqual(coordinator.dueRetries(at: 101.9), [])
        XCTAssertEqual(coordinator.dueRetries(at: 102), [.contacts])
        XCTAssertEqual(coordinator.dueRetries(at: 103), [], "each retry returned once")
    }

    func testRetryThenSuccess() {
        var coordinator = EscalationCoordinator()
        coordinator.start()
        coordinator.fail(.stream, reason: "timeout", at: 100)
        XCTAssertEqual(coordinator.dueRetries(at: 102), [.stream])
        coordinator.complete(.stream)
        XCTAssertEqual(coordinator.status(of: .stream), .done)
        XCTAssertEqual(coordinator.dueRetries(at: 1000), [])
    }

    func testCompleteIgnoresUnstartedAndEnded() {
        var coordinator = EscalationCoordinator()
        coordinator.complete(.route)
        XCTAssertEqual(coordinator.status(of: .route), .pending)
        coordinator.start()
        coordinator.end()
        coordinator.complete(.contacts)
        XCTAssertEqual(coordinator.status(of: .contacts), .failed(reason: "SOS ended"))
    }

    func testEndFlowFreezesHonestly() {
        var coordinator = EscalationCoordinator()
        coordinator.start()
        coordinator.complete(.route)
        coordinator.fail(.contacts, reason: "timeout", at: 100)
        coordinator.end()
        XCTAssertTrue(coordinator.ended)
        XCTAssertEqual(coordinator.status(of: .route), .done)
        XCTAssertEqual(coordinator.status(of: .contacts), .failed(reason: "SOS ended"))
        XCTAssertEqual(coordinator.status(of: .stream), .failed(reason: "SOS ended"))
        XCTAssertEqual(coordinator.dueRetries(at: 1000), [])
        coordinator.end() // idempotent
        XCTAssertEqual(coordinator.status(of: .route), .done)
    }

    func testTrackTitles() {
        XCTAssertEqual(
            EscalationTrack.allCases.map(\.title),
            ["Route", "Contacts", "Live stream", "Cab"]
        )
    }

    func testAttemptsAndReasonForChips() {
        var coordinator = EscalationCoordinator()
        XCTAssertEqual(coordinator.attempts(of: .route), 0, "not started")
        XCTAssertNil(coordinator.reason(of: .route))
        coordinator.start()
        XCTAssertEqual(coordinator.attempts(of: .route), 1, "first run")
        XCTAssertNil(coordinator.reason(of: .route), "no terminal failure yet")
        coordinator.fail(.route, reason: "timeout", at: 100)
        XCTAssertEqual(coordinator.attempts(of: .route), 2, "retry scheduled")
        XCTAssertNil(coordinator.reason(of: .route), "still running")
        coordinator.fail(.route, reason: "timeout", at: 102)
        coordinator.fail(.route, reason: "timeout", at: 110)
        coordinator.fail(.route, reason: "no route", at: 140)
        XCTAssertEqual(coordinator.status(of: .route), .failed(reason: "no route"))
        XCTAssertEqual(coordinator.reason(of: .route), "no route")
        XCTAssertNil(coordinator.reason(of: .cab), "other tracks unaffected")
    }
}

/// Contact list rules: at most 5, no blanks, no duplicate codes.
final class SOSContactStoreTests: XCTestCase {
    func testAddUpToFive() {
        var store = SOSContactStore()
        for index in 0..<5 {
            XCTAssertTrue(store.add(name: "Friend \(index)", code: "code\(index)"))
        }
        XCTAssertTrue(store.isFull)
        XCTAssertFalse(store.add(name: "Extra", code: "code5"))
        XCTAssertEqual(store.contacts.count, 5)
    }

    func testRejectsBlankAndDuplicates() {
        var store = SOSContactStore()
        XCTAssertFalse(store.add(name: "   ", code: "a"))
        XCTAssertFalse(store.add(name: "Meera", code: ""))
        XCTAssertTrue(store.add(name: "  Meera  ", code: "a"))
        XCTAssertEqual(store.contacts[0].name, "Meera")
        XCTAssertFalse(store.add(name: "Meera again", code: "a"))
    }

    func testRemoveAndLinkedCodes() {
        var store = SOSContactStore()
        store.add(name: "Meera", code: "a")
        store.add(name: "Arjun", code: "b")
        store.setLinked(code: "a", linked: true)
        store.setLinked(code: "missing", linked: true)
        XCTAssertEqual(store.linkedCodes, ["a"])
        store.remove(code: "a")
        XCTAssertEqual(store.linkedCodes, [])
        XCTAssertFalse(store.isFull)
    }

    func testInitTruncates() {
        let many = (0..<9).map { SOSContact(name: "F\($0)", code: "c\($0)") }
        XCTAssertEqual(SOSContactStore(contacts: many).contacts.count, 5)
    }

    func testAgreedCount() {
        var store = SOSContactStore()
        store.add(name: "Meera", code: "a")
        store.add(name: "Arjun", code: "b")
        XCTAssertEqual(store.agreedCount, 0)
        store.setAgreed(code: "a", agreed: true)
        store.setAgreed(code: "missing", agreed: true)
        XCTAssertEqual(store.agreedCount, 1)
        store.setAgreed(code: "b", agreed: true)
        XCTAssertEqual(store.agreedCount, 2)
    }

    func testOldContactsWithoutLinkOrAgreedStillLoad() throws {
        let data = Data(
            #"[{"name":"Meera","code":"a","linked":true}]"#.utf8
        )
        let decoded = try JSONDecoder().decode([SOSContact].self, from: data)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertTrue(decoded[0].linked)
        XCTAssertNil(decoded[0].link)
        XCTAssertFalse(decoded[0].agreed)
    }

    func testInviteLinkRoundTrips() throws {
        var store = SOSContactStore()
        XCTAssertTrue(store.add(
            name: "Meera", code: "a",
            link: "https://t.me/DemoBot?start=a"
        ))
        let data = try JSONEncoder().encode(store.contacts)
        let decoded = try JSONDecoder().decode([SOSContact].self, from: data)
        XCTAssertEqual(decoded, store.contacts)
        XCTAssertEqual(decoded[0].link, "https://t.me/DemoBot?start=a")
    }
}

/// Route choice: lowest ETA among the nearest 3 — never a crime model.
final class RouteChoiceTests: XCTestCase {
    func testPicksLowestETAAmongNearestThree() {
        let candidates = [
            RouteCandidate(name: "Near but slow", distanceMeters: 100, etaSeconds: 900),
            RouteCandidate(name: "Near and fast", distanceMeters: 200, etaSeconds: 300),
            RouteCandidate(name: "Third", distanceMeters: 300, etaSeconds: 600),
            // Best ETA overall, but 4th nearest: excluded.
            RouteCandidate(name: "Far and fastest", distanceMeters: 400, etaSeconds: 60),
        ]
        XCTAssertEqual(RouteChoice.pick(from: candidates)?.name, "Near and fast")
    }

    func testFewerThanThreeStillWorks() {
        let candidates = [
            RouteCandidate(name: "Only", distanceMeters: 500, etaSeconds: 700),
        ]
        XCTAssertEqual(RouteChoice.pick(from: candidates)?.name, "Only")
        XCTAssertNil(RouteChoice.pick(from: []))
    }

    func testNoResultsMessagesAreClear() {
        // No results never fails silently: the SOS screen shows one of
        // these. Pinned exactly, like the cab share wording.
        XCTAssertEqual(RouteChoice.noLocationMessage, "Location unavailable")
        XCTAssertEqual(RouteChoice.waitingForLocationMessage, "Waiting for location…")
        XCTAssertEqual(RouteChoice.noPlacesMessage, "No staffed places found nearby")
        XCTAssertEqual(RouteChoice.noRouteMessage, "No walking route found")
    }
}

/// The mock-cab banner: always present, always honest.
/// (Alert/cab/ended texts are composed server-side; their no-leak rule is
/// pinned by backend tests now.)
final class SOSMessageBuilderTests: XCTestCase {
    func testDemoBannerAlwaysPresent() {
        XCTAssertTrue(SOSMessageBuilder.demoBanner.contains("DEMO"))
        XCTAssertTrue(SOSMessageBuilder.demoBanner.contains("no real cab service"))
    }
}

final class UberDeepLinkTests: XCTestCase {
    private let pickup = UberDeepLink.Place(latitude: 28.6139, longitude: 77.2090, nickname: "SOS: my location")
    private let dropoff = UberDeepLink.Place(latitude: 28.6141, longitude: 77.2093, nickname: "Police Station")

    func testAppLinkCarriesPickupAndDropoff() throws {
        let url = try XCTUnwrap(UberDeepLink.appURL(pickup: pickup, dropoff: dropoff))
        XCTAssertEqual(url.scheme, "uber")
        let text = url.absoluteString.removingPercentEncoding ?? ""
        XCTAssertTrue(text.contains("action=setPickup"))
        XCTAssertTrue(text.contains("pickup[latitude]=28.61390"))
        XCTAssertTrue(text.contains("pickup[longitude]=77.20900"))
        XCTAssertTrue(text.contains("dropoff[latitude]=28.61410"))
        XCTAssertTrue(text.contains("dropoff[nickname]=Police Station"))
    }

    func testWebLinkUsesTheUniversalLink() throws {
        let url = try XCTUnwrap(UberDeepLink.webURL(pickup: pickup, dropoff: dropoff))
        XCTAssertEqual(url.host, "m.uber.com")
        XCTAssertTrue(url.absoluteString.hasPrefix("https://m.uber.com/ul/?"))
    }

    func testDropoffIsOptional() throws {
        let url = try XCTUnwrap(UberDeepLink.webURL(pickup: pickup, dropoff: nil))
        XCTAssertFalse(url.absoluteString.contains("dropoff"))
    }
}
