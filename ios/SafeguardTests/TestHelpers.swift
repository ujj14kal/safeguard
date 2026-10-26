import CoreVideo
import Foundation
import XCTest

/// Shared test helpers. Compiled into the Xcode test target and into the
/// macOS verification harness (same files, same assertions).
enum TestHelpers {
    /// Solid-fill BGRA pixel buffer.
    static func makePixelBuffer(
        width: Int = 640, height: Int = 480, fill: UInt8 = 0
    ) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer))
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for row in 0..<height {
            memset(base.advanced(by: row * bytesPerRow), Int32(fill), width * 4)
        }
        return pixelBuffer
    }

    /// Deterministic pseudo-random noise buffer (fixed seed).
    static func makeNoiseBuffer(
        width: Int = 320, height: Int = 240, seed: UInt64 = 42
    ) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        var bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer))
            .assumingMemoryBound(to: UInt8.self)
        var state = seed
        for _ in 0..<(height * CVPixelBufferGetBytesPerRow(pixelBuffer)) {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            bytes.pointee = UInt8(truncatingIfNeeded: state >> 33)
            bytes = bytes.advanced(by: 1)
        }
        return pixelBuffer
    }
}
