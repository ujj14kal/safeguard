import XCTest

/// WCAG contrast for the token pairs actually used. Reads the hexes from
/// DS, so any future token edit that breaks contrast fails here. The math
/// itself is pinned by the black/white known answer (21:1).
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
        // Text needs 4.5:1: accent on background/surface, white on button.
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
        // Icons and borders need 3:1 (status colours + accent on surfaces).
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
        // The HUD box colours are the brief's exact hexes (lilac/yellow/red).
        XCTAssertEqual(DS.Colors.accentHex, 0xB98DD1)
        XCTAssertEqual(DS.Colors.warningHex, 0xFFD23F)
        XCTAssertEqual(DS.Colors.dangerHex, 0xFF4D4D)
    }
}
