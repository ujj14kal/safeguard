import AVFoundation
import CoreImage
import SwiftUI
import UIKit

/// Protect tab model: owns the active FrameSource, runs the detect-then-track
/// pipeline on a serial queue, keeps the screen awake while protecting
/// (foreground-only app), and surfaces frame flow + errors.
@MainActor
final class ProtectViewModel: ObservableObject {
    @Published var state: ProtectionState = .idle
    @Published var usingReplay = false
    @Published var replayName: String?
    @Published var replayImage: UIImage?
    @Published var cameraSession: AVCaptureSession?
    @Published var statusLine = "Not protecting"
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
    @Published var lastSpeechInfo: String?
    @Published var toast: String?
    /// Near-black screen saver: the camera keeps running underneath.
    /// Lifted automatically when anything needs the wearer's eyes.
    @Published var dimmed = false

    /// Conversation-listener opt-in (default OFF). On while protecting,
    /// transcripts feed the threat matcher; off, they are scanned for code
    /// phrases/commands and dropped, and no window is ever built.
    @AppStorage("listenerOptIn") var listenerOptIn = false
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
    private let phraseMatcher: CodePhraseMatcher
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
        self.phraseMatcher = CodePhraseMatcher(config: safetyConfig)
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
        listener.$deafReason.assign(to: &$listenerDeafReason)
        // Hands-free "start protecting" needs a hot mic while idle, so the
        // listener runs from here on (foreground only — iOS suspends the
        // mic in the background). Idle transcripts feed commands only: no
        // code phrases, no window, no threat scan, no backend call.
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
            return "Are you safe?"
        case .safe:
            return "You're safe"
        case .unsafe:
            return "SOS"
        case .suspected:
            return "Something seems off"
        case .monitoring:
            if threatAlert {
                return "Something seems off"
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
        guard await PhoneCameraSource.requestPermission() else {
            errorMessage = FrameSourceError.permissionDenied.localizedDescription
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
            beginSession(status: "Monitoring with phone camera")
        } catch {
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
            beginSession(status: "Replay mode: \(url.lastPathComponent)")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        source?.stop()
        source = nil
        cameraSession = nil
        replayImage = nil
        debugTracks = []
        personCount = 0
        state = .idle
        statusLine = "Not protecting"
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
        window.clear()
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
        let base = usingReplay ? "Replay mode: \(replayName ?? "video")" : "Monitoring with phone camera"
        let people = personCount == 1 ? "1 person" : "\(personCount) people"
        statusLine = "\(base) • \(fps) fps • \(people)"
        safety.tick(at: Self.now)
        drainAskSpeech()
        syncProtectionState()
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
        threatAlert = scores.values.contains { $0 >= pipeline.config.alertThreshold }
        if threatAlert, let maxScore = scores.values.max() {
            safety.noteMovementAlert(score: maxScore, at: Self.now)
            drainAskSpeech()
            syncProtectionState()
        }
        if level != proximity {
            let rising = level > proximity
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
        lastVerifyResult = "Verify: \(result.threatLevel) via \(result.path) (\(result.reason))"
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

    func tapCheckIn() {
        safety.noteReply(.tap, at: Self.now)
        drainAskSpeech()
        syncProtectionState()
    }

    // MARK: - Safety plumbing

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func refreshBackendStatus() {
        Task {
            let status = await VerifierClient().fetchStatus()
            backendStatus = status
            // Said once per session, then on-device protection only.
            if !status.reachable, !offlineMessageSaid {
                offlineMessageSaid = true
                confirm("Verification is offline")
            }
        }
    }

    /// Speaks the pending question, if any. The 10 s clock starts when the
    /// audio starts (the speaker reports back even on failure/cancel).
    private func drainAskSpeech() {
        guard safety.takeAskSpeechDue() else { return }
        speakingNow = true
        speaker.speakAsk(
            phrase: safetyConfig.askPhrase, volume: safetyConfig.askVolume
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
        }
        if mapped != state {
            state = mapped
            // Anything needing the wearer's eyes lifts the dim.
            if mapped == .asking || mapped == .suspected || mapped == .unsafe {
                dimmed = false
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
            UIAccessibility.post(notification: .announcement, argument: "You're safe")
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .unsafe:
            UIAccessibility.post(notification: .announcement, argument: "SOS. Help is on the way.")
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .idle, .monitoring, .asking:
            break
        }
    }

    private func handleSourceError(_ message: String) {
        stop()
        errorMessage = message
    }

    // MARK: - Conversation listener (Part B)

    private func startListener() {
        Task {
            guard await ConversationListener.requestPermissions() else {
                listenerDeafReason =
                    "Microphone or speech recognition denied: voice check-in unavailable."
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
    fileprivate func handlePartial(_ text: String) {
        guard isProtecting else { return }
        guard let reply = partialGate.consume(phraseMatcher.match(text)) else { return }
        safety.noteReply(reply, at: Self.now)
        drainAskSpeech()
        syncProtectionState()
    }

    fileprivate func handleTranscript(_ text: String) {
        let alreadyHandled = partialGate.finishUtterance()
        if !isProtecting {
            if !speakingNow, let command = commandParser.parse(text) {
                runCommand(command)
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
                    showToast("Protection stopped")
                    stop()
                    return
                case .denied:
                    showToast("Still protecting")
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
        guard listenerOptIn else { return }
        window.append(text, at: Self.now)
        guard let found = speechMatcher.match(window.transcript) else { return }
        noteSpeechToPipeline(severity: found.severity, at: Self.now)
        if speechGate.consume(severity: found.severity, at: Self.now) {
            sendSpeechSnippet(match: found)
        }
    }

    // MARK: - Voice commands (Part D)

    private func runCommand(_ command: VoiceCommand) {
        switch command {
        case .startProtecting:
            if isProtecting {
                showToast("Already protecting")
            } else {
                confirm("Protection started")
                Task { await startCamera() }
            }
        case .stopProtecting:
            if !isProtecting {
                showToast("Not protecting")
            } else {
                stopConfirmation.request(at: Self.now)
                confirm("Stop protecting? Say yes to confirm.")
            }
        case .status:
            confirm(statusSummary())
        case .dim:
            if !isProtecting {
                showToast("Start protecting first")
            } else {
                dimmed = true
                confirm("Screen dimmed")
            }
        case .brighten:
            dimmed = false
            confirm("Screen bright")
        case .openSettings:
            confirm("Opening Settings")
            NotificationCenter.default.post(name: .safeguardOpenSettings, object: nil)
        case .goBack:
            confirm("Going back")
            NotificationCenter.default.post(name: .safeguardGoBack, object: nil)
        case .callEmergency:
            confirm("Calling 112")
            // telprompt always asks first: no pocket-dialled emergencies.
            if let url = URL(string: "telprompt://112") {
                Task {
                    let opened = await UIApplication.shared.open(url)
                    if !opened {
                        showToast("Could not place the call on this device")
                    }
                }
            }
        case .shareLocation:
            confirm("Sharing your location is not available yet.")
        case .help:
            confirm(
                "You can say: start protecting, stop, status, dim, brighten, "
                    + "settings, go back, call 112, share location, or help."
            )
        }
    }

    private func statusSummary() -> String {
        if !isProtecting {
            return "Not protecting."
        }
        let people = personCount == 1 ? "1 person nearby" : "\(personCount) people nearby"
        let backend = backendStatus?.reachable == true ? "Verification online." : "Verification offline."
        return "\(displayTitle). \(people). \(proximity.title). \(backend)"
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

    private func showToast(_ text: String) {
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
        lastSpeechInfo = "Speech: \(category) on-device (verification offline)"
    }
}

extension ProtectViewModel: ConversationListenerDelegate {
    func listener(_ listener: ConversationListener, didTranscribe text: String) {
        handleTranscript(text)
    }

    func listener(_ listener: ConversationListener, didHearPartial text: String) {
        handlePartial(text)
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
    }

    func reset() {
        tracker.reset()
        extractor.reset()
        proximityTracker.reset()
        verifierGate.reset()
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
        if verifierGate.consume(maxScore: maxScore) {
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
