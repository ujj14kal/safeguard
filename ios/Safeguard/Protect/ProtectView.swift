import SwiftUI

struct ProtectView: View {
    @StateObject private var model = ProtectViewModel.shared
    @AppStorage("debugOverlayEnabled") private var debugOverlay = false
    @AppStorage("listenerOptIn") private var listenerOptIn = false

    var body: some View {
        if model.isProtecting {
            hudView
        } else {
            idleView
        }
    }

    // MARK: - HUD (protecting): full-screen camera plus light chrome

    private var hudView: some View {
        ZStack {
            hudPreview
                .ignoresSafeArea()
            PersonBoxOverlay(
                tracks: model.debugTracks,
                frameSize: model.debugFrameSize,
                scores: model.debugScores,
                config: model.threatConfig
            )
            .ignoresSafeArea()
            if model.hasRedBox || model.conversationFlag != nil || model.state == .countdown {
                RedVignette()
                    .ignoresSafeArea()
            }
            VStack(spacing: 0) {
                hudTopBar
                if let toast = model.toast {
                    toastBubble(toast)
                        .padding(.top, DS.Spacing.small)
                }
                if let failure = model.verifyFailure {
                    Text(failure.message)
                        .font(.footnote)
                        .foregroundStyle(DS.Colors.warning)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                        .padding(.top, DS.Spacing.small)
                }
                Spacer()
                if model.state == .asking {
                    checkInCard
                }
                if model.state == .countdown {
                    countdownCard
                } else if let flag = model.conversationFlag {
                    flagCard(flag)
                }
                if let cue = model.listeningCue {
                    hudCue(cue)
                }
                hudBottomBar
            }
            if model.state == .unsafe {
                sosScrim
            }
            if model.dimmed {
                dimOverlay
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .onTapGesture(count: 2) { model.tapCheckIn() }
    }

    /// Near-black battery saver: the camera keeps running underneath.
    /// Anything needing the wearer's eyes lifts it automatically; tapping
    /// anywhere or the brighten button lifts it by hand.
    private var dimOverlay: some View {
        ZStack {
            Color.black.opacity(0.93)
                .ignoresSafeArea()
                .onTapGesture { model.dimmed = false }
            VStack(spacing: DS.Spacing.small) {
                Text(model.hudStatus.text)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.5))
                Button {} label: {
                    Image(systemName: "sun.max.fill")
                        .accessibilityLabel("Brighten the screen")
                }
                .buttonStyle(IconButtonStyle())
            }
        }
    }

