import SwiftUI

/// Signature status ring. Breathes gently while protecting; colour, symbol and
/// text always change together (never colour alone). Honours Reduce Motion.
struct ShieldRingView: View {
    let state: ProtectionState
    var size: CGFloat = 148

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(state.color, lineWidth: 10)
                .frame(width: size, height: size)
                .scaleEffect(breathing && state.isProtecting && !reduceMotion ? 1.04 : 1.0)
            Image(systemName: state.symbolName)
                .font(.system(size: size * 0.34, weight: .semibold))
                .foregroundStyle(state.color)
                .symbolEffect(
                    .pulse, options: .repeating,
                    isActive: state == .suspected && !reduceMotion
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status: \(state.title)")
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
