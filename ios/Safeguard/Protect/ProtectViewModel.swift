import AVFoundation
import Combine
import CoreImage
import CoreLocation
import CoreMotion
import MapKit
import SwiftUI
import UIKit

/// Protect tab model: owns the active FrameSource, runs the detect-then-track
/// pipeline on a serial queue, keeps the screen awake while protecting
/// (foreground-only app), and surfaces frame flow + errors.
@MainActor
final class ProtectViewModel: ObservableObject {
    /// One model for the whole app, created at launch: the microphone must be
    /// listening for distress words whichever tab is open.
    static let shared = ProtectViewModel()

    @Published var state: ProtectionState = .idle
    @Published var usingReplay = false
    @Published var replayName: String?
    @Published var replayImage: UIImage?
    @Published var cameraSession: AVCaptureSession?
    @Published var statusLine = String(localized: "Not protecting")
    @Published var errorMessage: String?
    @Published var showingPicker = false
    @Published var debugTracks: [Track] = []
    @Published var debugFrameSize: CGSize = .zero
    @Published var debugScores: [Int: Double] = [:]
    @Published var personCount = 0
    @Published var proximity: Proximity = .clear
    @Published var threatAlert = false
    @Published var lastVerifyResult: String?
    @Published var verifyFailure: VerifyFailure?
    @Published var backendStatus: BackendStatus?
    @Published var listenerLive = false
    @Published var listenerDeafReason: String?
    @Published var lastHeard = ""
    /// Debug: what the AI judge last did ("sent", its verdict, or why it failed).
    @Published var judgeStatus = String(localized: "AI judge: idle")
    @Published var cloudStatus = CloudEarState.off.summary
    /// Meta Muse Voice Transcribe through the backend. Needs the listener
    /// opt-in too. Off keeps all hearing on the phone.
    @AppStorage("cloudEarEnabled") var cloudEarEnabled = Defaults.current.cloudEarEnabled
    /// Demo mode: keep the cloud ear on all the time. Off, it switches on only
    /// when someone is near, a flag is raised, or an alert/SOS is running.
    @AppStorage("cloudEarAlwaysOn") var cloudEarAlwaysOn = Defaults.current.cloudEarAlwaysOn
    private var cloudGate = CloudEarGate()
    private var sourcePolicy = TranscriptSourcePolicy()
    private var cloudTimer: Timer?
    private var cloudWanted = false
    /// Concerning talk heard in the last few seconds (red banner on the HUD).
    @Published var conversationFlag: ConversationFlag?
    @Published var lastSpeechInfo: String?
    @Published var toast: String?
    /// Near-black screen saver: the camera keeps running underneath.
    /// Lifted automatically when anything needs the wearer's eyes.
    @Published var dimmed = false

    // MARK: - SOS escalation (Phase 6)

    /// Four-track coordinator (route, contacts, stream, cab).
    @Published var escalation = EscalationCoordinator()
    @Published var incidentID: String?
    @Published var liveURL: String?
    @Published var deliveryStatus: [IncidentDelivery] = []
    @Published var sosRouteMessage: String?
    @Published var sosRoute: MKRoute?
    @Published var sosDestinationName: String?
    @Published var sosDestinationCoordinate: CLLocationCoordinate2D?
    @Published var sosDestinationETA: String?
    @Published var sosRegion: MKCoordinateRegion?
    /// Best fresh fix of the wearer (mirrors the tracker), for the SOS map.
    @Published var sosFix: CLLocation?
    @Published var sosPlaces: [SOSPlace] = []
    @Published var sosRouteSearching = false
    @Published var sosPreciseOffHint = false
    @Published var showingCabSheet = false
    @Published var sosContacts = SOSContactStore()
    /// Wearer's display name for SOS messages (Settings).
    @AppStorage("wearerName") var wearerName = ""
    /// OFF by default (dry-run): turning on needs a confirm dialog.
    @AppStorage("sendRealAlerts") var sendRealAlerts = false

    private let incidentClient = IncidentClient()
    private let locationTracker = SOSLocationTracker()
    private var sosActive = false
    private var evidenceSessionID: String?
    private var sosLocationTimer: Timer?
    private var sosDestinationItem: MKMapItem?
    private var routeWaitStart: TimeInterval?
    private var routeOrigin: LocationSample?
    private var routeRefreshing = false
    /// Mock cab details (DEMO): fixed fake driver/plate + countdown end.
    private(set) var cabDeadline: TimeInterval?
    let cabDriver = "Demo Driver"
    let cabPlate = "DL-1D-EMO"

    /// Countdown text for the demo cab sheet (the 1 s tick refreshes it).
    var cabCountdownText: String {
        guard let deadline = cabDeadline else { return "--:--" }
        let left = max(0, Int(deadline - Self.now))
        return String(format: "%d:%02d", left / 60, left % 60)
    }

    /// Conversation-listener opt-in (default OFF). On while protecting,
    /// transcripts feed the threat matcher; off, they are scanned for code
    /// phrases/commands and dropped, and no window is ever built.
    @AppStorage("listenerOptIn") var listenerOptIn = Defaults.current.listenerOptIn
    /// "auto" (follow the iPhone), "en" or "hi".
    @AppStorage("speechLanguage") var speechLanguage = "auto"

    /// Safety state machine + check-in config. MainActor-owned; the pipeline
    /// feeds it via the published callbacks below (movement alerts), and the
    /// UI feeds replies and taps. Timers advance on the 1 s tick.
    private(set) var safety = SafetyStateMachine()
    private let safetyConfig = SafetyConfig()
    private let speaker: CheckInSpeaking = CheckInSpeaker()

    /// Everything voice shares one listener (one engine, one recognizer).
    private let listener = ConversationListener()
    private var phraseMatcher: CodePhraseMatcher
    private let speechConfig = SpeechConfig()
    private let speechMatcher: SpeechMatcher
    private var window: TranscriptWindow
    private var speechGate: SpeechVerifyGate
    private let commandParser = VoiceCommandParser()
    private var stopConfirmation: StopConfirmation
    private var offlineMessageSaid = false
    private let speechVerifier = VerifierClient()
    /// True while the app itself is speaking: voice commands are ignored
    /// then (code phrases and the threat matcher stay live).
    private var speakingNow = false
    private var partialGate = PartialReplyGate()

    var unsafeCause: UnsafeCause? { safety.unsafeCause }

    /// Pipeline config (immutable, safe to read cross-queue): the HUD
    /// overlay colours boxes with the same thresholds that scored them.
    var threatConfig: ThreatConfig { pipeline.config }

    /// Any tracked person red right now (too close, or alerting).
    var hasRedBox: Bool {
        let config = pipeline.config
        return debugTracks.contains { track in
            let score = debugScores[track.id] ?? 0
            return PersonBoxLevel.level(
                alert: score >= config.alertThreshold,
                height: Double(track.box.height),
                config: config
            ) == .tooClose
        }
    }

    /// HUD status pill content.
    var hudStatus: HudStatus {
        HudStatus.resolve(
            asking: safety.state == .asking,
            safe: safety.state == .safe,
            listeningWindow: safety.state == .listening,
            alert: threatAlert,
            proximity: proximity,
            listenerLive: listenerLive
        )
    }

