import XCTest

final class ThemeContrastTests: XCTestCase {
    private func luminance(_ hex: UInt32) -> Double {
        let channels = [Double((hex >> 16) & 0xFF) / 255,
                        Double((hex >> 8) & 0xFF) / 255,
                        Double(hex & 0xFF) / 255]
        let linear = channels.map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }

    private func ratio(_ first: UInt32, _ second: UInt32) -> Double {
        let high = max(luminance(first), luminance(second))
        let low = min(luminance(first), luminance(second))
        return (high + 0.05) / (low + 0.05)
    }

    func testMathIsCalibrated() {
        XCTAssertEqual(ratio(0x000000, 0xFFFFFF), 21, accuracy: 0.01)
        XCTAssertEqual(ratio(0xFFFFFF, 0xFFFFFF), 1, accuracy: 1e-9)
    }

    func testTextPairs() {
        XCTAssertGreaterThanOrEqual(
            ratio(DS.Colors.accentHex, DS.Colors.backgroundHex), 4.5
        )
        XCTAssertGreaterThanOrEqual(
            ratio(DS.Colors.accentHex, DS.Colors.surfaceHex), 4.5
        )
        XCTAssertGreaterThanOrEqual(
            ratio(0xFFFFFF, DS.Colors.buttonFillHex), 4.5
        )
    }

    func testIconAndBorderPairs() {
        for pair in [(DS.Colors.dangerHex, DS.Colors.backgroundHex),
                     (DS.Colors.warningHex, DS.Colors.backgroundHex),
                     (DS.Colors.okHex, DS.Colors.backgroundHex),
                     (DS.Colors.accentHex, DS.Colors.surfaceElevatedHex)]
        {
            XCTAssertGreaterThanOrEqual(
                ratio(pair.0, pair.1), 3.0,
                String(format: "%06X on %06X", pair.0, pair.1)
            )
        }
    }

    func testBoxColoursMatchLevels() {
        XCTAssertEqual(DS.Colors.accentHex, 0xB98DD1)
        XCTAssertEqual(DS.Colors.warningHex, 0xFFD23F)
        XCTAssertEqual(DS.Colors.dangerHex, 0xFF4D4D)
    }

    func testSetupStatusTextPairs() {
        XCTAssertGreaterThanOrEqual(
            ratio(DS.Colors.warningHex, DS.Colors.backgroundHex), 4.5
        )
        XCTAssertGreaterThanOrEqual(
            ratio(DS.Colors.okHex, DS.Colors.backgroundHex), 4.5
        )
    }

    func testSOSScrimPairs() {
        XCTAssertGreaterThanOrEqual(
            ratio(0xFFFFFF, DS.Colors.dangerHex), 3.0
        )
        XCTAssertGreaterThanOrEqual(
            ratio(0xFFFFFF, DS.Colors.backgroundHex), 4.5
        )
    }

    func testSOSChipBedPairs() {
        let bed = blendBlack(over: DS.Colors.dangerHex, opacity: DS.SOS.chipBedOpacity)
        let pairs: [(UInt32, String)] = [
            (0xFFFFFF, "chip white"),
            (DS.Colors.okHex, "delivery Sent"),
            (DS.Colors.warningHex, "delivery Dry-run"),
        ]
        for (foreground, name) in pairs {
            XCTAssertGreaterThanOrEqual(ratio(foreground, bed), 4.5, name)
        }
    }

    private func blendBlack(over background: UInt32, opacity: Double) -> UInt32 {
        let channels = [
            Double((background >> 16) & 0xFF),
            Double((background >> 8) & 0xFF),
            Double(background & 0xFF),
        ].map { UInt32(($0 * (1 - opacity)).rounded()) }
        return (channels[0] << 16) | (channels[1] << 8) | channels[2]
    }
}
