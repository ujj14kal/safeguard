import CoreVideo
import Foundation
import Vision

final class PlateScanner {
    private let minimumConfidence: Float = 0.3

    private struct Piece {
        var strings: [String]
        var box: CGRect
    }

    func scan(_ pixelBuffer: CVPixelBuffer) -> [String] {
        scanWithHint(pixelBuffer).plates
    }

    func scanWithHint(_ pixelBuffer: CVPixelBuffer) -> (plates: [String], hint: CGRect?) {
        var result = read(pixelBuffer, region: nil)
        if result.plates.isEmpty {
            let zoomed = read(pixelBuffer, region: CGRect(x: 0.05, y: 0.15, width: 0.9, height: 0.55))
            result = (zoomed.plates, result.hint ?? zoomed.hint)
        }
        return result
    }

    private func read(_ pixelBuffer: CVPixelBuffer, region: CGRect?) -> (plates: [String], hint: CGRect?) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.008
        request.recognitionLanguages = ["en-US"]
        if let region { request.regionOfInterest = region }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        guard (try? handler.perform([request])) != nil else { return ([], nil) }
        let pieces = (request.results ?? []).map { observation in
            Piece(
                strings: observation.topCandidates(6)
                    .filter { $0.confidence >= minimumConfidence }.map(\.string),
                box: observation.boundingBox
            )
        }.filter { !$0.strings.isEmpty }
        let read = plates(in: pieces)
        return (read, read.isEmpty ? fragmentBox(in: pieces, region: region) : nil)
    }

    private func fragmentBox(in pieces: [Piece], region: CGRect?) -> CGRect? {
        for piece in pieces {
            for text in piece.strings {
                let compact = text.uppercased().filter { $0.isLetter || $0.isNumber }
                let digits = compact.filter(\.isNumber).count
                let letters = compact.filter(\.isLetter).count
                guard compact.count >= 4, digits >= 2, letters >= 2 else { continue }
                var box = piece.box
                if let region {
                    box = CGRect(
                        x: region.minX + box.minX * region.width, y: region.minY + box.minY * region.height,
                        width: box.width * region.width, height: box.height * region.height
                    )
                }
                return box
            }
        }
        return nil
    }

    private func plates(in pieces: [Piece]) -> [String] {
        let ordered = pieces.sorted {
            abs($0.box.midY - $1.box.midY) > 0.02 ? $0.box.midY > $1.box.midY : $0.box.minX < $1.box.minX
        }
        var found: [String] = []
        func add(_ plate: String?) {
            if let plate, !found.contains(plate) { found.append(plate) }
        }
        for piece in ordered {
            for text in piece.strings {
                if let plate = PlateText.normalize(text) { add(plate); break }
            }
        }
        for size in 2...3 where ordered.count >= size {
            for start in 0...(ordered.count - size) {
                let group = Array(ordered[start..<(start + size)])
                guard near(group) else { continue }
                var texts = [""]
                for piece in group {
                    texts = texts.flatMap { prefix in piece.strings.prefix(3).map { prefix + $0 } }
                }
                for text in texts {
                    if let plate = PlateText.normalize(text) { add(plate); break }
                }
            }
        }
        return found
    }

    private func near(_ group: [Piece]) -> Bool {
        guard let first = group.first, let last = group.last else { return false }
        let union = group.dropFirst().reduce(first.box) { $0.union($1.box) }
        return union.height < 0.2 && union.width < 0.95 && last.box.minY <= first.box.maxY + 0.05
    }
}