    init() {
        self.phraseMatcher = CodePhraseMatcher(
            safePhrases: CodePhraseStore.effectiveSafe(),
            unsafePhrases: CodePhraseStore.effectiveUnsafe()
        )
        self.speechMatcher = SpeechMatcher(config: speechConfig)
        self.window = TranscriptWindow(windowSeconds: speechConfig.windowSeconds)
        self.speechGate = SpeechVerifyGate(
            triggerSeverity: safetyConfig.speechStrongThreshold,
            minInterval: speechConfig.speechVerifyMinInterval
        )
        self.stopConfirmation = StopConfirmation(
            windowSeconds: safetyConfig.stopConfirmSeconds
        )
        listener.delegate = self
        listener.$isLive.assign(to: &$listenerLive)
        listener.$isLive.removeDuplicates().dropFirst().sink { live in
            AppLog.shared.event("mic", ["live": String(live)])
        }.store(in: &cancellables)
        locationTracker.$latest.assign(to: &$sosFix)
        locationTracker.$reducedAccuracy.assign(to: &$sosPreciseOffHint)
        listener.$deafReason.assign(to: &$listenerDeafReason)
        listener.$lastHeard.assign(to: &$lastHeard)
        listener.$cloudStatus.assign(to: &$cloudStatus)
        listener.configureCloudEar()
        cloudTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateCloudEar() }
        }
        // Hands-free "start protecting" needs a hot mic while idle, so the
        // listener runs from here on (foreground only — iOS suspends the
        // mic in the background). Idle transcripts feed commands only: no
        // code phrases, no window, no threat scan, no backend call.
        // Pre-setup the mic stays off: setup asks each permission with its
        // reason first, and starting the listener would prompt bare.
        let standard = UserDefaults.standard
        if standard.bool(forKey: "setupComplete")
            || standard.bool(forKey: "onboardingSeen")
        {
            startListener()
        }
        loadContacts()
        history = IncidentHistory.load()
        saveHistory() // persists the 30-day purge, if any
    }

    /// Setup finished: the idle hot mic may start now.
    func setupFinished() {
        startListener()
    }

    // CIContext is Sendable; shared for off-main replay frame conversion.
    fileprivate nonisolated static let ciContext = CIContext()

    /// Serial queue for the whole detection pipeline (render + detect + track).
    private nonisolated let detectionQueue = DispatchQueue(
        label: "app.safeguard.detection", qos: .userInitiated
    )

    /// Pipeline state. Confined to `detectionQueue` by convention: every
    /// access runs on that queue (delegate callbacks funnel through it;
    /// resets use `sync`).
    private nonisolated(unsafe) let pipeline = DetectionPipeline()

    // Frames arrive on a background queue. A lock-based counter avoids spawning
    // a Task per frame, and the gate drops frames while the previous one is
    // still being handled (no unbounded backlog at 30 fps).
    private nonisolated let frameCounter = FrameCounter()
    private nonisolated let pipelineGate = ConversionGate()

    private var source: (any FrameSource)?
    private var lastFpsSample = 0
    private var fpsTimer: Timer?

    /// Protecting in every safety state except idle: the camera keeps
    /// running through the check-in and the SOS (Phase 6 escalates).
    var isProtecting: Bool { state != .idle }

    /// Big status text. The safety state wins; inside Monitoring the scorer
    /// alert wins over proximity text. The ring itself always shows
    /// proximity while protecting (never the alert).
    var displayTitle: String {
        switch state {
        case .asking:
            return String(localized: "Are you safe?")
        case .safe:
            return String(localized: "You're safe")
        case .unsafe:
            return String(localized: "SOS")
        case .countdown:
            return String(localized: "Auto-SOS starting")
        case .suspected:
            return String(localized: "Something seems off")
        case .monitoring:
            if threatAlert {
                return String(localized: "Something seems off")
            }
            if proximity != .clear {
                return proximity.title
            }
            return state.title
        case .idle:
            return state.title
        }
    }

    func startCamera() async {
        errorMessage = nil
        isStarting = true
        guard await PhoneCameraSource.requestPermission() else {
            errorMessage = FrameSourceError.permissionDenied.localizedDescription
            isStarting = false
            return
        }
        do {
            let camera = PhoneCameraSource()
            camera.delegate = self
            try camera.start()
            source = camera
            cameraSession = camera.captureSession
            usingReplay = false
            replayName = nil
            state = .monitoring
            beginSession(status: String(localized: "Monitoring with phone camera"))
            startEgoMotion()
            Task {
                // Let the preview produce its first frames behind the
                // loading screen instead of flashing black.
                try? await Task.sleep(for: .milliseconds(1100))
                isStarting = false
            }
            if pendingDistressStart {
                pendingDistressStart = false
                distressHeard()
            }
        } catch {
            pendingDistressStart = false
            isStarting = false
            errorMessage = error.localizedDescription
        }
    }

    func startReplay(url: URL) {
        errorMessage = nil
        do {
            let replay = VideoFileSource(url: url)
            replay.delegate = self
            try replay.start()
            source = replay
            cameraSession = nil
            usingReplay = true
            replayName = url.lastPathComponent
            state = .monitoring
            beginSession(status: L10n.format("Replay mode: %@", url.lastPathComponent))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        isStarting = false
        // Stopping during an SOS goes through the same end flow as the
        // hold-to-End button: contacts hear "SOS ended" once, tracks stop.
        if sosActive {
            endSOS()
        }
        stopEvidence()
        stopEgoMotion()
        hapticGate.reset()
        source?.stop()
        source = nil
        cameraSession = nil
        replayImage = nil
        debugTracks = []
        personCount = 0
        state = .idle
        statusLine = String(localized: "Not protecting")
        debugScores = [:]
        proximity = .clear
        threatAlert = false
        lastVerifyResult = nil
        verifyFailure = nil
        backendStatus = nil
        lastSpeechInfo = nil
        safety.stopProtecting()
        speaker.stop()
        speakingNow = false
        // The listener stays up for idle voice commands; the transcript
        // window is still discarded on every stop.
        endCountdown()
        evidenceStatus = nil
        window.clear()
        conversationFlag = nil
        judgeSchedule.reset()
        speechGate.reset()
        stopConfirmation.cancel()
        dimmed = false
        detectionQueue.sync { pipeline.reset() }
        UIApplication.shared.isIdleTimerDisabled = false
        fpsTimer?.invalidate()
        fpsTimer = nil
    }

    private func beginSession(status: String) {
        statusLine = status
        // Foreground-only app: keep the screen awake while protecting.
        UIApplication.shared.isIdleTimerDisabled = true
        frameCounter.reset()
        lastFpsSample = 0
        personCount = 0
        debugTracks = []
        debugScores = [:]
        proximity = .clear
        threatAlert = false
        lastVerifyResult = nil
        verifyFailure = nil
        lastSpeechInfo = nil
        window.clear()
        speechGate.reset()
        offlineMessageSaid = false
        safety.startProtecting(at: Self.now)
        refreshBackendStatus()
        startListener()
        locationTracker.requestPermission()
        detectionQueue.sync { pipeline.reset() }
        fpsTimer?.invalidate()
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickFps() }
        }
    }

    private func tickFps() {
        let total = frameCounter.value
        let fps = total - lastFpsSample
        lastFpsSample = total
        let base = usingReplay ? L10n.format("Replay mode: %@", replayName ?? "video") : String(localized: "Monitoring with phone camera")
        let people = personCount == 1 ? String(localized: "1 person") : L10n.format("%d people", personCount)
        statusLine = L10n.format("%@ • %d fps • %@", base, fps, people)
        safety.tick(at: Self.now)
        if let flag = conversationFlag, !flag.isActive(at: Self.now) { conversationFlag = nil }
        drainAskSpeech()
        syncProtectionState()
        retryEscalationTracks()
    }

    fileprivate func publishReplayFrame(_ image: UIImage?) {
        // A frame still in flight when stop() ran must not repaint the screen.
        guard isProtecting else { return }
        if let image {
            replayImage = image
        }
    }

    fileprivate func publishDetection(
        tracks: [Track], frameSize: CGSize, scores: [Int: Double], proximity level: Proximity
    ) {
        guard isProtecting else { return }
        debugTracks = tracks
        debugFrameSize = frameSize
        debugScores = scores
        personCount = tracks.count
        let wasAlert = threatAlert
        threatAlert = scores.values.contains { $0 >= pipeline.config.alertThreshold }
        if threatAlert != wasAlert {
            AppLog.shared.event("vision_alert", [
                "on": String(threatAlert), "score": String(format: "%.2f", scores.values.max() ?? 0),
            ])
        }
        if threatAlert, let maxScore = scores.values.max() {
            safety.noteMovementAlert(score: maxScore, at: Self.now)
            drainAskSpeech()
            syncProtectionState()
        }
        if level != proximity {
            let rising = level > proximity
            AppLog.shared.event("proximity", ["level": String(describing: level), "people": String(tracks.count)])
            proximity = level
            if rising {
                UIImpactFeedbackGenerator(style: level == .tooClose ? .medium : .light)
                    .impactOccurred()
            }
            UIAccessibility.post(notification: .announcement, argument: level.announcement)
        }
    }

    fileprivate func publishVerification(_ result: VerifyResult) {
        guard isProtecting else { return }
        lastVerifyResult = L10n.format("Verify: %@ via %@ (%@)", result.threatLevel, result.path, result.reason)
        AppLog.shared.event("vision_verify", [
            "level": result.threatLevel, "path": result.path, "reason": result.reason,
            "ms": String(Int(result.museLatencyMs)),
        ])
        verifyFailure = nil
        // Unknown levels are dropped: a strict contract beats a guess.
        if let level = MuseVerdictLevel(rawValue: result.threatLevel) {
            safety.noteMuseVerdict(level, at: Self.now)
            drainAskSpeech()
            syncProtectionState()
        }
    }

    fileprivate func publishVerifyFailure(_ error: Error) {
        guard isProtecting else { return }
        let failure = VerifyFailure.classify(
            error, museConfigured: backendStatus?.museConfigured
        )
        verifyFailure = failure
        lastVerifyResult = failure.message
        // Deliberately no machine input: the on-device result stands.
    }

    // MARK: - Check-in replies (voice phrases, double tap, buttons)

    func answerSafe() {
        safety.noteReply(.safePhrase, at: Self.now)
        syncProtectionState()
    }

    func answerUnsafe() {
        safety.noteReply(.unsafePhrase, at: Self.now)
        syncProtectionState()
    }

    #if DEBUG
        /// Simulator/demo helper (Settings → Developer): runs a real SOS
        /// without a camera, so the SOS screen, route and tracks can be
        /// reviewed. Same code path as the unsafe phrase.
        func debugSimulateSOS() {
            if state == .idle {
                state = .monitoring
                beginSession(status: "Debug SOS")
            }
            answerUnsafe()
        }
    #endif

    func tapCheckIn() {
        safety.noteReply(.tap, at: Self.now)
        drainAskSpeech()
        syncProtectionState()
    }

    // MARK: - Safety plumbing

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Backend health for the Dashboard while idle (no protecting session
    /// needed). Reachability only; latency is measured here too.
    @Published var idleBackendReachable: Bool?
    @Published var idleBackendLatencyMs: Int?
    @Published var idleMuseConfigured: Bool?
    /// True from the tap on "Start protecting" until the camera has had a
    /// moment to warm up: drives the branded loading screen.
    @Published var isStarting = false

    func checkBackend() {
        Task {
            let started = ProcessInfo.processInfo.systemUptime
            let status = await VerifierClient().fetchStatus()
            idleBackendReachable = status.reachable
            idleMuseConfigured = status.museConfigured
            idleBackendLatencyMs = status.reachable
                ? Int((ProcessInfo.processInfo.systemUptime - started) * 1000) : nil
        }
    }

    private func refreshBackendStatus() {
        Task {
            let status = await VerifierClient().fetchStatus()
            backendStatus = status
            // Said once per session, then on-device protection only.
            if !status.reachable, !offlineMessageSaid {
                offlineMessageSaid = true
                confirm(String(localized: "Verification is offline"))
            }
        }
    }

    /// Speaks the pending question, if any. The 10 s clock starts when the
    /// audio starts (the speaker reports back even on failure/cancel).
    private func drainAskSpeech() {
        guard safety.takeAskSpeechDue() else { return }
        speakingNow = true
        speaker.speakAsk(
            phrase: String(localized: "Are you safe?"), volume: safetyConfig.askVolume
        ) { [weak self] in
            Task { @MainActor [weak self] in
                self?.safety.noteAskSpeechStarted(at: Self.now)
            }
        } onStopped: { [weak self] in
            Task { @MainActor [weak self] in
                self?.speakingNow = false
            }
        }
    }

    // MARK: - Auto-SOS countdown (distress words)

    @AppStorage("distressWordsEnabled") var distressWordsEnabled = Defaults.current.distressWordsEnabled
    /// System-uptime time when the auto-SOS fires; nil outside the countdown.
    @Published var countdownDeadline: TimeInterval?
    /// "Recording • 2 of 3 parts saved to the cloud" while an SOS records.
    @Published var evidenceStatus: String?
    @AppStorage("recordOnSOS") var recordOnSOS = Defaults.current.recordOnSOS
    nonisolated let evidence = EvidenceRecorder()
    private var cancellables = Set<AnyCancellable>()
    @AppStorage("shoutingTriggersSOS") var shoutingTriggersSOS = Defaults.current.shoutingTriggersSOS
    private var loudness = LoudnessDetector()
    private var levelPeak: Float = -120
    private var levelLoggedAt: TimeInterval = 0
    private let distressMatcher = DistressMatcher()
    private var pendingDistressStart = false
    private var countdownTimer: Timer?

    /// The wearer is OK: stop the countdown (button, double tap, or the
    /// safe code phrase all end up here or in the state machine).
    func cancelAutoSOS() {
        AppLog.shared.event("countdown_cancel", ["by": "button"])
        safety.cancelCountdown(at: Self.now)
        syncProtectionState()
        showToast(String(localized: "Auto-SOS cancelled"))
    }

    private func beginCountdown() {
        countdownDeadline = Self.now + safetyConfig.autoSosSeconds
        // One soft tap each second; the SOS itself fires on the deadline,
        // not on a tick, so it cannot be late by up to a second.
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.state == .countdown else { return }
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            }
        }
        let wait = safetyConfig.autoSosSeconds + 0.05
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, self.state == .countdown else { return }
            self.safety.tick(at: Self.now)
            self.syncProtectionState()
        }
    }

    private func endCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownDeadline = nil
    }

    /// SOS: start recording video and audio, saved to the backend in parts.
    private func startEvidence() {
        guard recordOnSOS, !usingReplay, !evidence.isRecording else { return }
        evidence.retryPending()
        let sessionID = EvidenceSessionID.make()
        evidenceSessionID = sessionID
        AppLog.shared.event("evidence_start", ["session": sessionID])
        lastEvidenceProgress = EvidenceProgress()
        evidence.start(sessionID: sessionID) { [weak self] progress in
            AppLog.shared.event("evidence", [
                "segments": String(progress.segments), "uploaded": String(progress.uploaded),
                "failed": String(progress.failed),
            ])
            Task { @MainActor [weak self] in
                self?.evidenceStatus = progress.summary
                self?.lastEvidenceProgress = progress
            }
        }
        listener.setAudioSink { [evidence] buffer in evidence.appendAudio(buffer) }
        evidenceStatus = EvidenceProgress().summary
    }

    private func stopEvidence() {
        listener.setAudioSink(nil)
        evidence.stop()
    }

    /// A distress word heard while protecting.
    private func distressHeard() {
        AppLog.shared.event("distress", ["protecting": "true"])
        safety.noteDistressWord(at: Self.now)
        syncProtectionState()
    }

    /// A distress word heard while NOT protecting: start protecting at once,
    /// then run the countdown as soon as the camera is up.
    private func distressHeardWhileIdle() {
        guard distressWordsEnabled, !pendingDistressStart else { return }
        AppLog.shared.event("distress", ["protecting": "false", "action": "auto-start"])
        pendingDistressStart = true
        NotificationCenter.default.post(name: .safeguardGoBack, object: nil)
        Task {
            await startCamera()
            if state == .idle { pendingDistressStart = false }
        }
    }

    /// Drives the ring/display state from the machine, announcing changes.
    private func syncProtectionState() {
        let mapped: ProtectionState
        switch safety.state {
        case .idle:
            mapped = .idle
        case .monitoring:
            mapped = .monitoring
        case .listening:
            mapped = .suspected
        case .asking:
            mapped = .asking
        case .safe:
            mapped = .safe
        case .unsafe:
            mapped = .unsafe
        case .countdown:
            mapped = .countdown
        }
        if mapped != state {
            let previous = state
            AppLog.shared.event("state", [
                "from": previous.rawValue, "to": mapped.rawValue,
                "cause": safety.unsafeCause.map { String(describing: $0) } ?? "",
            ])
            state = mapped
            // Anything needing the wearer's eyes lifts the dim.
            if mapped == .asking || mapped == .suspected || mapped == .unsafe || mapped == .countdown {
                dimmed = false
            }
            if mapped == .countdown || mapped == .unsafe || mapped == .asking {
                NotificationCenter.default.post(name: .safeguardGoBack, object: nil)
            }
            if mapped == .countdown {
                beginCountdown()
            } else if previous == .countdown {
                endCountdown()
                if mapped != .unsafe {
                    // Cancelled countdown: a later SOS is not shout-caused.
                    pendingShoutCause = false
                }
            }
            if mapped == .asking, previous != .asking {
                askTrigger = conversationFlag != nil ? "flag" : "checkin"
            }
            if mapped == .unsafe {
                startEvidence()
                startEscalation()
            }
            // Safe-from-Unsafe while an SOS runs = deliberate end (safe
            // phrase or hold-to-End): notify contacts once, stop tracks.
            if previous == .unsafe, mapped == .safe, sosActive {
                endSOS()
            }
            announce(mapped)
        }
    }

    /// Calm cue text while the listening window runs (nil otherwise).
    /// The view announces it via VoiceOver once, on appear.
    var listeningCue: String? {
        safety.state == .listening ? safetyConfig.listeningCueText : nil
    }

    private func announce(_ state: ProtectionState) {
        // Asking needs no announcement: the TTS question is the signal.
        // Listening's cue announces itself when it appears.
        switch state {
        case .suspected:
            // One light haptic on entering the window; the app is otherwise
            // silent (no TTS, no tones) until the question.
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .safe:
            UIAccessibility.post(notification: .announcement, argument: String(localized: "You're safe"))
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .unsafe:
            UIAccessibility.post(notification: .announcement, argument: String(localized: "SOS. Help is on the way."))
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .countdown:
            UIAccessibility.post(
                notification: .announcement,
                argument: L10n.format(
                    "Auto SOS in 5 seconds. Say %@ to cancel.", CodePhraseStore.primarySafe()
                )
            )
        case .idle, .monitoring, .asking:
            break
        }
    }

    private func handleSourceError(_ message: String) {
        stop()
        errorMessage = message
    }

    // MARK: - Conversation listener (Part B)

    /// Decides, every couple of seconds, whether the cloud ear should listen.
    private func updateCloudEar() {
        let escalated = [.suspected, .asking, .countdown, .unsafe].contains(state)
        let want = cloudGate.shouldListen(
            enabled: cloudEarEnabled && listenerOptIn, alwaysOn: cloudEarAlwaysOn,
            personNear: isProtecting && proximity != .clear,
            flagged: conversationFlag != nil, escalated: escalated, at: Self.now
        )
        guard want != cloudWanted else { return }
        cloudWanted = want
        AppLog.shared.event("cloud_ear_wanted", ["on": String(want)])
        listener.setCloudEar(want)
    }

    /// Words the recogniser should favour: the ones that matter most.
    private var contextWords: [String] {
        (safetyConfig.distressWords + safetyConfig.safePhrases + safetyConfig.unsafePhrases
            + ["Safeguard", "stop protecting"]).prefix(60).map { $0 }
    }

    /// One raw microphone level per buffer (dBFS RMS), hopped to the main
    /// actor. Feeds the shouting detector and the level log.
    private func handleLevel(_ db: Float) {
        levelPeak = max(levelPeak, db)
        let now = Self.now
        if now - levelLoggedAt >= 3 {
            AppLog.shared.event("mic_level", ["peak_db": String(format: "%.0f", levelPeak)])
            levelPeak = -120
            levelLoggedAt = now
        }
        guard shoutingTriggersSOS, !speakingNow else {
            _ = loudness.feed(levelDB: -120, at: now)
            return
        }
        if loudness.feed(levelDB: db, at: now) {
            AppLog.shared.event("shout", ["peak_db": String(format: "%.0f", db), "protecting": String(isProtecting)])
            pendingShoutCause = true
            if isProtecting { distressHeard() } else { distressHeardWhileIdle() }
        }
    }

    private func startListener() {
        listener.contextualStrings = contextWords
        listener.setLevelHandler { [weak self] db in
            Task { @MainActor [weak self] in self?.handleLevel(db) }
        }
        Task {
            guard await ConversationListener.requestPermissions() else {
                listenerDeafReason =
                    String(localized: "Microphone or speech recognition denied: voice check-in unavailable.")
                return
            }
            listener.localeIdentifier = SpeechLocale.resolve(
                setting: speechLanguage, preferredLanguages: Locale.preferredLanguages
            )
            listener.start()
        }
    }

    /// One transcript, fixed consumer order. Idle: commands only (no code
    /// phrases, no window, no threat scan). Protecting: code phrases first
    /// (consumed, never scanned further), then the stop-confirmation
    /// answer, then voice commands (never while speaking, never in the
    /// silent window), then — only when opted in — the threat matcher.
    /// Partial text: code phrases only, and each phrase once per utterance.
    private var lastPartialLog: (text: String, at: TimeInterval) = ("", 0)

    fileprivate func handlePartial(_ text: String, source: TranscriptSource) {
        if source == .cloud { sourcePolicy.noteCloud(at: Self.now) }
        if text != lastPartialLog.text, Self.now - lastPartialLog.at >= 0.8 {
            lastPartialLog = (text, Self.now)
            AppLog.shared.event("partial", [
                "text": text, "protecting": String(isProtecting), "src": source.rawValue,
            ])
        }
        // While the cloud ear is delivering, Apple's rougher text of the same
        // sentence only serves distress words and code phrases below.
        let feedsConversation = source == .cloud || sourcePolicy.appleMayFeedConversation(at: Self.now)
        guard isProtecting else {
            // Idle: a distress word starts protection without waiting for the
            // sentence to finish, unless it is a wake-worded command.
            if distressWordsEnabled, !speakingNow, commandParser.parse(text) == nil,
               distressMatcher.matches(text)
            {
                distressHeardWhileIdle()
            }
            return
        }
        if distressWordsEnabled, !speakingNow, commandParser.parse(text) == nil,
           distressMatcher.matches(text)
        {
            distressHeard()
            return
        }
        if feedsConversation {
            rateAndFlag(text)
            if listenerOptIn, aiJudgeEnabled { judgeConversation(partial: text) }
        }
        guard let reply = partialGate.consume(phraseMatcher.match(text)) else { return }
        safety.noteReply(reply, at: Self.now)
        drainAskSpeech()
        syncProtectionState()
    }

    fileprivate func handleTranscript(_ text: String, source: TranscriptSource) {
        if source == .cloud { sourcePolicy.noteCloud(at: Self.now) }
        AppLog.shared.event("heard", [
            "text": text, "protecting": String(isProtecting), "src": source.rawValue,
        ])
        let alreadyHandled = partialGate.finishUtterance()
        if !isProtecting {
            if practicingPhrases {
                // Setup/Settings practice: report only, never act.
                switch phraseMatcher.match(text) {
                case .safePhrase:
                    practiceHeard = .safe
                case .unsafePhrase:
                    practiceHeard = .unsafe
                case .tap, .none:
                    practiceHeard = .noMatch
                }
                return
            }
            if !speakingNow, let command = commandParser.parse(text) {
                runCommand(command)
            } else if distressWordsEnabled, !speakingNow, distressMatcher.matches(text) {
                distressHeardWhileIdle()
            }
            return
        }
        if let reply = phraseMatcher.match(text) {
            // Already acted on from the partials of this utterance.
            if alreadyHandled == reply { return }
            safety.noteReply(reply, at: Self.now)
            drainAskSpeech()
            syncProtectionState()
            return
        }
        let now = Self.now
        if stopConfirmation.isPending(at: now) {
            if commandParser.parse(text) != nil {
                // A fresh wake-worded command cancels the pending stop.
                stopConfirmation.cancel()
            } else {
                switch stopConfirmation.answer(text, at: now) {
                case .confirmed:
                    showToast(String(localized: "Protection stopped"))
                    stop()
                    return
                case .denied:
                    showToast(String(localized: "Still protecting"))
                    return
                case .waiting, .expired:
                    break // keep scanning below
                }
            }
        }
        if !speakingNow, safety.state != .listening,
           let command = commandParser.parse(text)
        {
            runCommand(command)
            return
        }
        if distressWordsEnabled, !speakingNow, distressMatcher.matches(text) {
            distressHeard()
            return
        }
        guard listenerOptIn else { return }
        guard source == .cloud || sourcePolicy.appleMayFeedConversation(at: Self.now) else { return }
        rateAndFlag(text)
        window.append(text, at: Self.now)
        if aiJudgeEnabled {
            judgeConversation()
            return
        }
        guard let found = speechMatcher.match(window.transcript) else { return }
        noteSpeechToPipeline(severity: found.severity, at: Self.now)
        if speechGate.consume(severity: found.severity, at: Self.now) {
            sendSpeechSnippet(match: found)
        }
    }

    // MARK: - Silent conversation rating

    private var hapticGate = SpeechHapticGate()
    private var judgeSchedule = SpeechJudgeSchedule()
    /// AI judging of the whole conversation (text only goes to the backend).
    @AppStorage("aiJudgeEnabled") var aiJudgeEnabled = Defaults.current.aiJudgeEnabled

    /// Every chunk of talk is rated on its own and answered with a vibration
    /// only (never a sound): a nudge, an elevated double tap, or a strong
    /// warning pattern.
    private func rateChunk(_ text: String) {
        vibrate(SpeechHapticLevel.level(for: speechMatcher.match(text)?.severity ?? 0))
    }

    private func vibrate(_ wanted: SpeechHapticLevel) {
        let level = hapticGate.consume(wanted, at: Self.now)
        if level != .none { AppLog.shared.event("vibrate", ["level": String(describing: level)]) }
        // Soft taps only: one, two or three, never a sound.
        let taps: Int
        switch level {
        case .none: return
        case .nudge: taps = 1
        case .elevated: taps = 2
        case .strong: taps = 3
        }
        let generator = UIImpactFeedbackGenerator(style: .soft)
        for index in 0..<taps {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22 * Double(index)) {
                generator.impactOccurred(intensity: 0.8)
            }
        }
    }

    /// Rates one piece of talk (a partial or a final): a soft vibration, a
    /// red flag on the HUD, and the severity into the state machine, so the
    /// wearer is warned while the sentence is still being spoken.
    private func rateAndFlag(_ text: String) {
        guard isProtecting, listenerOptIn, let found = speechMatcher.match(text) else { return }
        rateChunk(text)
        guard found.severity >= ConversationFlag.minSeverity else { return }
        let flag = ConversationFlag(category: found.category, severity: found.severity, at: Self.now)
        conversationFlag = ConversationFlag.merged(conversationFlag, with: flag)
        AppLog.shared.event("flag", [
            "source": "word-list", "category": found.category.rawValue,
            "severity": String(format: "%.2f", found.severity),
        ])
        noteSpeechToPipeline(severity: found.severity, at: Self.now)
        dimmed = false
    }

    /// The AI layer: the backend model reads the last stretch of talk and
    /// says whether it is safe, so threats the word list has never seen
    /// are still caught. Text only, never audio; the on-device matcher has
    /// already warned instantly and stays as the fallback.
    private func judgeConversation(partial: String? = nil) {
        // A partial is the sentence still being spoken: judge it together
        // with the window, so the verdict does not wait for the pause that
        // ends the sentence.
        var text = window.transcript
        if let partial, !partial.isEmpty { text += (text.isEmpty ? "" : " ") + partial }
        var snippet = text
        if snippet.count > speechConfig.snippetMaxChars {
            snippet = String(snippet.suffix(speechConfig.snippetMaxChars))
        }
        guard judgeSchedule.shouldSend(snippet, at: Self.now) else { return }
        judgeStatus = L10n.format("AI judge: sent %d words", snippet.split(separator: " ").count)
        let sentAt = Date()
        AppLog.shared.event("judge_sent", ["text": snippet])
        let onDevice = speechMatcher.match(window.transcript)
        let severity = onDevice?.severity ?? 0
        let category = onDevice?.category.rawValue ?? "none"
        Task {
            do {
                let result = try await speechVerifier.verifySpeech(
                    snippet: snippet, onDeviceSeverity: severity, onDeviceCategory: category
                )
                judgeSchedule.finished()
                judgeStatus = L10n.format("AI judge: %@ %@", result.severity, result.categories.joined(separator: ","))
                AppLog.shared.event("judge", [
                    "severity": result.severity, "categories": result.categories.joined(separator: ","),
                    "directed": String(result.directedAtWearer), "reason": result.reason,
                    "ms": String(Int(Date().timeIntervalSince(sentAt) * 1000)),
                ])
                publishJudgement(result, onDevice: onDevice)
            } catch {
                judgeSchedule.finished()
                judgeStatus = L10n.format("AI judge failed: %@", error.localizedDescription)
                AppLog.shared.event("judge_failed", ["error": error.localizedDescription])
                if let onDevice {
                    publishSpeechFallback(severity: onDevice.severity, category: onDevice.category.rawValue)
                }
            }
        }
    }

    private func publishJudgement(_ result: SpeechVerifyResult, onDevice: SpeechMatch?) {
        guard isProtecting else { return }
        let severity = SpeechMatcher.backendSeverity(result.severity)
        publishSpeechResult(result, onDeviceSeverity: onDevice?.severity ?? 0)
        guard severity >= ConversationFlag.minSeverity else {
            // The AI says it is safe (a joke, a film, friends): take down a
            // flag the word list raised, unless it was a clear threat.
            if let flag = conversationFlag, flag.severity < 0.9 { conversationFlag = nil }
            return
        }
        let category = result.categories.compactMap(SpeechCategory.init(rawValue:)).first
            ?? onDevice?.category ?? .abuse
        let flag = ConversationFlag(category: category, severity: severity, at: Self.now)
        conversationFlag = ConversationFlag.merged(conversationFlag, with: flag)
        vibrate(SpeechHapticLevel.level(for: severity))
        dimmed = false
    }

    func dismissConversationFlag() {
        conversationFlag = nil
    }

    /// The red banner's button: start the safety measures now.
    func launchSafetyFromFlag() {
        conversationFlag = nil
        answerUnsafe()
    }

    // MARK: - Wearer motion

    private let motionManager = CMMotionManager()
    private var recentAccel: [Double] = []

    /// Phone acceleration feeds the approach discount: a box that grows
    /// while the wearer walks is the wearer closing in, not the person.
    private func startEgoMotion() {
        guard motionManager.isDeviceMotionAvailable, !motionManager.isDeviceMotionActive else { return }
        recentAccel = []
        motionManager.deviceMotionUpdateInterval = 0.05
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let a = motion?.userAcceleration else { return }
            self.recentAccel.append((a.x * a.x + a.y * a.y + a.z * a.z).squareRoot())
            if self.recentAccel.count > 20 { self.recentAccel.removeFirst() }
            let rms = (self.recentAccel.map { $0 * $0 }.reduce(0, +)
                / Double(self.recentAccel.count)).squareRoot()
            let now = Self.now
            self.detectionQueue.async { [pipeline = self.pipeline] in
                pipeline.extractor.setEgoMotion(accelRMS: rms, at: now)
            }
        }
    }

    private func stopEgoMotion() {
        motionManager.stopDeviceMotionUpdates()
        recentAccel = []
    }

    // MARK: - Voice commands (Part D)

    private func runCommand(_ command: VoiceCommand) {
        AppLog.shared.event("command", ["name": String(describing: command)])
        switch command {
        case .stopProtecting:
            if !isProtecting {
                showToast(String(localized: "Not protecting"))
            } else {
                stopConfirmation.request(at: Self.now)
                confirm(String(localized: "Stop protecting? Say yes to confirm."))
            }
        case .status:
            confirm(statusSummary())
        case .dim:
            if !isProtecting {
                showToast(String(localized: "Start protecting first"))
            } else {
                dimmed = true
                confirm(String(localized: "Screen dimmed"))
            }
        case .brighten:
            dimmed = false
            confirm(String(localized: "Screen bright"))
        case .openSettings:
            confirm(String(localized: "Opening Settings"))
            NotificationCenter.default.post(name: .safeguardOpenSettings, object: nil)
        case .goBack:
            confirm(String(localized: "Going back"))
            NotificationCenter.default.post(name: .safeguardGoBack, object: nil)
        case .callEmergency:
            confirm(String(localized: "Calling 112"))
            // telprompt always asks first: no pocket-dialled emergencies.
            if let url = URL(string: "telprompt://112") {
                Task {
                    let opened = await UIApplication.shared.open(url)
                    if !opened {
                        showToast(String(localized: "Could not place the call on this device"))
                    }
                }
            }
        case .shareLocation:
            confirm(String(localized: "Sharing your location is not available yet."))
        }
    }

    private func statusSummary() -> String {
        if !isProtecting {
            return String(localized: "Not protecting.")
        }
        let people = personCount == 1 ? String(localized: "1 person nearby") : L10n.format("%d people nearby", personCount)
        let backend = backendStatus?.reachable == true ? String(localized: "Verification online.") : String(localized: "Verification offline.")
        return L10n.format("%@. %@. %@. %@", displayTitle, people, proximity.title, backend)
    }

    /// Every voice action confirms three ways: a short spoken message, a
    /// haptic, and a brief on-screen toast.
    private func confirm(_ text: String) {
        speak(text)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        showToast(text)
    }

    private func speak(_ text: String) {
        speakingNow = true
        speaker.speak(text: text, volume: 1.0) { [weak self] in
            Task { @MainActor [weak self] in
                self?.speakingNow = false
            }
        }
    }

    func showToast(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(for: .seconds(3))
            if toast == text {
                toast = nil
            }
        }
    }

    private func noteSpeechToPipeline(severity: Double, at time: TimeInterval) {
        detectionQueue.async { [weak self] in
            self?.pipeline.setSpeech(severity: severity, at: time)
        }
    }

    private func sendSpeechSnippet(match: SpeechMatch) {
        let snippet = window.snippet(
            matchWordIndex: match.wordIndex, maxChars: speechConfig.snippetMaxChars
        )
        let onDeviceSeverity = match.severity
        let category = match.category.rawValue
        Task {
            do {
                let result = try await speechVerifier.verifySpeech(
                    snippet: snippet,
                    onDeviceSeverity: onDeviceSeverity,
                    onDeviceCategory: category
                )
                publishSpeechResult(result, onDeviceSeverity: onDeviceSeverity)
            } catch {
                publishSpeechFallback(severity: onDeviceSeverity, category: category)
            }
        }
    }

    private func publishSpeechResult(_ result: SpeechVerifyResult, onDeviceSeverity: Double) {
        guard isProtecting else { return }
        let severity = SpeechMatcher.backendSeverity(result.severity)
        safety.noteSpeech(severity: severity, at: Self.now)
        noteSpeechToPipeline(severity: severity, at: Self.now)
        drainAskSpeech()
        syncProtectionState()
        lastSpeechInfo =
            "Speech: \(result.categories.joined(separator: ",")) \(result.severity)"
            + " (on-device \(String(format: "%.2f", onDeviceSeverity)))"
    }

    private func publishSpeechFallback(severity: Double, category: String) {
        guard isProtecting else { return }
        // The backend failed (unreachable, 503, timeout, rate limit): the
        // on-device severity stands, exactly like a failed /verify.
        safety.noteSpeech(severity: severity, at: Self.now)
        noteSpeechToPipeline(severity: severity, at: Self.now)
        drainAskSpeech()
        syncProtectionState()
        lastSpeechInfo = L10n.format("Speech: %@ on-device (verification offline)", category)
    }

    // MARK: - SOS escalation (Phase 6)

    /// Unsafe just began: location + all four tracks start in parallel.
    private func startEscalation() {
        guard !sosActive else { return }
        sosActive = true
        sosStartedAt = Date()
        sosCause = resolveSosCause()
        pendingShoutCause = false
        escalation = EscalationCoordinator()
        escalation.start()
        incidentID = nil
        liveURL = nil
        deliveryStatus = []
        sosRoute = nil
        sosRouteMessage = nil
        sosDestinationName = nil
        sosDestinationCoordinate = nil
        sosDestinationETA = nil
        sosRegion = nil
        sosDestinationItem = nil
        sosPlaces = []
        sosRouteSearching = false
        routeOrigin = nil
        routeRefreshing = false
        routeWaitStart = nil
        if evidenceSessionID == nil {
            // Recording off or replay: the incident still needs a session
            // (the live page just shows no segments).
            evidenceSessionID = EvidenceSessionID.make()
        }
        cabDeadline = Self.now + 300
        AppLog.shared.event("sos_start", [
            "cause": safety.unsafeCause.map { String(describing: $0) } ?? "",
        ])
        locationTracker.start()
        startSOSLocationTimer()
        runTrack(.contacts)
        runTrack(.stream)
        runTrack(.route)
        runTrack(.cab)
    }

    /// Deliberate end (hold-to-End button): the machine goes Safe, and the
    /// safe-from-Unsafe hook runs endSOS().
    func endSOSButtonHeld() {
        safety.endUnsafe(at: Self.now)
        syncProtectionState()
    }

    /// Ends the SOS once: "SOS ended" goes out, tracks/location/recording
    /// stop. Runs from the hold button, the safe phrase, or Stop.
    private func endSOS() {
        guard sosActive else { return }
        sosActive = false
        recordHistoryEntry()
        escalation.end()
        sosLocationTimer?.invalidate()
        sosLocationTimer = nil
        locationTracker.stop()
        stopEvidence()
        let summary = EscalationTrack.allCases.map { track in
            "\(track.rawValue):\(shortStatus(escalation.status(of: track)))"
        }.joined(separator: ",")
        AppLog.shared.event("sos_end", ["tracks": summary])
        if let id = incidentID {
            Task { try? await incidentClient.endIncident(id) }
        }
        incidentID = nil
        liveURL = nil
        deliveryStatus = []
        sosRoute = nil
        sosRouteMessage = nil
        sosDestinationName = nil
        sosDestinationCoordinate = nil
        sosDestinationETA = nil
        sosRegion = nil
        sosDestinationItem = nil
        sosPlaces = []
        sosRouteSearching = false
        routeOrigin = nil
        routeRefreshing = false
        routeWaitStart = nil
        cabDeadline = nil
        showingCabSheet = false
        showToast(String(localized: "SOS ended"))
    }

    private func shortStatus(_ status: TrackStatus) -> String {
        switch status {
        case .pending:
            return "pending"
        case .running:
            return "running"
        case .done:
            return "done"
        case .failed:
            return "failed"
        }
    }

    /// Retry pass on the 1 s tick: due tracks re-run their work.
    private func retryEscalationTracks() {
        guard sosActive else { return }
        for track in escalation.dueRetries(at: Self.now) {
            runTrack(track)
        }
    }

    private func runTrack(_ track: EscalationTrack) {
        guard sosActive, escalation.status(of: track) == .running else { return }
        switch track {
        case .contacts:
            Task { await runContactsTrack() }
        case .stream:
            Task { await runStreamTrack() }
        case .route:
            Task { await runRouteTrack() }
        case .cab:
            Task { await runCabTrack() }
        }
    }

    private func trackDone(_ track: EscalationTrack) {
        escalation.complete(track)
        AppLog.shared.event("sos_track", ["track": track.rawValue, "status": "done"])
        UIAccessibility.post(notification: .announcement, argument: L10n.format("%@ done", track.title))
    }

    private func trackFailed(_ track: EscalationTrack, reason: String) {
        escalation.fail(track, reason: reason, at: Self.now)
        AppLog.shared.event("sos_track", [
            "track": track.rawValue,
            "status": shortStatus(escalation.status(of: track)),
        ])
        // A scheduled retry leaves the track running (silent); only a
        // terminal failure is announced.
        if case .failed = escalation.status(of: track) {
            UIAccessibility.post(notification: .announcement, argument: L10n.format("%@ failed: %@", track.title, reason))
        }
    }

    private func trackReason(for error: Error) -> String {
        if error is URLError {
            return String(localized: "backend unreachable")
        }
        if let failure = error as? VerifierError {
            switch failure {
            case .serverStatus(401):
                return String(localized: "bad app token")
            case .serverStatus(429):
                return String(localized: "rate limited")
            case .serverStatus(let code):
                return L10n.format("server error %@", String(code))
            case .invalidResponse:
                return String(localized: "bad response")
            }
        }
        return String(localized: "failed")
    }

    /// Creates the incident once (the backend dedupes repeats per session):
    /// contacts alerted, live page minted. True when an ID is known after.
    private func ensureIncident() async -> Bool {
        if incidentID != nil { return true }
        guard let session = evidenceSessionID else { return false }
        let fix = locationTracker.latest
        do {
            let result = try await incidentClient.startIncident(
                sessionID: session,
                wearerName: wearerName.isEmpty ? String(localized: "Someone") : wearerName,
                contactCodes: sosContacts.linkedCodes,
                dryRun: !sendRealAlerts,
                latitude: fix?.coordinate.latitude,
                longitude: fix?.coordinate.longitude
            )
            incidentID = result.id
            liveURL = result.liveURL
            deliveryStatus = result.delivery
            return true
        } catch {
            return false
        }
    }

    /// Contacts track: incident created = done (per-contact Sent / Failed /
    /// Dry-run outcomes ride in the delivery chips, not the track status).
    private func runContactsTrack() async {
        guard sosActive else { return }
        if await ensureIncident() {
            trackDone(.contacts)
        } else {
            trackFailed(.contacts, reason: String(localized: "could not reach backend"))
        }
    }

    /// Stream track: done when the live page exists (segments land on it
    /// as the evidence uploader sends them).
    private func runStreamTrack() async {
        guard sosActive else { return }
        if await ensureIncident(), liveURL != nil {
            trackDone(.stream)
        } else {
            trackFailed(.stream, reason: String(localized: "live page unavailable"))
        }
    }

    /// Route track: nearest staffed/public places by walking ETA, drawn on
    /// the SOS map. Waits briefly for an accurate fix (a cold start often
    /// delivers a cell-tower reading first), then refines on its own as the
    /// fix improves or the wearer moves.
    private func runRouteTrack() async {
        guard sosActive else { return }
        guard let first = locationTracker.latest else {
            if routeWaitStart == nil { routeWaitStart = Self.now }
            trackFailed(.route, reason: locationTracker.denied
                ? String(localized: "location permission is off") : RouteChoice.noLocationMessage)
            sosRouteMessage = escalation.status(of: .route) == .running
                ? RouteChoice.waitingForLocationMessage : RouteChoice.noLocationMessage
            return
        }
        routeWaitStart = nil
        sosRouteSearching = true
        sosRouteMessage = RouteChoice.waitingForLocationMessage
        // Give GPS a few seconds to settle on a precise fix.
        let waitUntil = Self.now + LocationFixPolicy.preciseWaitSeconds
        while sosActive, Self.now < waitUntil,
              let fix = locationTracker.latest,
              LocationFixPolicy.quality(accuracy: fix.horizontalAccuracy) != .precise
        {
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard sosActive, let fix = locationTracker.latest else {
            sosRouteSearching = false
            return
        }
        do {
            let outcome = try await computeRoute(from: fix)
            sosRouteSearching = false
            guard outcome else {
                trackFailed(.route, reason: String(localized: "none found"))
                return
            }
            trackDone(.route)
        } catch {
            sosRouteSearching = false
            sosRouteMessage = RouteChoice.noPlacesMessage
            trackFailed(.route, reason: String(localized: "search failed"))
        }
    }

    /// Finds help near `fix` and publishes the result. False when nothing
    /// staffed was found anywhere in range.
    private func computeRoute(from fix: CLLocation) async throws -> Bool {
        let origin = LocationSample(
            latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude,
            accuracy: fix.horizontalAccuracy, timestamp: fix.timestamp
        )
        let places = try await searchStaffedPlaces(near: fix.coordinate)
        let nearest = Array(places.sorted { $0.place.distance < $1.place.distance }.prefix(3))
        guard !nearest.isEmpty else {
            sosRouteMessage = RouteChoice.noPlacesMessage
            return false
        }
        sosPlaces = nearest.map { $0.place }
        var options: [(candidate: RouteCandidate, route: MKRoute, item: MKMapItem)] = []
        for entry in nearest {
            if let found = try? await walkingRoute(from: fix.coordinate, to: entry.item) {
                options.append((
                    RouteCandidate(
                        name: entry.place.name, distanceMeters: entry.place.distance,
                        etaSeconds: found.route.expectedTravelTime
                    ),
                    found.route, entry.item
                ))
            }
        }
        routeOrigin = origin
        if let pick = RouteChoice.pick(from: options.map { $0.candidate }),
           let won = options.first(where: { $0.candidate == pick })
        {
            sosRoute = won.route
            sosDestinationName = pick.name
            sosDestinationCoordinate = won.item.placemark.coordinate
            sosDestinationETA = L10n.format("%d min walk", Int((pick.etaSeconds + 30) / 60))
            sosDestinationItem = won.item
            sosRegion = regionCovering(fix.coordinate, won.item.placemark.coordinate)
            sosRouteMessage = nil
            return true
        }
        // No walking route (maps data thin here): still point at the
        // nearest place with its straight-line distance.
        let closest = nearest[0]
        sosRoute = nil
        sosDestinationName = closest.place.name
        sosDestinationCoordinate = closest.item.placemark.coordinate
        sosDestinationETA = L10n.format("%d m away", Int(closest.place.distance))
        sosDestinationItem = closest.item
        sosRegion = regionCovering(fix.coordinate, closest.item.placemark.coordinate)
        sosRouteMessage = nil
        return true
    }

    /// Silent re-run when the fix got accurate or the wearer moved; a
    /// failure keeps the route already on screen.
    private func refreshRouteIfNeeded() {
        guard sosActive, escalation.status(of: .route) == .done, !routeRefreshing,
              let origin = routeOrigin, let fix = locationTracker.latest
        else { return }
        let current = LocationSample(
            latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude,
            accuracy: fix.horizontalAccuracy, timestamp: fix.timestamp
        )
        guard LocationFixPolicy.shouldReroute(from: origin, to: current) else { return }
        routeRefreshing = true
        Task {
            _ = try? await computeRoute(from: fix)
            routeRefreshing = false
        }
    }

    /// Police and hospitals near `coordinate`, widening the radius until
    /// something turns up (maps data is thin in many places). Uses Apple's
    /// point-of-interest search first, then a text search as a backstop.
    private func searchStaffedPlaces(
        near coordinate: CLLocationCoordinate2D
    ) async throws -> [(place: SOSPlace, item: MKMapItem)] {
        let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        var lastError: Error?
        for radius in [3000.0, 8000, 20000] {
            var found: [(place: SOSPlace, item: MKMapItem)] = []
            var seen = Set<String>()
            func add(_ items: [MKMapItem], fallback: SOSPlaceKind) {
                for item in items.prefix(8) {
                    let point = item.placemark.coordinate
                    let name = item.name ?? (fallback == .police
                        ? String(localized: "Police station") : String(localized: "Hospital"))
                    let id = "\(name.lowercased())|\(Int(point.latitude * 2000))|\(Int(point.longitude * 2000))"
                    guard seen.insert(id).inserted else { continue }
                    let kind: SOSPlaceKind = item.pointOfInterestCategory == .police
                        ? .police : (item.pointOfInterestCategory == .hospital ? .hospital : fallback)
                    let distance = here.distance(
                        from: CLLocation(latitude: point.latitude, longitude: point.longitude)
                    )
                    found.append((
                        SOSPlace(id: id, name: name, kind: kind, coordinate: point, distance: distance),
                        item
                    ))
                }
            }
            do {
                let poi = MKLocalPointsOfInterestRequest(center: coordinate, radius: radius)
                poi.pointOfInterestFilter = MKPointOfInterestFilter(including: [.police, .hospital])
                let response = try await MKLocalSearch(request: poi).start()
                add(response.mapItems, fallback: .police)
            } catch {
                lastError = error
            }
            for (query, kind) in [("police station", SOSPlaceKind.police), ("hospital", .hospital)] {
                let request = MKLocalSearch.Request()
                request.naturalLanguageQuery = query
                request.region = MKCoordinateRegion(
                    center: coordinate, latitudinalMeters: radius * 2, longitudinalMeters: radius * 2
                )
                do {
                    let response = try await MKLocalSearch(request: request).start()
                    add(response.mapItems, fallback: kind)
                } catch {
                    lastError = error
                }
            }
            if !found.isEmpty { return found }
        }
        if let lastError { throw lastError }
        return []
    }

    private func walkingRoute(
        from: CLLocationCoordinate2D, to destination: MKMapItem
    ) async throws -> (route: MKRoute, item: MKMapItem) {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        request.destination = destination
        request.transportType = .walking
        let response = try await MKDirections(request: request).calculate()
        guard let route = response.routes.first else {
            throw VerifierError.invalidResponse("no route")
        }
        return (route, destination)
    }

    private func regionCovering(
        _ first: CLLocationCoordinate2D, _ second: CLLocationCoordinate2D
    ) -> MKCoordinateRegion {
        let latDelta = abs(first.latitude - second.latitude) * 1.6 + 0.005
        let lonDelta = abs(first.longitude - second.longitude) * 1.6 + 0.005
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (first.latitude + second.latitude) / 2,
                longitude: (first.longitude + second.longitude) / 2
            ),
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
        )
    }

    /// Walking directions in Google Maps (the app when installed, else the
    /// web page, which iOS hands to the app on its own). No API key needed.
    func openDestinationInGoogleMaps() {
        guard let point = sosDestinationCoordinate else { return }
        let origin = locationTracker.latest.map {
            "\($0.coordinate.latitude),\($0.coordinate.longitude)"
        }
        let destination = "\(point.latitude),\(point.longitude)"
        var web = "https://www.google.com/maps/dir/?api=1&destination=\(destination)&travelmode=walking"
        if let origin { web += "&origin=\(origin)" }
        if let url = URL(string: "comgooglemaps://?daddr=\(destination)&directionsmode=walking"),
           UIApplication.shared.canOpenURL(url)
        {
            UIApplication.shared.open(url)
        } else if let url = URL(string: web) {
            UIApplication.shared.open(url)
        }
    }

    func openDestinationInMaps() {
        sosDestinationItem?.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking,
        ])
    }

    /// Cab track (DEMO): shares the fake details with the contacts.
    private func runCabTrack() async {
        guard sosActive else { return }
        guard await ensureIncident(), let id = incidentID else {
            trackFailed(.cab, reason: String(localized: "waiting for incident"))
            return
        }
        do {
            let etaMinutes = max(1, Int(((cabDeadline ?? Self.now) - Self.now) / 60))
            _ = try await incidentClient.shareCab(
                incidentID: id, driver: cabDriver, plate: cabPlate, etaMinutes: etaMinutes
            )
            trackDone(.cab)
        } catch {
            trackFailed(.cab, reason: trackReason(for: error))
        }
    }

    /// Manual re-share from the demo sheet.
    func shareCabDetails() {
        guard sosActive, let id = incidentID else {
            showToast(String(localized: "No active SOS"))
            return
        }
        Task {
            do {
                let etaMinutes = max(1, Int(((cabDeadline ?? Self.now) - Self.now) / 60))
                _ = try await incidentClient.shareCab(
                    incidentID: id, driver: cabDriver, plate: cabPlate, etaMinutes: etaMinutes
                )
                showToast(String(localized: "Cab details shared"))
            } catch {
                showToast(String(localized: "Could not share cab details"))
            }
        }
    }

    // MARK: - SOS location stream

    private func startSOSLocationTimer() {
        sosLocationTimer?.invalidate()
        sosLocationTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.streamSOSLocation() }
        }
        streamSOSLocation()
    }

    private func streamSOSLocation() {
        refreshRouteIfNeeded()
        guard sosActive, let id = incidentID,
              let fix = locationTracker.latest
        else {
            return
        }
        Task {
            try? await incidentClient.sendLocation(
                incidentID: id,
                latitude: fix.coordinate.latitude,
                longitude: fix.coordinate.longitude,
                accuracy: fix.horizontalAccuracy >= 0 ? fix.horizontalAccuracy : nil,
                timestamp: fix.timestamp.timeIntervalSince1970
            )
        }
    }

    // MARK: - Contacts (Phase 6)

    private static let contactsDefaultsKey = "sosContactsJSON"

    private func loadContacts() {
        guard let data = UserDefaults.standard.data(forKey: Self.contactsDefaultsKey),
              let decoded = try? JSONDecoder().decode([SOSContact].self, from: data)
        else {
            return
        }
        sosContacts = SOSContactStore(contacts: decoded)
    }

    private func saveContacts() {
        if let data = try? JSONEncoder().encode(sosContacts.contacts) {
            UserDefaults.standard.set(data, forKey: Self.contactsDefaultsKey)
        }
    }

    /// Creates a backend invite and adds the contact. Returns the share link.
    func inviteContact(name: String, phone: String? = nil) async -> URL? {
        guard !sosContacts.isFull else {
            showToast(String(localized: "At most 5 contacts"))
            return nil
        }
        do {
            let invite = try await incidentClient.inviteContact(name: name)
            if sosContacts.add(name: invite.name, code: invite.code, link: invite.link, phone: phone) {
                saveContacts()
                AppLog.shared.event("contact_invite", ["linked": "false"])
                return URL(string: invite.link)
            }
            return nil
        } catch {
            showToast(String(localized: "Could not create invite"))
            return nil
        }
    }

    func removeContact(code: String) {
        sosContacts.remove(code: code)
        saveContacts()
    }

    func refreshContacts() {
        Task {
            for contact in sosContacts.contacts where !contact.linked {
                if let status = try? await incidentClient.contactStatus(code: contact.code) {
                    sosContacts.setLinked(code: contact.code, linked: status.linked)
                }
            }
            saveContacts()
        }
    }

    // MARK: - Phase 7: practice, history, data

    /// Code-phrase practice outcome for setup/Settings ("Heard: …").
    enum PracticeHeard: Equatable {
        case none
        case noMatch
        case safe
        case unsafe
    }

    @Published var practiceHeard = PracticeHeard.none
    private var practicingPhrases = false

    func startPhrasePractice() {
        practiceHeard = .none
        practicingPhrases = true
        startListener() // permissions were granted in the setup step before
    }

    func stopPhrasePractice() {
        practicingPhrases = false
    }

    /// Rebuilds the matcher after the wearer edits code phrases.
    func refreshPhrases() {
        phraseMatcher = CodePhraseMatcher(
            safePhrases: CodePhraseStore.effectiveSafe(),
            unsafePhrases: CodePhraseStore.effectiveUnsafe()
        )
    }

    func setContactAgreed(code: String, agreed: Bool) {
        sosContacts.setAgreed(code: code, agreed: agreed)
        saveContacts()
    }

    func requestLocationPermission() {
        locationTracker.requestPermission()
    }

    // MARK: - Incident history (Activity tab)

    @Published var history = IncidentHistory()
    @Published private(set) var sosStartedAt: Date?
    private var sosCause: String?
    private var lastEvidenceProgress = EvidenceProgress()
    /// Set when shouting triggers the distress path; consumed at SOS start.
    private var pendingShoutCause = false
    /// What triggered the current check-in ("flag" or "checkin").
    private var askTrigger = "checkin"

    private func saveHistory() {
        history.save()
    }

    func deleteHistoryEntry(id: UUID) {
        history.remove(id: id)
        saveHistory()
    }

    func deleteHistoryAll() {
        history.removeAll()
        saveHistory()
    }

    private func recordHistoryEntry() {
        guard let started = sosStartedAt else { return }
        var outcomes: [String: String] = [:]
        for track in EscalationTrack.allCases {
            let status = shortStatus(escalation.status(of: track))
            if let reason = escalation.reason(of: track) {
                outcomes[track.rawValue] = "\(status): \(reason)"
            } else {
                outcomes[track.rawValue] = status
            }
        }
        let alerted = deliveryStatus.filter {
            $0.status == "sent" || $0.status == "dry-run"
        }
        history.append(IncidentHistoryEntry(
            startedAt: started, endedAt: Date(),
            cause: sosCause ?? "noReply", trackOutcomes: outcomes,
            contactsAlerted: alerted.count,
            contactNames: alerted.compactMap(\.name),
            evidenceSaved: lastEvidenceProgress.uploaded,
            evidenceWaiting: max(
                0, lastEvidenceProgress.segments - lastEvidenceProgress.uploaded
            ),
            liveURL: liveURL, evidenceSessionID: evidenceSessionID
        ))
        saveHistory()
        sosStartedAt = nil
        sosCause = nil
    }

    private func resolveSosCause() -> String {
        switch safety.unsafeCause {
        case .unsafePhrase:
            return "unsafePhrase"
        case .distressWord:
            return pendingShoutCause ? "shouting" : "distressWord"
        case .noReply, .none:
            return askTrigger == "flag" ? "flag" : "noReply"
        }
    }

    // MARK: - Delete all my data (Settings → Data)

    /// Wipes local data, then asks the backend to delete this device's
    /// evidence sessions and contacts. Refuses during an active SOS.
    /// Returns what happened, honestly (offline failures listed).
    func deleteAllMyData(keepingSetup: Bool = false) async -> DataWipeReport? {
        guard !sosActive else {
            showToast(String(localized: "End the SOS first"))
            return nil
        }
        let sessions = Set(history.entries.compactMap(\.evidenceSessionID))
        let codes = sosContacts.contacts.map(\.code)
        // The account goes first: deleting it needs the saved session.
        var accountDeleted: Bool?
        if AccountStore.shared.isSignedIn {
            accountDeleted = await AccountStore.shared.deleteAccount()
        }
        AccountStore.shared.clearLocal()
        var report = DataWipe.wipeLocal(keeping: keepingSetup ? ["setupComplete"] : [])
        sosContacts = SOSContactStore()
        history = IncidentHistory()
        refreshPhrases()
        for session in sessions {
            do {
                _ = try await incidentClient.deleteEvidence(sessionID: session)
                report.backendDeleted.append("evidence")
            } catch {
                report.backendFailed.append("evidence")
            }
        }
        for code in codes {
            do {
                _ = try await incidentClient.deleteContact(code: code)
                report.backendDeleted.append("contact")
            } catch {
                report.backendFailed.append("contact")
            }
        }
        if let accountDeleted {
            if accountDeleted {
                report.backendDeleted.append("account")
            } else {
                report.backendFailed.append("account")
            }
        }
        AppLog.shared.event("data_wipe", [
            "keys": String(report.removedKeys.count),
            "files": String(report.removedFiles.count),
            "backend_ok": String(report.backendDeleted.count),
            "backend_failed": String(report.backendFailed.count),
        ])
        return report
    }

    /// Setup dry-run: a labelled SAMPLE SOS. A dry-run (never real),
    /// non-test incident is started and ended right away so the preview is
    /// exactly the text contacts would receive. No recording, no location.
    func runSampleSOS() async -> String? {
        do {
            let result = try await incidentClient.startIncident(
                sessionID: EvidenceSessionID.make(),
                wearerName: wearerName.isEmpty ? String(localized: "Someone") : wearerName,
                contactCodes: sosContacts.linkedCodes,
                dryRun: true, test: false
            )
            try? await incidentClient.endIncident(result.id)
            return result.previewText.isEmpty ? nil : result.previewText
        } catch {
            return nil
        }
    }

    /// Settings test button: a test-flagged incident, ended right away.
    func sendTestAlert() {
        let codes = sosContacts.linkedCodes
        guard !codes.isEmpty else {
            showToast(String(localized: "Link a contact first"))
            return
        }
        Task {
            do {
                let result = try await incidentClient.startIncident(
                    sessionID: EvidenceSessionID.make(),
                    wearerName: wearerName.isEmpty ? String(localized: "Someone") : wearerName,
                    contactCodes: codes,
                    dryRun: !sendRealAlerts,
                    test: true
                )
                try? await incidentClient.endIncident(result.id)
                showToast(sendRealAlerts ? String(localized: "Test alert sent") : String(localized: "Test alert logged (dry-run)"))
                AppLog.shared.event("test_alert", ["sent": "true"])
            } catch {
                showToast(String(localized: "Test alert failed"))
                AppLog.shared.event("test_alert", ["sent": "false"])
            }
        }
    }
}

