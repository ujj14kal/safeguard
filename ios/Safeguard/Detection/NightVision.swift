import CoreImage
import CoreVideo
import Foundation

enum NightVision {
    static let darkBelow = 0.20
    static let brightAbove = 0.28

    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func averageBrightness(_ pixelBuffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA
        else { return 1 }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let steps = 24
        var total = 0.0
        var count = 0.0
        for row in 0..<steps {
            let y = (row * 2 + 1) * height / (steps * 2)
            let line = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for column in 0..<steps {
                let x = (column * 2 + 1) * width / (steps * 2)
                let pixel = line.advanced(by: x * 4)
                total += (0.114 * Double(pixel[0]) + 0.587 * Double(pixel[1]) + 0.299 * Double(pixel[2])) / 255
                count += 1
            }
        }
        return count > 0 ? total / count : 1
    }

    static func brighten(_ source: CVPixelBuffer) -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        var output: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &output)
        guard let output else { return source }
        let image = CIImage(cvPixelBuffer: source)
            .applyingFilter("CIGammaAdjust", parameters: ["inputPower": 0.45])
            .applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: 0.08, kCIInputContrastKey: 1.35,
            ])
        context.render(image, to: output)
        return output
    }
}

struct DarknessTracker {
    private(set) var isDark = false
    private var streak = 0

    mutating func update(_ brightness: Double) -> Bool? {
        let wantsDark = isDark ? brightness < NightVision.brightAbove : brightness < NightVision.darkBelow
        if wantsDark != isDark {
            streak += 1
            if streak >= 2 {
                isDark = wantsDark
                streak = 0
                return isDark
            }
        } else {
            streak = 0
        }
        return nil
    }
}
