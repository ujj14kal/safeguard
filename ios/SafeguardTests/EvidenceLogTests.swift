import XCTest
@testable import Safeguard

final class PlateTextTests: XCTestCase {
    func testCommonIndianPlatesAreRecognisedInAnySpacing() {
        XCTAssertEqual(PlateText.normalize("MH 12 AB 1234"), "MH12AB1234")
        XCTAssertEqual(PlateText.normalize("dl3c ab-1234"), "DL3CAB1234")
        XCTAssertEqual(PlateText.normalize("KA01MJ4321"), "KA01MJ4321")
        XCTAssertEqual(PlateText.normalize("22BH1234AA"), "22BH1234AA")
    }

    func testCommonMisreadsAreCorrectedByPosition() {
        XCTAssertEqual(PlateText.normalize("MH12AB123O"), "MH12AB1230")
        XCTAssertEqual(PlateText.normalize("MH12AB12S4"), "MH12AB1254")
        XCTAssertEqual(PlateText.normalize("0L3CAB1234"), nil, "0L is not a state code")
        XCTAssertEqual(PlateText.normalize("D13CAB1234"), nil, "13 cannot turn D1 into DL, only digits at the start become letters")
        XCTAssertEqual(PlateText.normalize("DL3CAB1234"), "DL3CAB1234")
    }

    func testOrdinaryTextIsNotAPlate() {
        XCTAssertNil(PlateText.normalize("OPEN 24 HOURS"))
        XCTAssertNil(PlateText.normalize("ZZ12AB1234"), "ZZ is not a state code")
        XCTAssertNil(PlateText.normalize("MH12"))
        XCTAssertNil(PlateText.normalize("SAFEGUARD2026"))
    }

    func testDisplayFormatting() {
        XCTAssertEqual(PlateText.display("MH12AB1234"), "MH 12 AB 1234")
        XCTAssertEqual(PlateText.display("DL3CAB1234"), "DL 3C AB 1234")
        XCTAssertEqual(PlateText.display("22BH1234AA"), "22BH1234AA")
    }

    func testRatingStartsPossibleAndBecomesStronglyPossibleOnASecondReading() {
        var tracker = PlateTracker()
        let first = tracker.observe("MH12AB1234", at: 10)
        XCTAssertEqual(first?.rating, "possible")
        XCTAssertNil(tracker.observe("MH12AB1234", at: 10.4), "too soon to count again")
        XCTAssertEqual(tracker.observe("MH12AB1234", at: 12)?.rating, "strongly possible")
        XCTAssertNil(tracker.observe("MH12AB1234", at: 14))
        XCTAssertNil(tracker.observe("MH12AB1234", at: 16))
        XCTAssertNotNil(tracker.observe("MH12AB1234", at: 18), "the fifth reading is reported once more")
    }
}

final class EvidenceLogTests: XCTestCase {
    func testRepeatedNamesMergeAndKeepTheStrongestRating() {
        let log = EvidenceLog()
        log.add(LogItem(type: "name", text: "Rahul", rating: "possible", source: "Rahul wait"))
        log.add(LogItem(type: "name", text: "rahul", rating: "strongly possible"))
        let items = log.drain()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].count, 2)
        XCTAssertEqual(items[0].rating, "strongly possible")
        XCTAssertEqual(items[0].source, "Rahul wait")
        XCTAssertEqual(log.count, 0)
    }

    func testEveryGestureMomentIsKeptSeparately() {
        let log = EvidenceLog()
        log.add(LogItem(type: "gesture", text: "Obscene hand gesture", rating: "possible", shot: Data([1])))
        log.add(LogItem(type: "gesture", text: "Obscene hand gesture", rating: "possible", shot: Data([2])))
        XCTAssertEqual(log.drain().count, 2)
    }

    func testOldEntriesAndOverflowFallAway() {
        let log = EvidenceLog()
        let now = Date()
        log.add(LogItem(type: "name", text: "Old", rating: "possible", time: now.addingTimeInterval(-700)), now: now)
        XCTAssertEqual(log.count, 0)
        for index in 0..<80 {
            log.add(LogItem(type: "plate", text: "MH 12 AB \(1000 + index)", rating: "possible", time: now), now: now)
        }
        XCTAssertEqual(log.count, EvidenceLog.capacity)
    }

    func testFailedBatchesCanBePutBack() {
        let log = EvidenceLog()
        log.add(LogItem(type: "name", text: "Meera", rating: "possible"))
        let batch = log.drain()
        XCTAssertEqual(log.count, 0)
        log.requeue(batch)
        XCTAssertEqual(log.count, 1)
    }

    func testItemJSONMatchesWhatTheServerExpects() throws {
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        let item = LogItem(type: "gesture", text: "Obscene hand gesture", rating: "possible",
                           time: when, source: nil, shot: Data([1]), count: 1)
        let json = item.json(shotName: "shot-00003.jpg")
        XCTAssertEqual(json["type"] as? String, "gesture")
        XCTAssertEqual(json["shot"] as? String, "shot-00003.jpg")
        XCTAssertEqual(json["t"] as? Double, 1_800_000_000)
        XCTAssertNil(json["source"])
        XCTAssertEqual(EvidenceSegmentName.filename(kind: .shot, seq: 3), "shot-00003.jpg")
        XCTAssertEqual(EvidenceSegmentName.parse("shot-00003.jpg")?.kind, .shot)
    }
}
