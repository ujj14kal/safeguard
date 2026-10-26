import Foundation

/// What the matcher found. The range points into the caller's window text —
/// no matched text is copied out or kept beyond the window.
public struct SpeechMatch: Sendable, Equatable {
    public var category: SpeechCategory
    /// 0...1 after quotation/negation guards.
    public var severity: Double
    /// Word index of the first matched word in the scanned transcript.
    public var wordIndex: Int

    public init(category: SpeechCategory, severity: Double, wordIndex: Int) {
        self.category = category
        self.severity = severity
        self.wordIndex = wordIndex
    }
}

/// On-device threat/harassment/coercion matcher over transcript text. Pure:
/// whole-word, case-insensitive, with quotation, negation and benign-frame
/// guards. Returns the strongest match, if any.
public struct SpeechMatcher: Sendable {
    public let config: SpeechConfig

    public init(config: SpeechConfig = SpeechConfig()) {
        self.config = config
    }

    /// Maps a /verify-speech severity onto the 0...1 machine input.
    /// Backend `low` lands below the strong threshold (a downgrade, not a
    /// trigger); unknown strings map to 0 — dropped, never trusted.
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
        for pattern in config.patterns {
            let phrase = Self.words(in: pattern.phrase)
            guard !phrase.isEmpty, words.count >= phrase.count else { continue }
            for start in 0...(words.count - phrase.count) {
                guard wordsMatch(words, at: start, phrase: phrase) else { continue }
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
                if best == nil || candidate.severity > best!.severity {
                    best = candidate
                }
            }
        }
        return best
    }

    // MARK: - Guards

    /// Word ranges covered by benign frames ("killing time").
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

    /// True when the matched word sits inside double quotes. Single quotes
    /// are skipped: apostrophes ("don't") would false-positive.
    private func isQuoted(_ transcript: String, wordIndex: Int, words: [String]) -> Bool {
        // Map the word index back to a string offset by re-walking the
        // transcript with the same tokenization the matcher used.
        var seen = 0
        var index = transcript.startIndex
        var matchOffset: String.Index?
        while index < transcript.endIndex {
            // Skip separators.
            while index < transcript.endIndex,
                  !"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
                      .contains(transcript[index])
            {
                index = transcript.index(after: index)
            }
            let wordStart = index
            while index < transcript.endIndex,
                  "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
                      .contains(transcript[index])
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

    /// True when a negation phrase ends within `negationDistance` words
    /// before the match.
    private func isNegated(_ words: [String], matchStart: Int) -> Bool {
        for raw in config.negationPhrases {
            let phrase = Self.words(in: raw)
            guard !phrase.isEmpty else { continue }
            // The negation must END at most `negationDistance` words before
            // the match starts.
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

    private func wordsMatch(_ words: [String], at start: Int, phrase: [String]) -> Bool {
        guard start >= 0, start + phrase.count <= words.count else { return false }
        return words[start..<(start + phrase.count)].elementsEqual(phrase)
    }

    private static func words(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}

/// Edge-triggered /verify-speech gate: fires on strong severities, at most
/// once per `minInterval`, so a continuous rant sends one snippet and only
/// refires with fresh speech. The view model builds it with
/// `SafetyConfig.speechStrongThreshold` so "strong" has one definition.
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
