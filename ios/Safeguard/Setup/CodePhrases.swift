import Foundation

/// Code-phrase editing: the wearer may replace each default with one
/// phrase of their own. Matching stays language-independent (word
/// sequences, any script).
public enum CodePhraseValidation: Sendable {
    public enum Failure: String, Sendable, Equatable {
        case tooShort
        case same
        case containsOther
        case isDistressWord
    }

    /// Validates a (safe, unsafe) pair. Each needs at least 2 words, they
    /// must differ, neither may contain the other, and neither may be a
    /// distress word (that would SOS instead of answering).
    public static func validate(
        safe: String, unsafe: String,
        distressWords: [String] = SafetyConfig().distressWords
    ) -> [Failure] {
        let safeWords = words(in: safe)
        let unsafeWords = words(in: unsafe)
        var failures: [Failure] = []
        if safeWords.count < 2 || unsafeWords.count < 2 {
            failures.append(.tooShort)
        }
        if !safeWords.isEmpty, safeWords == unsafeWords {
            failures.append(.same)
        }
        if contains(words: safeWords, phrase: unsafeWords)
            || contains(words: unsafeWords, phrase: safeWords)
        {
            failures.append(.containsOther)
        }
        let distress = Set(distressWords.map { $0.lowercased() })
        if distress.contains(safeWords.joined(separator: " "))
            || distress.contains(unsafeWords.joined(separator: " "))
        {
            failures.append(.isDistressWord)
        }
        return failures
    }

    public static func words(in text: String) -> [String] {
        SpeechText.words(in: text)
    }

    private static func contains(words: [String], phrase: [String]) -> Bool {
        guard !phrase.isEmpty, words.count >= phrase.count else { return false }
        return (0...(words.count - phrase.count)).contains { start in
            words[start..<(start + phrase.count)].elementsEqual(phrase)
        }
    }
}

/// The wearer's custom phrases (UserDefaults). Empty = keep the built-in
/// defaults. `effective` is what the matcher actually uses.
public enum CodePhraseStore {
    public static let safeKey = "customSafePhrase"
    public static let unsafeKey = "customUnsafePhrase"

    public static var customSafe: String {
        get { UserDefaults.standard.string(forKey: safeKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: safeKey) }
    }

    public static var customUnsafe: String {
        get { UserDefaults.standard.string(forKey: unsafeKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: unsafeKey) }
    }

    public static func effectiveSafe() -> [String] {
        let custom = customSafe.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return [custom] }
        return SafetyConfig().safePhrases
    }

    public static func effectiveUnsafe() -> [String] {
        let custom = customUnsafe.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return [custom] }
        return SafetyConfig().unsafePhrases
    }
}
