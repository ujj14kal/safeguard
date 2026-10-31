import XCTest
@testable import Safeguard

final class NameSpotterTests: XCTestCase {
    private func rated(_ text: String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: NameSpotter.names(in: text).map { ($0.name, $0.rating) })
    }

    func testIntroductionIsStrong() {
        XCTAssertEqual(rated("hi my name is ravi kumar"), ["Ravi Kumar": "strongly possible"])
        XCTAssertEqual(rated("mera naam Rohan hai"), ["Rohan": "strongly possible"])
        XCTAssertEqual(rated("call me Vikram"), ["Vikram": "strongly possible"])
    }

    func testCapitalisedSelfIntroIsStrongLowercaseIsPossible() {
        XCTAssertEqual(rated("I am Amit"), ["Amit": "strongly possible"])
        XCTAssertEqual(rated("i am amit"), ["Amit": "possible"])
    }

    func testAddressedNameIsPossible() {
        XCTAssertEqual(rated("hey Priya wait"), ["Priya": "possible"])
    }

    func testCommonWordsAreNotNames() {
        XCTAssertTrue(rated("I am fine thank you").isEmpty)
        XCTAssertTrue(rated("i am going home").isEmpty)
        XCTAssertTrue(rated("hello how are you").isEmpty)
        XCTAssertTrue(rated("main theek hoon").isEmpty)
    }

    func testHindiIntroduction() {
        XCTAssertEqual(rated("मेरा नाम राहुल है"), ["राहुल": "strongly possible"])
    }

    func testBareCapitalisedNamesArePossible() {
        XCTAssertEqual(rated("Ujjwal Deepika"), ["Ujjwal": "possible", "Deepika": "possible"])
        XCTAssertEqual(rated("please call Deepika now"), ["Deepika": "possible"])
    }

    func testSentenceStartAndLowercaseWordsAreIgnored() {
        XCTAssertTrue(rated("Walking home from the market today now").isEmpty)
        XCTAssertTrue(rated("where is the station").isEmpty)
    }
}
