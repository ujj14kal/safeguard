import MapKit
import SwiftUI
import UIKit

struct ProtectView: View {
    @StateObject private var model = ProtectViewModel.shared
    @AppStorage("debugOverlayEnabled") private var debugOverlay = Defaults.debugOverlayDefault
    @AppStorage("listenerOptIn") private var listenerOptIn = Defaults.current.listenerOptIn
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        hudView
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
                        steps: LoadingScreen.protectionSteps
                    )
                }
                .transition(.opacity)
                .zIndex(3)
            }
        }
        .animation(DS.Motion.smooth, value: model.state)
        .animation(DS.Motion.smooth, value: model.isStarting)
        .animation(DS.Motion.smooth, value: model.conversationFlag?.label)
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
                (Text(verbatim: heardLine + "\n\(model.judgeStatus)\n\(model.museSees ?? String(localized: "Muse sees: waiting"))\n\(model.latencyLine)\nCues: \(model.cueLine.isEmpty ? "none" : model.cueLine) • rude gestures: \(model.unwantedGestureCount)/5\n")
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
            if model.state == .monitoring || model.state == .suspected {
                Button("SOS", role: .destructive) { model.manualSOS() }
                    .buttonStyle(DestructiveButtonStyle())
            }
            HStack(spacing: DS.Spacing.medium) {
                Button("Stop protecting") { model.stop() }
                    .buttonStyle(SecondaryButtonStyle())
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
}

#Preview {
    ProtectView()
}
