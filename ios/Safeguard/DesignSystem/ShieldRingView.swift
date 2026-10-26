import SwiftUI

/// Signature status ring. Breathes gently while protecting; colour, symbol and
/// text always change together (never colour alone). Honours Reduce Motion.
struct ShieldRingView: View {
    let state: ProtectionState
    var proximity: Proximity = .clear
    var size: CGFloat = 148

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    /// While protecting, the ring shows proximity (teal/yellow/red); other
    /// states keep their own treatment. Red `tooClose` is a warning triangle,
    /// never the SOS circle.
    private var ringColor: Color {
        if state.isProtecting {
            switch proximity {
            case .clear: return .teal
            case .near: return .yellow
            case .tooClose: return .red
            }
        }
        return state.color
    }

    private var symbolName: String {
        state.isProtecting ? proximity.symbolName : state.symbolName
    }

    private var voiceOverLabel: String {
        if state.isProtecting, proximity != .clear {
            return "Status: \(proximity.title)"
        }
        return "Status: \(state.title)"
    }

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(ringColor, lineWidth: 10)
                .frame(width: size, height: size)
                .scaleEffect(breathing && state.isProtecting && !reduceMotion ? 1.04 : 1.0)
            Image(systemName: symbolName)
                .font(.system(size: size * 0.34, weight: .semibold))
                .foregroundStyle(ringColor)
                .symbolEffect(
                    .pulse, options: .repeating,
                    isActive: state == .suspected && !reduceMotion
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(voiceOverLabel)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
    }
}

#Preview {
    VStack(spacing: 24) {
        ShieldRingView(state: .monitoring)
        ShieldRingView(state: .suspected)
        ShieldRingView(state: .unsafe)
    }
    .padding()
}