extension ProtectViewModel: ConversationListenerDelegate {
    func listener(_ listener: ConversationListener, didTranscribe text: String, source: TranscriptSource) {
        handleTranscript(text, source: source)
    }

    func listener(_ listener: ConversationListener, didHearPartial text: String, source: TranscriptSource) {
        handlePartial(text, source: source)
    }
}

/// Detection pipeline state: frame render, throttled Vision detection, IoU
/// tracking. All methods run on the view model's `detectionQueue`.
private final class DetectionPipeline {
    let config: ThreatConfig
    let detector: PersonDetector
    let tracker = IoUTracker()
    let extractor: FeatureExtractor
    let scorer: ThreatScorer
    var proximityTracker: ProximityTracker
    let verifier = VerifierClient()
    var verifierGate: VerifierGate
    var sweepGate: NearSweepGate
    let frameBuffer = FrameBuffer()
    var lastDetect = Date.distantPast
    let detectInterval: TimeInterval = 0.2

    init(config: ThreatConfig = ThreatConfig()) {
        self.config = config
        self.detector = PersonDetector(poseMatchDistance: config.poseMatchDistance)
        self.extractor = FeatureExtractor(config: config)
        self.scorer = ThreatScorer(config: config)
        self.proximityTracker = ProximityTracker(config: config)
        self.verifierGate = VerifierGate(config: config)
        self.sweepGate = NearSweepGate(config: config)
    }

