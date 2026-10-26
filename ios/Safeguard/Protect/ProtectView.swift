import SwiftUI

struct ProtectView: View {
    @StateObject private var model = ProtectViewModel()
    @AppStorage("debugOverlayEnabled") private var debugOverlayEnabled = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.Spacing.large) {
                    ShieldRingView(state: model.state)
                        .padding(.top, DS.Spacing.medium)
                    VStack(spacing: DS.Spacing.small) {
                        Text(model.state.title)
                            .font(.system(.title2, design: .rounded, weight: .bold))
                        Text(model.statusLine)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    previewSection
                    controlsSection
                    if let error = model.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding()
            }
            .navigationTitle("Protect")
            .sheet(isPresented: $model.showingPicker) {
                DocumentPicker { url in model.startReplay(url: url) }
            }
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        Group {
            if let session = model.cameraSession {
                CameraPreviewView(session: session)
            } else if let image = model.replayImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .accessibilityLabel("Replay video frame")
            } else {
                ContentUnavailableView(
                    "No preview", systemImage: "video.slash",
                    description: Text("Start protecting to see the camera feed.")
                )
            }
        }
        .overlay {
            if debugOverlayEnabled {
                DebugBoxOverlay(
                    tracks: model.debugTracks,
                    frameSize: model.debugFrameSize,
                    scores: model.debugScores
                )
            }
        }
        .frame(height: 260)
        .clipShape(RoundedRectangle(cornerRadius: DS.cornerRadius))
    }

    @ViewBuilder
    private var controlsSection: some View {
        VStack(spacing: DS.Spacing.medium) {
            if model.isProtecting {
                Button("Stop protecting", role: .destructive) { model.stop() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Start protecting") { Task { await model.startCamera() } }
                    .buttonStyle(.borderedProminent)
                Button("Replay a video…") { model.showingPicker = true }
                    .buttonStyle(.bordered)
            }
            if model.usingReplay, let name = model.replayName {
                Text("Replay mode: \(name)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    ProtectView()
}
