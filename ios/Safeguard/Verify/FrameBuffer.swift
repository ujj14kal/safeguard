import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// In-memory ring of recent downscaled JPEG frames for backend /verify.
/// Frames live here only and are discarded after use; never written to disk.
/// Thread-safe; typically fed at detection rate (~5 Hz).
public final class FrameBuffer: @unchecked Sendable {
    public let maxFrames: Int
    public let maxPixelSize: Int
    public let jpegQuality: Double

    private static let context = CIContext()

    private let lock = NSLock()
    private var frames: [(time: TimeInterval, jpeg: Data)] = []
    private var latestSize: CGSize = .zero

    public init(maxFrames: Int = 8, maxPixelSize: Int = 512, jpegQuality: Double = 0.7) {
        self.maxFrames = maxFrames
        self.maxPixelSize = maxPixelSize
        self.jpegQuality = jpegQuality
    }

    /// Downscale + JPEG-encode a frame and append it, dropping the oldest.
    public func append(pixelBuffer: CVPixelBuffer, at time: TimeInterval) {
        guard let (jpeg, size) = Self.encode(
            pixelBuffer: pixelBuffer, maxPixelSize: maxPixelSize, quality: jpegQuality
        ) else {
            return
        }
        lock.withLock {
            frames.append((time, jpeg))
            latestSize = size
            if frames.count > maxFrames {
                frames.removeFirst(frames.count - maxFrames)
            }
        }
    }

    /// Oldest-first JPEGs plus their pixel size (for box scaling).
    public func snapshot() -> (frames: [Data], size: CGSize) {
        lock.withLock { (frames.map(\.jpeg), latestSize) }
    }

    public func clear() {
        lock.withLock {
            frames = []
            latestSize = .zero
        }
    }

    /// Downscale the long edge to `maxPixelSize` and JPEG-encode.
    public static func encode(
        pixelBuffer: CVPixelBuffer, maxPixelSize: Int, quality: Double
    ) -> (Data, CGSize)? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let scale = min(1, Double(maxPixelSize) / max(extent.width, extent.height))
        let target = CGSize(
            width: max(1, extent.width * scale), height: max(1, extent.height * scale)
        )
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(scaled, from: CGRect(origin: .zero, size: target))
        else {
            return nil
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(
            destination, cgImage,
            [kCGImageDestinationLossyCompressionQuality as String: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (data as Data, target)
    }
}
