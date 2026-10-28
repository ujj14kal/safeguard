import SwiftUI
import UIKit

extension DS {
    enum Motion {
        static let smooth = Animation.smooth(duration: 0.4)
        static let snappy = Animation.snappy(duration: 0.28)
        static let lively = Animation.spring(response: 0.5, dampingFraction: 0.82)
    }

    static let cardRadius: CGFloat = 24
}

struct DSCardModifier: ViewModifier {
    var padding: CGFloat = DS.Spacing.medium
    var tint: Color?

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                    .fill(DS.Colors.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                            .strokeBorder((tint ?? .white).opacity(tint == nil ? 0.07 : 0.35), lineWidth: 1)
                    )
            )
    }
}

extension View {
    func dsCard(padding: CGFloat = DS.Spacing.medium, tint: Color? = nil) -> some View {
        modifier(DSCardModifier(padding: padding, tint: tint))
    }

    func tapHaptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) -> some View {
        simultaneousGesture(TapGesture().onEnded {
            UIImpactFeedbackGenerator(style: style).impactOccurred()
        })
    }
}

struct ShimmerModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                if !reduceMotion {
                    GeometryReader { proxy in
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.14), .clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: proxy.size.width * 0.6)
                        .offset(x: phase * proxy.size.width * 1.6)
                    }
                    .allowsHitTesting(false)
                }
            }
            .clipped()
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

extension View {
    func shimmering() -> some View { modifier(ShimmerModifier()) }
}

struct SkeletonBar: View {
    var width: CGFloat? = nil
    var height: CGFloat = 14

    var body: some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(.white.opacity(0.08))
            .frame(width: width, height: height)
            .shimmering()
            .accessibilityHidden(true)
    }
}

struct SkeletonRow: View {
    var body: some View {
        HStack(spacing: DS.Spacing.medium) {
            Circle().fill(.white.opacity(0.08)).frame(width: 40, height: 40).shimmering()
            VStack(alignment: .leading, spacing: 8) {
                SkeletonBar(width: 150)
                SkeletonBar(width: 100, height: 10)
            }
            Spacer()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }
}

struct LoadingScreen: View {
    let title: String
    var subtitle: String?
    var symbol = "shield.fill"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false
    @State private var breathe = false

    var body: some View {
        VStack(spacing: DS.Spacing.large) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.08), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(
                        AngularGradient(
                            colors: [DS.Colors.accent.opacity(0), DS.Colors.accent],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round)
                    )
                    .rotationEffect(.degrees(spinning ? 360 : 0))
                Image(systemName: symbol)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(DS.Colors.accent)
                    .scaleEffect(breathe && !reduceMotion ? 1.06 : 1)
            }
            .frame(width: 96, height: 96)
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding(DS.Spacing.xLarge)
        .accessibilityElement(children: .combine)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                spinning = true
            }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
    }
}

struct StatusPill: View {
    let text: String
    let symbol: String
    let color: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
            .accessibilityElement(children: .combine)
    }
}

struct PulsingDot: View {
    var color: Color = DS.Colors.ok
    var size: CGFloat = 10

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.35))
                .frame(width: size * 2.2, height: size * 2.2)
                .scaleEffect(pulse ? 1 : 0.5)
                .opacity(pulse ? 0 : 0.8)
            Circle().fill(color).frame(width: size, height: size)
        }
        .frame(width: size * 2.2, height: size * 2.2)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.5).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
        .accessibilityHidden(true)
    }
}

struct DSSectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(title)
                .font(.system(.title3, design: .rounded, weight: .semibold))
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityAddTraits(.isHeader)
    }
}
