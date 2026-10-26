import SwiftUI

struct ProtectView: View {
    @StateObject private var model = ProtectViewModel()
    @AppStorage("debugOverlayEnabled") private var debugOverlayEnabled = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.Spacing.large) {
                    ShieldRingView(state: model.state, proximity: model.proximity)
                        .padding(.top, DS.Spacing.medium)
                    VStack(spacing: DS.Spacing.small) {
                        Text(model.displayTitle)
                            .font(.system(.title2, design: .rounded, weight: .bold))
                        Text(model.statusLine)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let verify = model.lastVerifyResult {
                            Text(verify)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        if let speech = model.lastSpeechInfo {
                            Text(speech)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        if model.listenerLive {
                            Label("Listening", systemImage: "mic.fill")
                                .font(.footnote)
                                .accessibilityLabel("Microphone is listening")
                        } else if model.isProtecting, let deaf = model.listenerDeafReason {
                            Label(deaf, systemImage: "mic.slash.fill")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    previewSection
                    if model.state == .asking {
                        checkInSection
                    }
                    if model.state == .unsafe {
                        sosBanner
                    }
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
            .onTapGesture(count: 2) { model.tapCheckIn() }
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

    /// The spoken question's on-screen equivalent: answer by button,
    /// by code phrase, or by double tap. (Full-screen HUD in Part D.)
    private var checkInSection: some View {
        VStack(spacing: DS.Spacing.medium) {
            Text("No reply in 10 seconds starts the SOS.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("I'm safe") { model.answerSafe() }
                .buttonStyle(.borderedProminent)
            Button("I need help", role: .destructive) { model.answerUnsafe() }
                .buttonStyle(.borderedProminent)
            Text("Or double-tap anywhere to answer \"I'm safe\".")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Are you safe?")
    }

    /// Unsafe records the state and shows it; the four escalation tracks
    /// are Phase 6.
    private var sosBanner: some View {
        Label(
            model.unsafeCause == .noReply ? "No reply — SOS started" : "SOS started",
            systemImage: "sos.circle.fill"
        )
        .font(.headline)
        .foregroundStyle(.red)
        .accessibilityAddTraits(.isHeader)
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
