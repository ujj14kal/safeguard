import CoreVideo
import Foundation
import Vision

final class PlateScanner {
    private let minimumConfidence: Float = 0.4

    func scan(_ pixelBuffer: CVPixelBuffer) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.015
        request.recognitionLanguages = ["en-US"]
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right)
        guard (try? handler.perform([request])) != nil else { return [] }
        var found: [String] = []
        for observation in request.results ?? [] {
            for candidate in observation.topCandidates(3) where candidate.confidence >= minimumConfidence {
                if let plate = PlateText.normalize(candidate.string), !found.contains(plate) {
                    found.append(plate)
                    break
                }
            }
        }
        return found
    }
}
