import Foundation

public enum PlateText {
    static let stateCodes: Set<String> = [
        "AN", "AP", "AR", "AS", "BR", "CH", "CG", "DD", "DL", "DN", "GA", "GJ", "HP", "HR", "JH", "JK",
        "KA", "KL", "LA", "LD", "MH", "ML", "MN", "MP", "MZ", "NL", "OD", "OR", "PB", "PY", "RJ", "SK",
        "TN", "TR", "TS", "TG", "UK", "UP", "WB",
    ]

    private static let toLetter: [Character: Character] = ["0": "O", "1": "I", "5": "S", "8": "B", "2": "Z"]
    private static let toDigit: [Character: Character] = [
        "O": "0", "Q": "0", "D": "0", "I": "1", "L": "1", "S": "5", "B": "8", "Z": "2", "G": "6",
    ]

    public static func normalize(_ raw: String) -> String? {
        let compact = raw.uppercased().filter { $0.isLetter || $0.isNumber }
        guard (8...11).contains(compact.count) else { return nil }
        if let bh = normalizeBharat(compact) { return bh }
        var chars = Array(compact)
        for index in 0..<2 { chars[index] = toLetter[chars[index]] ?? chars[index] }
        for index in (chars.count - 4)..<chars.count { chars[index] = toDigit[chars[index]] ?? chars[index] }
        let text = String(chars)
        guard stateCodes.contains(String(text.prefix(2))),
              text.range(of: "^[A-Z]{2}[0-9]{1,2}[A-Z]{1,4}[0-9]{4}$", options: .regularExpression) != nil
        else { return nil }
        return text
    }

    private static func normalizeBharat(_ compact: String) -> String? {
        compact.range(of: "^[0-9]{2}BH[0-9]{4}[A-Z]{2}$", options: .regularExpression) != nil ? compact : nil
    }

    public static func display(_ compact: String) -> String {
        guard compact.range(of: "^[A-Z]{2}[0-9]{1,2}[A-Z]{1,4}[0-9]{4}$", options: .regularExpression) != nil else {
            return compact
        }
        let state = compact.prefix(2)
        let number = compact.suffix(4)
        let middle = Array(compact.dropFirst(2).dropLast(4))
        let digits = middle.prefix { $0.isNumber }
        let letters = middle.dropFirst(digits.count)
        if digits.count == 2 || letters.count <= 2 {
            return "\(state) \(String(digits)) \(String(letters)) \(number)".replacingOccurrences(of: "  ", with: " ")
        }
        let district = String(digits) + String(letters.prefix(1))
        return "\(state) \(district) \(String(letters.dropFirst())) \(number)"
    }
}

public struct PlateEvent: Equatable, Sendable {
    public var compact: String
    public var text: String
    public var rating: String
    public var count: Int
}

public struct PlateTracker: Sendable {
    public var minSeparation: TimeInterval = 1.0
    public var emitAt: Set<Int> = [1, 2, 5]

    private var counts: [String: Int] = [:]
    private var lastSeen: [String: TimeInterval] = [:]

    public init() {}

    public mutating func observe(_ compact: String, at time: TimeInterval) -> PlateEvent? {
        if let last = lastSeen[compact], time - last < minSeparation { return nil }
        lastSeen[compact] = time
        let count = (counts[compact] ?? 0) + 1
        counts[compact] = count
        guard emitAt.contains(count) else { return nil }
        return PlateEvent(
            compact: compact, text: PlateText.display(compact),
            rating: count >= 2 ? "strongly possible" : "possible", count: 1
        )
    }

    public mutating func reset() {
        counts.removeAll()
        lastSeen.removeAll()
    }
}
