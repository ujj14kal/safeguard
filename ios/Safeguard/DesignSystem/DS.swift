import SwiftUI

enum DS {
    enum Spacing {
        static let small: CGFloat = 8
        static let medium: CGFloat = 16
        static let large: CGFloat = 24
        static let xLarge: CGFloat = 32
    }

    static let cornerRadius: CGFloat = 20

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
        static let accent = Color(hex: accentHex)
        static let buttonFill = Color(hex: buttonFillHex)
        static let brandPurple = Color(hex: brandPurpleHex)
        static let danger = Color(hex: dangerHex)
        static let warning = Color(hex: warningHex)
        static let ok = Color(hex: okHex)

        static func box(for level: Proximity) -> Color {
            switch level {
            case .clear: accent
            case .near: warning
            case .tooClose: danger
            }
        }
    }

    enum SOS {
        static let scrimOpacity: Double = 0.88
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
    @ViewBuilder
    func safeguardPanel() -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: DS.cornerRadius))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.cornerRadius))
        }
    }

    @ViewBuilder
    func safeguardCircle() -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(.regular, in: Circle())
        } else {
            self.background(.regularMaterial, in: Circle())
        }
    }
}
