import CoreGraphics
import CoreText
import CoreVideo
import XCTest
@testable import Safeguard

final class PlateScannerTests: XCTestCase {
    private func frame(lines: [String], fontSize: CGFloat, width: Int = 720, height: Int = 1280) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixels = buffer!
        CVPixelBufferLockBaseAddress(pixels, [])
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixels), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        context.setFillColor(CGColor(gray: 0.35, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 0.85, blue: 0.1, alpha: 1))
        let plateHeight = fontSize * 1.5 * CGFloat(lines.count)
        let plate = CGRect(x: 40, y: CGFloat(height) / 2, width: CGFloat(width) - 80, height: plateHeight)
        context.fill(plate)
        for (index, line) in lines.enumerated() {
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: CGColor(gray: 0, alpha: 1),
            ]
            let text = CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: attributes))
            context.textPosition = CGPoint(x: 60, y: plate.maxY - fontSize * 1.15 - CGFloat(index) * fontSize * 1.5)
            CTLineDraw(text, context)
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        return pixels
    }

    private func scanRotated(_ lines: [String], size: CGFloat) -> [String] {
        PlateScanner().scan(frame(lines: lines, fontSize: size))
    }

    func testReadsAOneLinePlate() {
        XCTAssertEqual(scanRotated(["MH 12 AB 1234"], size: 60), ["MH12AB1234"])
    }

    func testReadsAPlateWithoutSpaces() {
        XCTAssertEqual(scanRotated(["DL3CAB1234"], size: 60), ["DL3CAB1234"])
    }

    func testReadsASmallerPlate() {
        XCTAssertEqual(scanRotated(["KA 01 AB 4321"], size: 34), ["KA01AB4321"])
    }

    func testReadsATwoLinePlate() {
        XCTAssertEqual(scanRotated(["MH 12", "AB 1234"], size: 80), ["MH12AB1234"])
    }

    private func darkFrame(_ lines: [String], size: CGFloat) -> CVPixelBuffer {
        let source = frame(lines: lines, fontSize: size)
        CVPixelBufferLockBaseAddress(source, [])
        let base = CVPixelBufferGetBaseAddress(source)!.assumingMemoryBound(to: UInt8.self)
        let count = CVPixelBufferGetBytesPerRow(source) * CVPixelBufferGetHeight(source)
        for index in 0..<count where index % 4 != 3 { base[index] = UInt8(Double(base[index]) * 0.22) }
        CVPixelBufferUnlockBaseAddress(source, [])
        return source
    }

    func testBrightnessSeparatesDarkFromLitFrames() {
        let lit = frame(lines: ["MH 12 AB 1234"], fontSize: 60)
        let dark = darkFrame(["MH 12 AB 1234"], size: 60)
        XCTAssertGreaterThan(NightVision.averageBrightness(lit), NightVision.brightAbove)
        XCTAssertLessThan(NightVision.averageBrightness(dark), NightVision.darkBelow)
    }

    func testBrighteningLiftsADarkFrame() {
        let dark = darkFrame(["MH 12 AB 1234"], size: 60)
        let lifted = NightVision.brighten(dark)
        XCTAssertGreaterThan(NightVision.averageBrightness(lifted), NightVision.averageBrightness(dark) * 1.8)
    }

    func testReadsADarkPlateAfterBrightening() {
        let dark = darkFrame(["MH 12 AB 1234"], size: 60)
        XCTAssertEqual(PlateScanner().scan(NightVision.brighten(dark)), ["MH12AB1234"])
    }

    func testDarknessTrackerNeedsTwoReadingsAndHasHysteresis() {
        var tracker = DarknessTracker()
        XCTAssertNil(tracker.update(0.1))
        XCTAssertEqual(tracker.update(0.1), true)
        XCTAssertNil(tracker.update(0.25))
        XCTAssertNil(tracker.update(0.25))
        XCTAssertNil(tracker.update(0.4))
        XCTAssertEqual(tracker.update(0.4), false)
    }
}
