import Foundation

/// A guardian code: three groups of four letters and digits
/// (XXXX-XXXX-XXXX, no 0/O/1/I/L). The guardian holds it; the person they
/// watch over enters it at sign-up or in Settings.
public enum GuardianCode {
    public static let key = "guardianCode"
    private static let alphabet = Set("ABCDEFGHJKMNPQRSTUVWXYZ23456789")

    /// The code in its canonical form, or nil when it cannot be a code.
    /// Spaces, dashes and case are forgiven.
    public static func normalized(_ raw: String) -> String? {
        let letters = raw.uppercased().filter { $0 != "-" && $0 != " " }
        guard letters.count == 12, letters.allSatisfy({ alphabet.contains($0) }) else { return nil }
        let chars = Array(letters)
        return stride(from: 0, to: 12, by: 4)
            .map { String(chars[$0..<$0 + 4]) }
            .joined(separator: "-")
    }
}