    func reset() {
        tracker.reset()
        extractor.reset()
        proximityTracker.reset()
        verifierGate.reset()
        sweepGate.reset()
        frameBuffer.clear()
    }

    /// Latest speech severity from the conversation listener (global, not
    /// per-track): stamped onto every track's features while fresh.
    func setSpeech(severity: Double, at time: TimeInterval) {
        extractor.setSpeech(severity: severity, at: time)
    }

    func handleFrame(_ frame: SafeguardFrame, isReplay: Bool, owner: ProtectViewModel) {
        if isReplay {
            let image = Self.makeImage(from: frame.pixelBuffer)
            Task { await owner.publishReplayFrame(image) }
        }

        let now = Date()
        guard now.timeIntervalSince(lastDetect) >= detectInterval else { return }
        lastDetect = now
        let nowSeconds = ProcessInfo.processInfo.systemUptime
        guard let people = try? detector.detect(in: frame.pixelBuffer) else { return }
        let tracks = tracker.update(detections: people)
        let live = tracks.filter { $0.missed == 0 }
        // Store the boxes WITH their frame so a verify clip can prompt SAM 2 on
        // its first frame with the boxes that were actually seen there.
        frameBuffer.append(
            pixelBuffer: frame.pixelBuffer, at: nowSeconds, boxes: live.map(\.box)
        )
        extractor.update(tracks: live, at: nowSeconds)
        var scores: [Int: Double] = [:]
        var scored: [(track: Track, features: PersonFeatures, score: ThreatScore)] = []
        for track in live {
            if let features = extractor.features(for: track.id, at: nowSeconds) {
                let score = scorer.score(features)
                scores[track.id] = score.value
                scored.append((track, features, score))
            }
        }
        let maxScore = scores.values.max() ?? 0
        let nearestHeight = live.map { Double($0.box.height) }.max()
        let alertFired = verifierGate.consume(maxScore: maxScore)
        let sweepDue = sweepGate.consume(
            isNear: (nearestHeight ?? 0) >= config.nearHeight, at: nowSeconds
        )
        if alertFired { sweepGate.noteSent(at: nowSeconds) }
        if alertFired || sweepDue {
            let clip = frameBuffer.clip()
            let top = scored.sorted { $0.score.value > $1.score.value }.prefix(3)
            let payload = VerifyPayload(
                frames: clip.frames,
                boxes: VerifyPayload.pixelBoxes(clip.boxes, in: clip.size),
                features: top.map {
                    VerifyFeatureSummary(
                        track: $0.track, features: $0.features,
                        score: $0.score.value, reasons: $0.score.reasons
                    )
                }
            )
            Task { [verifier] in
                do {
                    let result = try await verifier.verify(payload)
                    await owner.publishVerification(result)
                } catch {
                    await owner.publishVerifyFailure(error)
                }
            }
        }
        let nearest = live.map { Double($0.box.height) }.max()
        let level = proximityTracker.update(nearestHeight: nearest, at: nowSeconds)
        let size = CGSize(
            width: CVPixelBufferGetWidth(frame.pixelBuffer),
            height: CVPixelBufferGetHeight(frame.pixelBuffer)
        )
        Task {
            await owner.publishDetection(
                tracks: live, frameSize: size, scores: scores, proximity: level
            )
        }
    }

