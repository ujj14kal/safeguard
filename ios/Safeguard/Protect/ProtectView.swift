import MapKit
import SwiftUI
import UIKit

struct ProtectView: View {
    @StateObject private var model = ProtectViewModel.shared
    @AppStorage("debugOverlayEnabled") private var debugOverlay = Defaults.debugOverlayDefault
    @AppStorage("listenerOptIn") private var listenerOptIn = Defaults.current.listenerOptIn
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("autoStartProtecting") private var autoStart = Defaults.autoStartProtectingDefault
    @AppStorage("setupComplete") private var setupComplete = false
    @State private var autoStartTried = false
    @State private var breathing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if model.isProtecting {
                hudView
                    .transition(.opacity)
            } else {
                idleView
                    .transition(.opacity)
            }
        }
        .animation(DS.Motion.smooth, value: model.isProtecting)
        .task { await autoStartIfWanted() }
    }

    private func autoStartIfWanted() async {
        guard autoStart, setupComplete, !autoStartTried, !model.isProtecting,
              SetupPermissions.status(of: .camera) == .granted
        else { return }
        autoStartTried = true
        try? await Task.sleep(for: .milliseconds(3900))
        guard !model.isProtecting else { return }
        await model.startCamera()
    }

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
                SOSView(model: model)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(2)
            }
            if model.dimmed {
                dimOverlay
            }
            if model.isStarting {
                ZStack {
                    DS.Colors.background.opacity(0.92).ignoresSafeArea()
                    LoadingScreen(
                        title: String(localized: "Starting protection"),
                        subtitle: String(localized: "Warming up the camera and microphone")
                    )
                }
                .transition(.opacity)
                .zIndex(3)
            }
        }
        .animation(DS.Motion.smooth, value: model.state)
        .animation(DS.Motion.smooth, value: model.isStarting)
        .animation(DS.Motion.smooth, value: model.conversationFlag?.label)
        .toolbar(.hidden, for: .tabBar)
        .onTapGesture(count: 2) { model.tapCheckIn() }
    }

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
                    .accessibilityLabel(Text(format: "Microphone off: %@", deaf))
            }
            Circle()
                .fill(model.backendStatus?.reachable == true ? DS.Colors.ok : Color.gray)
                .frame(width: 10, height: 10)
                .accessibilityLabel(
                    model.backendStatus?.reachable == true
                        ? String(localized: "Verification backend reachable") : String(localized: "Verification backend offline")
                )
        }
        .padding()
    }

    private var heardLine: String {
        if model.lastHeard.isEmpty {
            return String(localized: "Heard: (nothing yet)")
        }
        return L10n.format("Heard: %@", model.lastHeard)
    }

    private var hudBottomBar: some View {
        VStack(spacing: DS.Spacing.small) {
            if debugOverlay {
                (Text(verbatim: heardLine + "\n\(model.judgeStatus)\n\(model.latencyLine)\nCues: \(model.cueLine.isEmpty ? "none" : model.cueLine) • rude gestures: \(model.unwantedGestureCount)/5\n")
                    + Text(format: "Apple ear on • %@", model.cloudStatus))
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
                            model.dimmed ? String(localized: "Brighten the screen") : String(localized: "Dim the screen")
                        )
                }
                .buttonStyle(IconButtonStyle())
            }
        }
        .padding()
    }

    private var countdownCard: some View {
        VStack(spacing: DS.Spacing.medium) {
            Label("Auto-SOS starting", systemImage: "timer")
                .font(.headline)
                .foregroundStyle(DS.Colors.danger)
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                let left = max(0, (model.countdownDeadline ?? 0) - ProcessInfo.processInfo.systemUptime)
                let secs = Int(left.rounded(.up))
                Text(verbatim: "\(secs)")
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .accessibilityLabel(Text(
                        format: "%d seconds until auto SOS", secs
                    ))
                    .onAppear { announceCountdown(secs) }
                    .onChange(of: secs) { _, new in announceCountdown(new) }
            }
            Text("Recording and safety measures start when it reaches zero.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("I'm OK, cancel") { model.cancelAutoSOS() }
                .buttonStyle(PrimaryButtonStyle())
            Text(format: "Or say \"%@\", or double tap", CodePhraseStore.primarySafe())
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .safeguardPanel()
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(DS.Colors.danger, lineWidth: 3))
        .padding(.horizontal)
        .accessibilityElement(children: .contain)
    }

    private func announceCountdown(_ secs: Int) {
        guard secs > 0 else { return }
        UIAccessibility.post(notification: .announcement, argument: "\(secs)")
    }

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
        .accessibilityLabel(Text(format: "%@. Start the safety measures?", flag.label))
    }

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

    private var idleView: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                DS.Colors.background.ignoresSafeArea()
                RadialGradient(
                    colors: [DS.Colors.brandPurple.opacity(0.45), .clear],
                    center: .top, startRadius: 20, endRadius: 420
                )
                .ignoresSafeArea()
                ScrollView {
                    VStack(spacing: DS.Spacing.large) {
                        hero
                        VStack(spacing: DS.Spacing.medium) {
                            Button {
                                Task { await model.startCamera() }
                            } label: {
                                Label("Start protecting", systemImage: "play.fill")
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            Button("Replay a video…") { model.showingPicker = true }
                                .font(.subheadline.weight(.semibold))
                                .tint(DS.Colors.accent)
                                .minTouchTarget()
                        }
                        readinessPill
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
                .scrollIndicators(.hidden)
                if let toast = model.toast {
                    toastBubble(toast)
                        .padding(.top, DS.Spacing.small)
                }
                if model.isStarting {
                    ZStack {
                        DS.Colors.background.opacity(0.94).ignoresSafeArea()
                        LoadingScreen(
                            title: String(localized: "Starting protection"),
                            subtitle: String(localized: "Warming up the camera and microphone")
                        )
                    }
                    .transition(.opacity)
                }
            }
            .animation(DS.Motion.smooth, value: model.isStarting)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $model.showingPicker) {
                DocumentPicker { url in model.startReplay(url: url) }
            }
        }
    }

    private var hero: some View {
        VStack(spacing: DS.Spacing.medium) {
            ZStack {
                Circle()
                    .fill(RadialGradient(
                        colors: [DS.Colors.accent.opacity(0.4), .clear],
                        center: .center, startRadius: 10, endRadius: 150
                    ))
                    .frame(width: 280, height: 280)
                    .scaleEffect(breathing && !reduceMotion ? 1.06 : 0.96)
                Circle()
                    .strokeBorder(
                        AngularGradient(
                            colors: [DS.Colors.accent, DS.Colors.buttonFill, DS.Colors.accent],
                            center: .center
                        ),
                        lineWidth: 5
                    )
                    .frame(width: 150, height: 150)
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 66, weight: .medium))
                    .foregroundStyle(DS.Colors.accent)
                    .symbolRenderingMode(.hierarchical)
            }
            .frame(height: 230)
            .accessibilityHidden(true)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
                    breathing = true
                }
            }
            Text("Safeguard")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(DS.Colors.accent)
            Text(model.statusLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let verify = model.lastVerifyResult {
                Text(verify).font(.footnote).foregroundStyle(.secondary)
            }
            if let speech = model.lastSpeechInfo {
                Text(speech).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var readinessPill: some View {
        let items = Readiness.items(ReadinessInput(
            camera: SetupPermissions.status(of: .camera),
            microphone: SetupPermissions.status(of: .microphone),
            speech: SetupPermissions.status(of: .speech),
            location: SetupPermissions.status(of: .location),
            backendReachable: model.idleBackendReachable,
            contactCount: model.sosContacts.contacts.count,
            linkedCount: model.sosContacts.linkedCodes.count,
            sendsRealAlerts: model.sendRealAlerts
        ))
        let problems = items.filter { $0.level == .problem }.count
        return Button {
            NotificationCenter.default.post(name: .safeguardOpenDashboard, object: nil)
        } label: {
            HStack {
                StatusPill(
                    text: problems == 0
                        ? String(localized: "Ready to protect")
                        : L10n.format("Items needing attention: %d", problems),
                    symbol: problems == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                    color: problems == 0 ? DS.Colors.ok : DS.Colors.warning
                )
                Spacer()
                Text("Details")
                    .font(.footnote.weight(.semibold))
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
            }
            .foregroundStyle(DS.Colors.accent)
            .dsCard()
        }
        .buttonStyle(.plain)
        .onAppear { model.checkBackend() }
    }

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
                        .accessibilityLabel(Text(format: "Voice commands unavailable: %@", deaf))
                }
            }
            ForEach(
                ["Say “help” or “bachao”, or shout: SOS starts by itself",
                 "Safeguard, stop • status • dim"],
                id: \.self
            ) { command in
                Text(command)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .dsCard()
    }
}

#Preview {
    ProtectView()
}
