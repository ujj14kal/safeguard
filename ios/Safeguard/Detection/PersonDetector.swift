import CoreVideo
import ImageIO
import Vision

/// On-device person detector (Apple Vision human rectangles). Behaviour-only
/// pipeline: boxes out, no identity, no face recognition. Synchronous; call
/// off the main thread. Orientation defaults to `.up`; chest-mount framing
/// is tuned against real footage in Phase 8.
public final class PersonDetector {
    public init() {}

    public func detect(
        in pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation = .up
    ) throws -> [DetectedPerson] {
        let request = VNDetectHumanRectanglesRequest()
        #if targetEnvironment(simulator)
            // The Simulator has no usable GPU/Neural Engine path for Vision and
            // fails with "Could not create inference context". Devices are unaffected.
            request.usesCPUOnly = true
        #endif
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:]
        )
        try handler.perform([request])
        guard let results = request.results else { return [] }
        return results.map {
            DetectedPerson(box: $0.boundingBox, confidence: $0.confidence)
        }
    }
}
