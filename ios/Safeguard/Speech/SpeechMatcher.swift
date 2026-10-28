import Foundation

public struct SpeechMatch: Sendable, Equatable {
    public var category: SpeechCategory
    public var severity: Double
    public var wordIndex: Int

    public init(category: SpeechCategory, severity: Double, wordIndex: Int) {
        self.category = category
        self.severity = severity
        self.wordIndex = wordIndex
    }
}

public struct SpeechMatcher: Sendable {
    public let config: SpeechConfig

    private struct Compiled {
        var pattern: SpeechPattern
        var keys: [String]
    }
    private let compiled: [Compiled]

    public init(config: SpeechConfig = SpeechConfig()) {
        self.config = config
        self.compiled = config.patterns.compactMap {
            let keys = SpeechText.words(in: $0.phrase).map(SpeechText.fuzzyKey)
            return keys.isEmpty ? nil : Compiled(pattern: $0, keys: keys)
        }
    }

    public static func backendSeverity(_ level: String) -> Double {
        switch level {
        case "high": 0.9
        case "medium": 0.6
        case "low": 0.15
        default: 0
        }
    }

    public func match(_ transcript: String) -> SpeechMatch? {
        let words = Self.words(in: transcript)
        guard !words.isEmpty else { return nil }
        let benignRanges = benignWordRanges(in: words)
        var best: SpeechMatch?
        var hostileStarts = Set<Int>()
        let keys = words.map(SpeechText.fuzzyKey)
        for entry in compiled {
            let pattern = entry.pattern
            let phrase = entry.keys
            guard words.count >= phrase.count else { continue }
            for start in 0...(words.count - phrase.count) {
                guard keysMatch(keys, at: start, phrase: phrase) else { continue }
                let end = start + phrase.count
                if benignRanges.contains(where: { $0.contains(start) && $0.contains(end - 1) }) {
                    continue
                }
                var severity = pattern.severity
                if isQuoted(transcript, wordIndex: start, words: words) {
                    severity *= config.quotationFactor
                }
                if pattern.category != .distress,
                   isNegated(words, matchStart: start)
                {
                    severity *= config.negationFactor
                }
                let candidate = SpeechMatch(
                    category: pattern.category, severity: severity, wordIndex: start
                )
                if pattern.category == .anger || pattern.category == .abuse
                    || pattern.category == .proposition
                {
                    hostileStarts.insert(start)
                }
                if best == nil || candidate.severity > best!.severity {
                    best = candidate
                }
            }
        }
        if hostileStarts.count >= config.repeatedAngerCount,
           (best?.severity ?? 0) < config.repeatedAngerSeverity
        {
            best = SpeechMatch(
                category: .anger, severity: config.repeatedAngerSeverity,
                wordIndex: best?.wordIndex ?? 0
            )
        }
        return best
    }

    private func benignWordRanges(in words: [String]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        for frame in config.benignPhrases {
            let phrase = Self.words(in: frame)
            guard !phrase.isEmpty, words.count >= phrase.count else { continue }
            for start in 0...(words.count - phrase.count) {
                if wordsMatch(words, at: start, phrase: phrase) {
                    ranges.append(start..<(start + phrase.count))
                }
            }
        }
        return ranges
    }

    private func isWordCharacter(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
    }

    private func isQuoted(_ rawTranscript: String, wordIndex: Int, words: [String]) -> Bool {
        let transcript = SpeechText.normalised(rawTranscript)
        var seen = 0
        var index = transcript.startIndex
        var matchOffset: String.Index?
        while index < transcript.endIndex {
            while index < transcript.endIndex,
                  !isWordCharacter(transcript[index])
            {
                index = transcript.index(after: index)
            }
            let wordStart = index
            while index < transcript.endIndex,
                  isWordCharacter(transcript[index])
            {
                index = transcript.index(after: index)
            }
            if wordStart < index {
                if seen == wordIndex {
                    matchOffset = wordStart
                    break
                }
                seen += 1
            }
        }
        guard let matchOffset else { return false }
        let quotesBefore = transcript[..<matchOffset].filter { $0 == "\"" }.count
        let quotesAfter = transcript[matchOffset...].filter { $0 == "\"" }.count
        return quotesBefore % 2 == 1 && quotesAfter >= 1
    }

    private func isNegated(_ words: [String], matchStart: Int) -> Bool {
        for raw in config.negationPhrases {
            let phrase = Self.words(in: raw)
            guard !phrase.isEmpty else { continue }
            let lower = max(phrase.count, matchStart - config.negationDistance)
            guard lower <= matchStart else { continue }
            for end in lower...matchStart {
                let start = end - phrase.count
                guard start >= 0 else { continue }
                if wordsMatch(words, at: start, phrase: phrase) {
                    return true
                }
            }
        }
        return false
    }

    private func keysMatch(_ keys: [String], at start: Int, phrase: [String]) -> Bool {
        guard start >= 0, start + phrase.count <= keys.count else { return false }
        for offset in phrase.indices where !SpeechText.keysEqual(keys[start + offset], phrase[offset]) {
            return false
        }
        return true
    }

    private func wordsMatch(_ words: [String], at start: Int, phrase: [String]) -> Bool {
        guard start >= 0, start + phrase.count <= words.count else { return false }
        return zip(words[start..<(start + phrase.count)], phrase).allSatisfy {
            SpeechText.wordsEqual($0, $1)
        }
    }

    private static func words(in text: String) -> [String] {
        SpeechText.words(in: text)
    }
}

public struct SpeechVerifyGate: Sendable {
    private let triggerSeverity: Double
    private let minInterval: TimeInterval
    private var lastFire: TimeInterval?

    public init(triggerSeverity: Double, minInterval: TimeInterval = 30) {
        self.triggerSeverity = triggerSeverity
        self.minInterval = minInterval
    }

    public mutating func consume(severity: Double, at time: TimeInterval) -> Bool {
        guard severity >= triggerSeverity else { return false }
        if let last = lastFire, time - last < minInterval {
            return false
        }
        lastFire = time
        return true
    }

    public mutating func reset() {
        lastFire = nil
    }
}
