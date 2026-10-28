import Foundation

public struct TranscriptWindow: Sendable {
    public struct Segment: Sendable, Equatable {
        public var text: String
        public var at: TimeInterval

        public init(text: String, at time: TimeInterval) {
            self.text = text
            self.at = time
        }
    }

    private var segments: [Segment] = []
    private let windowSeconds: TimeInterval

    public init(windowSeconds: TimeInterval = 20) {
        self.windowSeconds = windowSeconds
    }

    public mutating func append(_ text: String, at time: TimeInterval) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        segments.append(Segment(text: trimmed, at: time))
        prune(before: time - windowSeconds)
    }

    public mutating func clear() {
        segments.removeAll()
    }

    public var isEmpty: Bool { segments.isEmpty }

    public var transcript: String {
        segments.map(\.text).joined(separator: " ")
    }

    public func tail(maxChars: Int = 400) -> String {
        let text = transcript
        guard text.count > maxChars, maxChars > 0 else { return text }
        let cut = String(text.suffix(maxChars))
        if let space = cut.firstIndex(of: " ") {
            return String(cut[cut.index(after: space)...])
        }
        return cut
    }

    public func snippet(matchWordIndex: Int, maxChars: Int = 400) -> String {
        let text = transcript
        guard !text.isEmpty, maxChars > 0 else { return "" }
        guard let matchRange = wordRange(at: matchWordIndex, in: text) else {
            return String(text.suffix(maxChars))
        }
        let sentence = sentenceRange(around: matchRange, in: text)
        let sentenceText = text[sentence]
        let snippet: String
        if sentenceText.count > maxChars {
            var start = text.index(
                matchRange.lowerBound, offsetBy: -(maxChars / 2),
                limitedBy: sentence.lowerBound
            ) ?? sentence.lowerBound
            let end = text.index(start, offsetBy: maxChars, limitedBy: sentence.upperBound)
                ?? sentence.upperBound
            if end == sentence.upperBound {
                start = text.index(end, offsetBy: -maxChars, limitedBy: sentence.lowerBound)
                    ?? sentence.lowerBound
            }
            snippet = String(text[start..<end])
        } else if sentenceText.count < maxChars, text.count > sentenceText.count {
            let pad = (maxChars - sentenceText.count) / 2
            let start = text.index(sentence.lowerBound, offsetBy: -pad, limitedBy: text.startIndex)
                ?? text.startIndex
            let end = text.index(sentence.upperBound, offsetBy: pad, limitedBy: text.endIndex)
                ?? text.endIndex
            var padded = String(text[start..<end])
            if padded.count > maxChars {
                padded = String(padded.prefix(maxChars))
            }
            snippet = padded
        } else {
            snippet = String(sentenceText)
        }
        return snippet
    }

    private mutating func prune(before cutoff: TimeInterval) {
        segments.removeAll { $0.at < cutoff }
    }

    private func wordRange(at target: Int, in text: String) -> Range<String.Index>? {
        var seen = 0
        var index = text.startIndex
        while index < text.endIndex {
            while index < text.endIndex, !text[index].isLetter, !text[index].isNumber {
                index = text.index(after: index)
            }
            let start = index
            while index < text.endIndex, text[index].isLetter || text[index].isNumber {
                index = text.index(after: index)
            }
            if start < index {
                if seen == target {
                    return start..<index
                }
                seen += 1
            }
        }
        return nil
    }

    private func sentenceRange(
        around range: Range<String.Index>, in text: String
    ) -> Range<String.Index> {
        let stops: Set<Character> = [".", "!", "?"]
        var start = range.lowerBound
        while start > text.startIndex {
            let prev = text.index(before: start)
            if stops.contains(text[prev]) {
                break
            }
            start = prev
        }
        var end = range.upperBound
        while end < text.endIndex {
            let char = text[end]
            end = text.index(after: end)
            if stops.contains(char) {
                break
            }
        }
        return start..<end
    }
}
