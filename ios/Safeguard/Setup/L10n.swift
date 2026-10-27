import Foundation
import SwiftUI

/// Localisation helpers. Every key is the full English string (literals
/// are keyed automatically by SwiftUI; formatted strings use these so the
/// key is explicit and stable). Hindi lives in Localizable.xcstrings.
/// Without a strings bundle (unit tests) everything falls back to English.
public enum L10n {
    public static func format(_ key: String, _ args: CVarArg...) -> String {
        format(key, arguments: args)
    }

    public static func format(_ key: String, arguments args: [CVarArg]) -> String {
        String(format: NSLocalizedString(key, comment: ""), arguments: args)
    }
}

public extension Text {
    /// Localised text with format arguments, e.g.
    /// `Text(format: "%d of %d parts", saved, total)`.
    init(format key: String, _ args: CVarArg...) {
        self.init(verbatim: L10n.format(key, arguments: args))
    }
}