    nonisolated private static func makeImage(from pixelBuffer: CVPixelBuffer) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ProtectViewModel.ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}

extension ProtectViewModel: FrameSourceDelegate {
    nonisolated func frameSource(_ source: any FrameSource, didOutput frame: SafeguardFrame) {
        frameCounter.increment()
        evidence.appendVideo(frame.pixelBuffer, at: frame.timestamp)
        // Drop frames while one is still being handled: bounds the queue
        // and the detection work under a 30 fps source.
        guard pipelineGate.tryEnter() else { return }
        let isReplay = source is VideoFileSource
        detectionQueue.async { [weak self] in
            guard let self else { return }
            self.pipeline.handleFrame(frame, isReplay: isReplay, owner: self)
            self.pipelineGate.leave()
        }
    }

    nonisolated func frameSource(_ source: any FrameSource, didFailWith error: Error) {
        let message = error.localizedDescription
        Task { await self.handleSourceError(message) }
    }
}

/// Thread-safe frame counter shared between the capture queue and the main actor.
private final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
    func reset() { lock.withLock { count = 0 } }
}

/// Lets one frame be handled at a time; later frames are dropped until the
/// previous one finishes.
private final class ConversionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false

    func tryEnter() -> Bool {
        lock.withLock {
            if busy { return false }
            busy = true
            return true
        }
    }

    func leave() { lock.withLock { busy = false } }
}
