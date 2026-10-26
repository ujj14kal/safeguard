import SwiftUI

/// Safeguard design tokens. System components first; these tokens cover
/// spacing, corner radius, and the one signature panel treatment.
enum DS {
    enum Spacing {
        static let small: CGFloat = 8
        static let medium: CGFloat = 16
        static let large: CGFloat = 24
        static let xLarge: CGFloat = 32
    }

    static let cornerRadius: CGFloat = 20
}

extension View {
    /// Floating panel over camera/map: Liquid Glass on iOS 26+, system material below.
    /// Never fakes glass with custom blurs.
    @ViewBuilder
    func safeguardPanel() -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: DS.cornerRadius))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.cornerRadius))
        }
    }
}
