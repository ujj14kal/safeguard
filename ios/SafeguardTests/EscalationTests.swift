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
}

/// App-composed share texts: fixed template + wearer details only.
final class SOSMessageBuilderTests: XCTestCase {
    func testDemoBannerAlwaysPresent() {
        XCTAssertTrue(SOSMessageBuilder.demoBanner.contains("DEMO"))
        XCTAssertTrue(SOSMessageBuilder.demoBanner.contains("no real cab service"))
    }

    func testCabShareExactShape() {
        let text = SOSMessageBuilder.cabShare(
            driver: "Demo Driver", plate: "DL-1D-EMO", etaMinutes: 4,
            liveURL: "https://demo.test/live/abc"
        )
        XCTAssertEqual(
            text,
            "DEMO cab (no real cab service is connected): Demo Driver, "
                + "DL-1D-EMO, arriving in about 4 min. "
                + "Family live page: https://demo.test/live/abc"
        )
    }

    func testCabShareHasNoAppearanceOrTranscript() {
        // The builder takes no transcript input; the template words are
        // pinned here so appearance/identity wording can never creep in.
        let text = SOSMessageBuilder.cabShare(
            driver: "Demo Driver", plate: "DL-1D-EMO", etaMinutes: 4,
            liveURL: "https://demo.test/live/abc"
        ).lowercased()
        let words = Set(
            text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        )
        let forbidden = [
            "wearing", "wore", "shirt", "pants", "dress", "skinned", "beard",
            "man", "woman", "men", "women", "boy", "girl", "male", "female",
            "heard", "said", "transcript",
        ]
        XCTAssertTrue(
            words.intersection(forbidden).isEmpty,
            "leaked: \(words.intersection(forbidden))"
        )
    }
}
