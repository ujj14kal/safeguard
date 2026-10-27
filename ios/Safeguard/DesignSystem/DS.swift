import SwiftUI

/// Safeguard design tokens. System components first; these tokens cover
/// spacing, corner radius, the dark-purple palette, and the one signature
/// panel treatment. No hex values outside this file.
enum DS {
    enum Spacing {
        static let small: CGFloat = 8
        static let medium: CGFloat = 16
        static let large: CGFloat = 24
        static let xLarge: CGFloat = 32
    }

    static let cornerRadius: CGFloat = 20

    /// Dark theme (forced app-wide). Hexes are the source of truth the
    /// contrast test reads; the Colors are what views use.
    enum Colors {
        static let backgroundHex: UInt32 = 0x0D0A12
        static let surfaceHex: UInt32 = 0x1A1422
        static let surfaceElevatedHex: UInt32 = 0x241B2E
        static let accentHex: UInt32 = 0xB98DD1
        static let buttonFillHex: UInt32 = 0x8E52A3
        static let brandPurpleHex: UInt32 = 0x6F3A7C
        static let dangerHex: UInt32 = 0xFF4D4D
        static let warningHex: UInt32 = 0xFFD23F
        static let okHex: UInt32 = 0x3DDBC4

        static let background = Color(hex: backgroundHex)
        static let surface = Color(hex: surfaceHex)
        static let surfaceElevated = Color(hex: surfaceElevatedHex)
        /// Text and icons on dark (7.3:1 on the background).
        static let accent = Color(hex: accentHex)
        /// Primary button fill (white text 5.4:1).
        static let buttonFill = Color(hex: buttonFillHex)
        /// Icon and splash only (matches the app icon).
        static let brandPurple = Color(hex: brandPurpleHex)
        static let danger = Color(hex: dangerHex)
        static let warning = Color(hex: warningHex)
        /// Clear/ok status.
        static let ok = Color(hex: okHex)

        /// Person-box colour by proximity level (HUD overlay).
        static func box(for level: Proximity) -> Color {
            switch level {
            case .clear: accent
            case .near: warning
            case .tooClose: danger
            }
        }
    }

    /// SOS scrim translucency. The contrast test blends these exact
    /// opacities over the danger token, so edits here re-verify.
    enum SOS {
        /// Red scrim over the live camera (danger-dominated at 88%).
        static let scrimOpacity: Double = 0.88
        /// Black chip bed over the scrim (solid black with Reduce
        /// Transparency, which only raises contrast).
        static let chipBedOpacity: Double = 0.45
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
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

    /// Circular sibling of `safeguardPanel` (icon buttons).
    @ViewBuilder
    func safeguardCircle() -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(.regular, in: Circle())
        } else {
            self.background(.regularMaterial, in: Circle())
        }
    }
}
