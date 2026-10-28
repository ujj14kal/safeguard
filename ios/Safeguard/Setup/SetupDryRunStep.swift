import SwiftUI

struct SetupDryRunStep: View {
    @StateObject private var model = ProtectViewModel.shared
    @State private var running = false
    @State private var preview: String?
    @State private var failed = false
    @Binding var seen: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.medium) {
            Text("Try a sample SOS")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
            Text("This runs a SAMPLE SOS: no real message, no recording, no location sent. You will see the red screen, the four track chips and exactly the text your contacts would receive.")
                .foregroundStyle(.secondary)
            if !seen {
                Button(running ? String(localized: "Running sample...") : String(localized: "Run sample SOS")) {
                    run()
                }
                .buttonStyle(.borderedProminent)
                .minTouchTarget()
                .disabled(running)
            }
            if running {
                ProgressView()
            }
            if let preview {
                sampleCard(preview)
            } else if failed {
                Label(
                    "Couldn't reach the backend, so there is no exact text to show. The real SOS retries automatically when offline.",
                    systemImage: "wifi.exclamationmark"
                )
                .font(.footnote)
                .foregroundStyle(DS.Colors.warning)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func run() {
        guard !running else { return }
        running = true
        failed = false
        Task {
            let text = await model.runSampleSOS()
            await MainActor.run {
                running = false
                preview = text
                failed = text == nil
                seen = true
            }
        }
    }

    private func sampleCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            Label("SAMPLE SOS — nothing was sent", systemImage: "sos.circle.fill")
                .font(.headline)
                .foregroundStyle(.white)
            HStack(spacing: DS.Spacing.small) {
                ForEach(EscalationTrack.allCases, id: \.self) { track in
                    Text(track.title)
                        .font(.footnote.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.45))
                        .clipShape(Capsule())
                        .foregroundStyle(.white)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Sample tracks: route, contacts, live stream, cab")
            Text("Your contacts would receive:")
                .font(.footnote)
                .foregroundStyle(.white)
            Text(verbatim: text)
                .font(.body)
                .foregroundStyle(.white)
                .padding(10)
                .background(.black.opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding()
        .background(.black.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: DS.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: DS.cornerRadius)
                .stroke(DS.Colors.danger, lineWidth: 2)
        )
        .accessibilityElement(children: .combine)
    }
}
