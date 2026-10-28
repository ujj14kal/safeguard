import Foundation
import SwiftUI

public enum L10n {
    public static func format(_ key: String, _ args: CVarArg...) -> String {
        format(key, arguments: args)
    }

    public static func format(_ key: String, arguments args: [CVarArg]) -> String {
        String(format: NSLocalizedString(key, comment: ""), arguments: args)
    }
}

public extension Text {
    init(format key: String, _ args: CVarArg...) {
        self.init(verbatim: L10n.format(key, arguments: args))
    }
}
