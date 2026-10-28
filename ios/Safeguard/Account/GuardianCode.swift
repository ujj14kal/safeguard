import Foundation

public enum GuardianCode {
    public static let key = "guardianCode"
    private static let alphabet = Set("ABCDEFGHJKMNPQRSTUVWXYZ23456789")

    public static func normalized(_ raw: String) -> String? {
        let letters = raw.uppercased().filter { $0 != "-" && $0 != " " }
        guard letters.count == 12, letters.allSatisfy({ alphabet.contains($0) }) else { return nil }
        let chars = Array(letters)
        return stride(from: 0, to: 12, by: 4)
            .map { String(chars[$0..<$0 + 4]) }
            .joined(separator: "-")
    }
}
