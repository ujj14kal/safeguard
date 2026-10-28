import SwiftUI

struct ShieldRingView: View {
    let state: ProtectionState
    var proximity: Proximity = .clear
    var size: CGFloat = 148

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

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
            return L10n.format("Status: %@", proximity.title)
        }
        return L10n.format("Status: %@", state.title)
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
