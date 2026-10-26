import SwiftUI

/// Debug overlay: tracked boxes + IDs over the preview. Vision boxes are
/// normalized with origin lower-left; this view maps them onto the
/// aspect-fill preview given the source frame size in pixels.
struct DebugBoxOverlay: View {
    let tracks: [Track]
    let frameSize: CGSize
    let scores: [Int: Double]

    var body: some View {
        GeometryReader { geometry in
            ForEach(tracks, id: \.id) { track in
                let rect = boxRect(track.box, frame: frameSize, view: geometry.size)
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .stroke(Color.teal, lineWidth: 2)
                        .frame(width: rect.width, height: rect.height)
                    Text(label(for: track.id))
                        .font(.caption2)
                        .bold()
                        .foregroundStyle(.white)
                        .padding(2)
                        .background(Color.teal, in: RoundedRectangle(cornerRadius: 4))
                }
                .position(x: rect.midX, y: rect.midY)
            }
        }
        .accessibilityHidden(true)
    }

    private func label(for id: Int) -> String {
        if let score = scores[id] {
            return String(format: "#%d %.2f", id, score)
        }
        return "#\(id)"
    }

    private func boxRect(_ box: CGRect, frame: CGSize, view: CGSize) -> CGRect {
        guard frame.width > 0, frame.height > 0, view.width > 0, view.height > 0 else {
            return .zero
        }
        let scale = max(view.width / frame.width, view.height / frame.height)
        let scaled = CGSize(width: frame.width * scale, height: frame.height * scale)
        let dx = (view.width - scaled.width) / 2
        let dy = (view.height - scaled.height) / 2
        return CGRect(
            x: dx + box.minX * scaled.width,
            y: dy + (1 - box.maxY) * scaled.height,
            width: box.width * scaled.width,
            height: box.height * scaled.height
        )
    }
}
