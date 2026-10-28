import CoreVideo
import XCTest

final class PersonDetectorTests: XCTestCase {
    func testBlankBlackImageFindsNobody() throws {
        let detector = PersonDetector()
        let buffer = try TestHelpers.makePixelBuffer(fill: 0)
        XCTAssertEqual(try detector.detect(in: buffer), [])
    }

    func testBlankWhiteImageFindsNobody() throws {
        let detector = PersonDetector()
        let buffer = try TestHelpers.makePixelBuffer(fill: 255)
        XCTAssertEqual(try detector.detect(in: buffer), [])
    }

    func testNoiseImageFindsNobody() throws {
        let detector = PersonDetector()
        let buffer = try TestHelpers.makeNoiseBuffer()
        XCTAssertEqual(try detector.detect(in: buffer), [])
    }

    func testDetectorIsReusable() throws {
        let detector = PersonDetector()
        let black = try TestHelpers.makePixelBuffer(fill: 0)
        let white = try TestHelpers.makePixelBuffer(fill: 255)
        XCTAssertEqual(try detector.detect(in: black), [])
        XCTAssertEqual(try detector.detect(in: white), [])
    }

}
