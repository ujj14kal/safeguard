import CoreGraphics
import XCTest

/// HUD mapping + status: aspect-fill boxes (incl. the full-screen portrait
/// case), per-track colours, and pill priority. No UI host needed.
final class BoxMappingTests: XCTestCase {
    // MARK: - Aspect-fill mapping

    func testFullFrameFillsView() {
        let rect = AspectFillMapper.boxRect(
            CGRect(x: 0, y: 0, width: 1, height: 1),
            frame: CGSize(width: 288, height: 512),
            view: CGSize(width: 144, height: 256)
        )
        XCTAssertEqual(rect.minX, 0, accuracy: 1e-9)
        XCTAssertEqual(rect.minY, 0, accuracy: 1e-9)
        XCTAssertEqual(rect.width, 144, accuracy: 1e-9)
        XCTAssertEqual(rect.height, 256, accuracy: 1e-9)
    }

    func testFullScreenPortraitSize() {
        // Portrait buffer 720x1280 on a 393x852 full-screen view: scale by
        // height (852/1280), crop 43.125 pt off each side.
        let rect = AspectFillMapper.boxRect(
            CGRect(x: 0, y: 0, width: 1, height: 1),
            frame: CGSize(width: 720, height: 1280),
            view: CGSize(width: 393, height: 852)
        )
        XCTAssertEqual(rect.minX, -43.125, accuracy: 1e-6)
        XCTAssertEqual(rect.minY, 0, accuracy: 1e-6)
        XCTAssertEqual(rect.width, 479.25, accuracy: 1e-6)
        XCTAssertEqual(rect.height, 852, accuracy: 1e-6)
    }

    func testVisionYFlipsToTopLeft() {
        // A person in the TOP third (Vision y 0.65...0.95, origin
        // lower-left) lands in the TOP third of the screen.
        let rect = AspectFillMapper.boxRect(
            CGRect(x: 0.4, y: 0.65, width: 0.2, height: 0.30),
            frame: CGSize(width: 720, height: 1280),
            view: CGSize(width: 393, height: 852)
        )
        XCTAssertLessThan(rect.minY, 852 / 3, "top-third person must map to the top")
        XCTAssertGreaterThan(rect.minY, 0)
        XCTAssertLessThan(rect.maxX, 393)
        XCTAssertGreaterThan(rect.minX, 0)
    }

    func testDegenerateSizesReturnZero() {
        XCTAssertEqual(
            AspectFillMapper.boxRect(
                CGRect(x: 0, y: 0, width: 1, height: 1),
                frame: .zero, view: CGSize(width: 100, height: 100)
            ),
            .zero
        )
        XCTAssertEqual(
            AspectFillMapper.boxRect(
                CGRect(x: 0, y: 0, width: 1, height: 1),
                frame: CGSize(width: 100, height: 100), view: .zero
            ),
            .zero
        )
    }

    // MARK: - Per-track levels

    func testBoxLevelThresholds() {
        let config = ThreatConfig()
        XCTAssertEqual(
            PersonBoxLevel.level(alert: false, height: 0.10, config: config), .clear
        )
        XCTAssertEqual(
            PersonBoxLevel.level(alert: false, height: 0.30, config: config), .near
        )
        XCTAssertEqual(
            PersonBoxLevel.level(alert: false, height: 0.45, config: config), .tooClose
        )
    }

    func testAlertingTrackIsAlwaysRed() {
        let config = ThreatConfig()
        XCTAssertEqual(
            PersonBoxLevel.level(alert: true, height: 0.05, config: config), .tooClose
        )
    }

    // MARK: - Pill priority

    func testPillBaseStates() {
        XCTAssertEqual(
            HudStatus.resolve(),
            HudStatus(text: "Protecting", symbol: "shield.fill")
        )
        XCTAssertEqual(
            HudStatus.resolve(listenerLive: true),
            HudStatus(text: "Listening", symbol: "mic.fill")
        )
    }

    func testPillProximityBeatsBase() {
        XCTAssertEqual(HudStatus.resolve(proximity: .near).text, "Someone is near")
        XCTAssertEqual(HudStatus.resolve(proximity: .tooClose).text, "Too close")
        XCTAssertEqual(
            HudStatus.resolve(proximity: .tooClose).symbol, "exclamationmark.triangle.fill"
        )
    }

    func testPillPriorityOrder() {
        // Asking > safe > window > alert > proximity > listening > base.
        XCTAssertEqual(
            HudStatus.resolve(
                asking: true, safe: true, listeningWindow: true, alert: true,
                proximity: .tooClose, listenerLive: true
            ).text,
            "Are you safe?"
        )
        XCTAssertEqual(
            HudStatus.resolve(
                safe: true, listeningWindow: true, alert: true,
                proximity: .tooClose, listenerLive: true
            ).text,
            "You're safe"
        )
        XCTAssertEqual(
            HudStatus.resolve(
                listeningWindow: true, alert: true,
                proximity: .tooClose, listenerLive: true
            ).text,
            "Stay quiet, listening"
        )
        XCTAssertEqual(
            HudStatus.resolve(alert: true, proximity: .tooClose, listenerLive: true).text,
            "Something seems off"
        )
    }
}
