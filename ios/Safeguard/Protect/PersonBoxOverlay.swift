import SwiftUI

/// HUD person overlay: corner brackets + a short label per tracked person,
/// always visible while protecting. Scores and ids join the label only with
/// Settings > Debug > Detection overlay on. Lightweight shapes, no per-frame
/// allocations beyond the view tree itself.
struct PersonBoxOverlay: View {
    let tracks: [Track]
    let frameSize: CGSize
    let scores: [Int: Double]
    let config: ThreatConfig
    @AppStorage("debugOverlayEnabled") private var debugDetails = Defaults.debugOverlayDefault

    var body: some View {
        GeometryReader { geometry in
            ForEach(tracks, id: \.id) { track in
                let rect = AspectFillMapper.boxRect(track.box, frame: frameSize, view: geometry.size)
                let score = scores[track.id] ?? 0
                let level = PersonBoxLevel.level(
                    alert: score >= config.alertThreshold,
                    height: Double(track.box.height),
                    config: config
                )
                ZStack(alignment: .topLeading) {
                    BracketShape()
                        .stroke(DS.Colors.box(for: level), lineWidth: 3)
                        .frame(width: rect.width, height: rect.height)
                    boxLabel(level: level, trackID: track.id, score: score)
                    if let text = cueText(track) {
                        Text(text)
                            .font(.caption2)
                            .bold()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(DS.Colors.danger.opacity(0.85), in: Capsule())
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                            .padding(4)
                    }
                }
                .position(x: rect.midX, y: rect.midY)
            }
        }
        .accessibilityHidden(true)
    }

    /// A hostile hand gesture is always shown (it is what the wearer needs
    /// to see); gestures and expressions in general only with the debug
    /// overlay on.
    private func cueText(_ track: Track) -> String? {
        guard let cues = track.cues else { return nil }
        var parts: [String] = []
        if let hostile = cues.gestures.first(where: { $0.isHostile && $0.score >= config.gestureMinScore }) {
            parts.append(String(localized: "Rude gesture") + (debugDetails ? String(format: " %.2f", hostile.score) : ""))
        }
        if debugDetails {
            for gesture in cues.gestures where !gesture.isHostile && gesture.kind != .other {
                parts.append(gesture.kind.rawValue)
            }
            if let expression = cues.expression, expression.kind != .neutral {
                parts.append(String(format: "%@ %.2f", expression.kind.rawValue, expression.score))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    @ViewBuilder
    private func boxLabel(level: Proximity, trackID: Int, score: Double) -> some View {
        if debugDetails {
            Text(String(format: "#%d %.2f", trackID, score))
                .font(.caption2)
                .bold()
                .foregroundStyle(.white)
                .padding(2)
                .background(DS.Colors.box(for: level), in: RoundedRectangle(cornerRadius: 4))
        } else if level != .clear {
            Text(level.title)
                .font(.caption2)
                .bold()
                .foregroundStyle(.white)
                .padding(2)
                .background(DS.Colors.box(for: level), in: RoundedRectangle(cornerRadius: 4))
        }
    }
}

/// Corner brackets (not a full rectangle): four L-corners with short arms.
struct BracketShape: Shape {
    var armFraction: CGFloat = 0.25

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let armX = min(rect.width * armFraction, 28)
        let armY = min(rect.height * armFraction, 28)
        // Shape space is top-left (y grows downward).
        let left = rect.minX
        let right = rect.maxX
        let top = rect.minY
        let bottom = rect.maxY
        // Top-left.
        path.move(to: CGPoint(x: left, y: top + armY))
        path.addLine(to: CGPoint(x: left, y: top))
        path.addLine(to: CGPoint(x: left + armX, y: top))
        // Top-right.
        path.move(to: CGPoint(x: right - armX, y: top))
        path.addLine(to: CGPoint(x: right, y: top))
        path.addLine(to: CGPoint(x: right, y: top + armY))
        // Bottom-right.
        path.move(to: CGPoint(x: right, y: bottom - armY))
        path.addLine(to: CGPoint(x: right, y: bottom))
        path.addLine(to: CGPoint(x: right - armX, y: bottom))
        // Bottom-left.
        path.move(to: CGPoint(x: left + armX, y: bottom))
        path.addLine(to: CGPoint(x: left, y: bottom))
        path.addLine(to: CGPoint(x: left, y: bottom - armY))
        return path
    }
}

/// Soft red glow along the screen edges while any box is red: obvious in
/// the corner of the eye, no hard flashing, static when Reduce Motion is on.
struct RedVignette: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bright = false

    var body: some View {
        RoundedRectangle(cornerRadius: 24)
            .stroke(DS.Colors.danger, lineWidth: 14)
            .blur(radius: 16)
            .opacity(reduceMotion ? 0.7 : (bright ? 0.85 : 0.45))
            .padding(-8)
            .accessibilityHidden(true)
            .onAppear {
                if reduceMotion {
                    bright = true
                } else {
                    withAnimation(
                        .easeInOut(duration: 1.2).repeatForever(autoreverses: true)
                    ) {
                        bright = true
                    }
                }
            }
    }
}