    @ViewBuilder
    private var hudPreview: some View {
        if let session = model.cameraSession {
            CameraPreviewView(session: session)
        } else if let image = model.replayImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Replay video frame")
        } else {
            DS.Colors.background
        }
    }

    /// Brief on-screen feedback for voice actions (HUD and idle alike).
    private func toastBubble(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .padding(.horizontal, DS.Spacing.medium)
            .padding(.vertical, DS.Spacing.small)
            .safeguardPanel()
            .transition(.opacity)
    }

    private var hudTopBar: some View {
        HStack {
            Label(model.hudStatus.text, systemImage: model.hudStatus.symbol)
                .font(.headline)
                .padding(.horizontal, DS.Spacing.medium)
                .padding(.vertical, DS.Spacing.small)
                .safeguardPanel()
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if model.listenerLive {
                Image(systemName: "mic.fill")
                    .foregroundStyle(DS.Colors.accent)
                    .accessibilityLabel("Microphone is listening")
            } else if let deaf = model.listenerDeafReason {
                Image(systemName: "mic.slash.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Microphone off: \(deaf)")
            }
            Circle()
                .fill(model.backendStatus?.reachable == true ? DS.Colors.ok : Color.gray)
                .frame(width: 10, height: 10)
                .accessibilityLabel(
                    model.backendStatus?.reachable == true
                        ? "Verification backend reachable" : "Verification backend offline"
                )
        }
        .padding()
    }

    private var hudBottomBar: some View {
        VStack(spacing: DS.Spacing.small) {
            if debugOverlay {
                // Debug only: what the recogniser just heard, so you can see
                // whether Hindi/English is being picked up at all.
                Text((model.lastHeard.isEmpty ? "Heard: (nothing yet)" : "Heard: \(model.lastHeard)")
                    + "\n" + model.judgeStatus
                    + "\nApple ear on • \(model.cloudStatus)")
                    .font(.footnote.monospaced())
                    .lineLimit(6)
                    .padding(8)
                    .safeguardPanel()
            }
            if !listenerOptIn {
                Text("Conversation rating is off: turn it on in Settings")
                    .font(.footnote)
                    .foregroundStyle(DS.Colors.warning)
            }
            Text("Say “help” / “bachao” for SOS")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: DS.Spacing.medium) {
                Button("Stop protecting", role: .destructive) { model.stop() }
                    .buttonStyle(DestructiveButtonStyle())
                Button { model.dimmed.toggle() } label: {
                    Image(systemName: model.dimmed ? "sun.max.fill" : "moon.fill")
                        .accessibilityLabel(
                            model.dimmed ? "Brighten the screen" : "Dim the screen"
                        )
                }
                .buttonStyle(IconButtonStyle())
            }
        }
        .padding()
    }

    /// Auto-SOS countdown after a distress word: big number, one big button.
    private var countdownCard: some View {
        VStack(spacing: DS.Spacing.medium) {
            Label("Auto-SOS starting", systemImage: "timer")
                .font(.headline)
                .foregroundStyle(DS.Colors.danger)
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                let left = max(0, (model.countdownDeadline ?? 0) - ProcessInfo.processInfo.systemUptime)
                Text("\(Int(left.rounded(.up)))")
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .accessibilityLabel("\(Int(left.rounded(.up))) seconds until auto SOS")
            }
            Text("Recording and safety measures start when it reaches zero.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("I'm OK, cancel") { model.cancelAutoSOS() }
                .buttonStyle(PrimaryButtonStyle())
            Text("Or say \"open calculator\", or double tap")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .safeguardPanel()
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(DS.Colors.danger, lineWidth: 3))
        .padding(.horizontal)
        .accessibilityElement(children: .contain)
    }

    /// Red banner for concerning talk: stays a few seconds, offers the
    /// safety measures (the same path as saying the unsafe phrase).
    private func flagCard(_ flag: ConversationFlag) -> some View {
        VStack(spacing: DS.Spacing.small) {
            Label(flag.label, systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(DS.Colors.danger)
            Text("Heard just now. Start the safety measures?")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: DS.Spacing.medium) {
                Button("Start safety measures", role: .destructive) { model.launchSafetyFromFlag() }
                    .buttonStyle(DestructiveButtonStyle())
                Button("Dismiss") { model.dismissConversationFlag() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding()
        .safeguardPanel()
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(DS.Colors.danger, lineWidth: 2))
        .padding(.horizontal)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(flag.label). Start the safety measures?")
    }

    /// The spoken question's on-screen equivalent on the HUD: buttons, code
    /// phrase, or double tap.
    private var checkInCard: some View {
        VStack(spacing: DS.Spacing.medium) {
            Text("No reply in 10 seconds starts the SOS.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("I'm safe") { model.answerSafe() }
                .buttonStyle(PrimaryButtonStyle())
            Button("I need help", role: .destructive) { model.answerUnsafe() }
                .buttonStyle(DestructiveButtonStyle())
        }
        .padding()
        .safeguardPanel()
        .padding(.horizontal)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Are you safe?")
    }

    /// Calm stay-quiet cue on the HUD (large text, announced once).
    private func hudCue(_ text: String) -> some View {
        Text(text)
            .font(.system(.title3, design: .rounded, weight: .semibold))
            .multilineTextAlignment(.center)
            .padding()
            .safeguardPanel()
            .padding(.horizontal)
            .onAppear {
                UIAccessibility.post(notification: .announcement, argument: text)
            }
            .accessibilityAddTraits(.isHeader)
    }

    /// Unsafe: full red scrim, visually distinct from the red edge glow.
    /// Records and shows the state; Phase 6 escalates.
    private var sosScrim: some View {
        ZStack {
            DS.Colors.danger.opacity(0.88)
                .ignoresSafeArea()
            VStack(spacing: DS.Spacing.medium) {
                Image(systemName: "sos.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.white)
                Text("SOS")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
                Text(
                    model.unsafeCause == .noReply
                        ? "No reply — help is on the way"
                        : model.unsafeCause == .distressWord
                            ? "Distress call — recording and help are starting"
                            : "Help is on the way"
                )
                .foregroundStyle(.white)
                if let status = model.evidenceStatus {
                    Label(status, systemImage: "record.circle")
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                }
                Button("Stop protecting") { model.stop() }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(DS.Colors.danger)
            }
            .padding()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("SOS. Help is on the way.")
    }

    // MARK: - Idle

    private var idleView: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                ScrollView {
                VStack(spacing: DS.Spacing.large) {
                    // Outline shield in the accent colour: the dark purple
                    // logo fades on the dark background.
                    Image(systemName: "shield")
                        .font(.system(size: 96, weight: .light))
                        .foregroundStyle(DS.Colors.accent)
                        .accessibilityHidden(true)
                        .padding(.top, DS.Spacing.medium)
                    VStack(spacing: DS.Spacing.small) {
                        Text("Safeguard")
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                            .foregroundStyle(DS.Colors.accent)
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
                    }
                    VStack(spacing: DS.Spacing.medium) {
                        Button("Start protecting") { Task { await model.startCamera() } }
                            .buttonStyle(PrimaryButtonStyle())
                        Button("Replay a video…") { model.showingPicker = true }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                    voiceCommandsCard
                    if let error = model.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(DS.Colors.danger)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding()
                }
                if let toast = model.toast {
                    toastBubble(toast)
                        .padding(.top, DS.Spacing.small)
                }
            }
            .background(DS.Colors.background)
            .navigationTitle("Protect")
            .sheet(isPresented: $model.showingPicker) {
                DocumentPicker { url in model.startReplay(url: url) }
            }
        }
    }

    /// Short voice-command list. Keep in sync with VoiceCommandParser.
    private var voiceCommandsCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            HStack {
                Label("Voice commands", systemImage: "mic.fill")
                    .font(.headline)
                    .foregroundStyle(DS.Colors.accent)
                Spacer()
                if model.listenerLive {
                    Text("ready")
                        .font(.footnote)
                        .foregroundStyle(DS.Colors.ok)
                        .accessibilityLabel("Voice commands ready")
                } else if let deaf = model.listenerDeafReason {
                    Text("unavailable")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Voice commands unavailable: \(deaf)")
                }
            }
            ForEach(
                ["Say “help” or “bachao”, or shout: SOS starts by itself",
                 "Safeguard, stop • status • dim"],
                id: \.self
            ) { command in
                Text("“\(command)”")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: DS.cornerRadius))
    }
}

#Preview {
    ProtectView()
}
