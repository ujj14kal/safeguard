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
    var steps: [String] = []

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stepIndex = 0

    static var protectionSteps: [String] {
        [
            String(localized: "Warming up the camera"),
            String(localized: "Tuning the microphone"),
            String(localized: "Connecting to Muse"),
            String(localized: "Getting your location"),
        ]
    }

    var body: some View {
        VStack(spacing: DS.Spacing.xLarge) {
            emblem
            VStack(spacing: 10) {
                Text(title)
                    .font(.system(.title2, design: .rounded, weight: .bold))
                if !steps.isEmpty {
                    Text(steps[stepIndex % steps.count])
                        .id(stepIndex)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)
                        ))
                    stepDots
                } else if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .clipped()
        }
        .padding(DS.Spacing.xLarge)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .task(id: steps.count) {
            guard steps.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1300))
                withAnimation(.easeInOut(duration: 0.4)) { stepIndex += 1 }
            }
        }
    }

    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<steps.count, id: \.self) { index in
                Capsule()
                    .fill(index == stepIndex % steps.count ? DS.Colors.accent : .white.opacity(0.18))
                    .frame(width: index == stepIndex % steps.count ? 18 : 6, height: 6)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: stepIndex)
    }

    private var emblem: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<3, id: \.self) { ring in
                    let phase = (t / 2.6 + Double(ring) / 3).truncatingRemainder(dividingBy: 1)
                    Circle()
                        .stroke(DS.Colors.accent.opacity((1 - phase) * 0.4), lineWidth: 2)
                        .scaleEffect(0.5 + phase * 0.9)
                }
                Circle()
                    .fill(RadialGradient(
                        colors: [DS.Colors.accent.opacity(0.28), .clear],
                        center: .center, startRadius: 4, endRadius: 56
                    ))
                    .frame(width: 112, height: 112)
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(
                        AngularGradient(
                            colors: [DS.Colors.accent.opacity(0), DS.Colors.accent],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round)
                    )
                    .frame(width: 92, height: 92)
                    .rotationEffect(.degrees((t * 220).truncatingRemainder(dividingBy: 360)))
                Image(systemName: symbol)
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(DS.Colors.accent)
                    .scaleEffect(1 + 0.05 * sin(t * 2.6))
            }
            .frame(width: 170, height: 170)
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
