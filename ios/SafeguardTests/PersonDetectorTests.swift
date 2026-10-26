import CoreVideo
import XCTest

/// Detector plumbing on synthetic frames (blank/strictly no-person input must
/// yield no detections and never throw). Positive-path detection needs real
/// footage and is covered by the Phase 8 replay tuning, not here.
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
