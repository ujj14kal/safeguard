import AVFoundation
import Combine
import CoreImage
import CoreLocation
import CoreMotion
import MapKit
import SwiftUI
import UIKit

@MainActor
final class ProtectViewModel: ObservableObject {
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
    @Published var museSees: String?
    @Published var verifyFailure: VerifyFailure?
    @Published var backendStatus: BackendStatus?
    @Published var listenerLive = false
    @Published var listenerDeafReason: String?
    @Published var lastHeard = ""
    @Published var judgeStatus = String(localized: "AI judge: idle")
    @Published var cloudStatus = CloudEarState.off.summary
    @AppStorage("cloudEarEnabled") var cloudEarEnabled = Defaults.current.cloudEarEnabled
    @AppStorage("cloudEarAlwaysOn") var cloudEarAlwaysOn = Defaults.current.cloudEarAlwaysOn
    private var cloudGate = CloudEarGate()
    private var sourcePolicy = TranscriptSourcePolicy()
    private var cloudTimer: Timer?
    private var cloudWanted = false
    @Published var conversationFlag: ConversationFlag?
    @Published var lastSpeechInfo: String?
    @Published var toast: String?
    @Published var dimmed = false

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
    @Published var sosFix: CLLocation?
    @Published var sosPlaces: [SOSPlace] = []
    @Published var sosRouteSearching = false
    @Published var sosPreciseOffHint = false
    @Published var showingCabSheet = false
    @Published var sosContacts = SOSContactStore()
    @AppStorage("wearerName") var wearerName = ""
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
    private(set) var cabDeadline: TimeInterval?
    let cabDriver = "Demo Driver"
    let cabPlate = "DL-1D-EMO"

    var cabCountdownText: String {
        guard let deadline = cabDeadline else { return "--:--" }
        let left = max(0, Int(deadline - Self.now))
        return String(format: "%d:%02d", left / 60, left % 60)
    }

    @AppStorage("listenerOptIn") var listenerOptIn = Defaults.current.listenerOptIn
    @AppStorage("speechLanguage") var speechLanguage = "auto"

    private(set) var safety = SafetyStateMachine()
    private let safetyConfig = SafetyConfig()
    private let speaker: CheckInSpeaking = CheckInSpeaker()

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
    private var speakingNow = false
    private var partialGate = PartialReplyGate()

    var unsafeCause: UnsafeCause? { safety.unsafeCause }

    var threatConfig: ThreatConfig { pipeline.config }

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
        let standard = UserDefaults.standard
        if standard.bool(forKey: "setupComplete")
            || standard.bool(forKey: "onboardingSeen")
        {
            startListener()
        }
        loadContacts()
        history = IncidentHistory.load()
        saveHistory()
    }

    func setupFinished() {
        startListener()
    }

    fileprivate nonisolated static let ciContext = CIContext()

    private nonisolated let detectionQueue = DispatchQueue(
        label: "app.safeguard.detection", qos: .userInitiated
    )

    private nonisolated(unsafe) let pipeline = DetectionPipeline()

    private nonisolated let frameCounter = FrameCounter()
    private nonisolated let pipelineGate = ConversionGate()

    private var source: (any FrameSource)?
    private var lastFpsSample = 0
    private var fpsTimer: Timer?

    var isProtecting: Bool { state != .idle }

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
        guard !isStarting, state == .idle else { return }
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
            startWatch()
            Task {
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
        stopWatch()
        stopLiveStream()
        isStarting = false
        if sosActive {
            endSOS()
        }
        stopEvidence()
        stopEgoMotion()
        evidenceLog.clear()
        pendingTranscript.removeAll()
        namesRecorded.removeAll()
        nameLastCounted.removeAll()
        plateTracker.reset()
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
        museSees = nil
        verifyFailure = nil
        backendStatus = nil
        lastSpeechInfo = nil
        safety.stopProtecting()
        speaker.stop()
        speakingNow = false
        endCountdown()
        evidenceStatus = nil
        window.clear()
        gestureCounter.reset()
        unwantedGestureCount = 0
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
        UIApplication.shared.isIdleTimerDisabled = true
        frameCounter.reset()
        lastFpsSample = 0
        personCount = 0
        debugTracks = []
        debugScores = [:]
        proximity = .clear
        threatAlert = false
        lastVerifyResult = nil
        museSees = nil
        verifyFailure = nil
        lastSpeechInfo = nil
        window.clear()
        gestureCounter.reset()
        unwantedGestureCount = 0
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

    @AppStorage("gesturesTriggerSOS") var gesturesTriggerSOS = true
    @Published var cueLine = ""
    @Published private(set) var unwantedGestureCount = 0
    private var gestureCounter = UnwantedGestureCounter()
    private var lastGestureLog: [String: TimeInterval] = [:]
    private var pendingGestureCause = false
    private var pendingTimerCause = false
    private var lastAlertAbove: TimeInterval = -.infinity
    private nonisolated let evidenceLog = EvidenceLog()
    private var plateTracker = PlateTracker()
    private var shotSeq = 0
    private var pendingItemPayload: [[String: Any]] = []
    private var logFlushScheduled = false
    private let shotUploader = EvidenceUploader()

    fileprivate func publishFrameCues(_ cues: FrameCues, at time: TimeInterval) {
        guard isProtecting else { return }
        cueLine = cues.summary
        for gesture in cues.gestures where gesture.kind != .other {
            logCue(
                "gesture", kind: gesture.kind.rawValue, score: gesture.score, at: time,
                every: gesture.isHostile ? 0.2 : 1.5
            )
        }
        if let expression = cues.expression, expression.kind != .neutral, expression.score >= 0.45 {
            logCue("expression", kind: expression.kind.rawValue, score: expression.score, at: time, every: 2)
        }
        let hostile = cues.hostile(minScore: pipeline.config.gestureMinScore)
        guard let event = gestureCounter.feed(hostile: hostile != nil, at: time) else { return }
        switch event {
        case .counted(let total):
            unwantedGestureCount = total
            AppLog.shared.event("gesture_counted", ["total": String(total), "limit": String(gestureCounter.limit)])
            recordGestureMoment(score: hostile?.score ?? 0)
            showToast(L10n.format("Unwanted gesture noted (%d)", total))
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .exceeded(let total):
            unwantedGestureCount = 0
            recordGestureMoment(score: hostile?.score ?? 0)
            AppLog.shared.event("gesture_sos", ["total": String(total), "enabled": String(gesturesTriggerSOS)])
            guard gesturesTriggerSOS else { return }
            pendingGestureCause = true
            distressHeard()
        }
    }

    private func recordGestureMoment(score: Double) {
        guard let jpeg = pipeline.frameBuffer.snapshot().frames.last else { return }
        evidenceLog.add(LogItem(
            type: "gesture", text: "Obscene hand gesture",
            rating: score >= 0.8 ? "strongly possible" : "possible", shot: jpeg
        ))
        scheduleLogFlush()
    }

    fileprivate func publishPlates(_ plates: [String], at time: TimeInterval) {
        guard isProtecting else { return }
        for plate in plates {
            guard let event = plateTracker.observe(plate, at: time) else { continue }
            let jpeg = event.rating == "possible" ? pipeline.frameBuffer.snapshot().frames.last : nil
            evidenceLog.add(LogItem(
                type: "plate", text: event.text, rating: event.rating, shot: jpeg, count: event.count
            ))
            AppLog.shared.event("plate_seen", ["rating": event.rating])
        }
        scheduleLogFlush()
    }

    private var logTarget: (id: String, session: String)? {
        if sosActive, let id = incidentID, let session = evidenceSessionID { return (id, session) }
        if liveStreaming, let id = liveIncidentID, let session = evidenceSessionID { return (id, session) }
        if let id = watchIncidentID, let session = watchSessionID { return (id, session) }
        return nil
    }

    private var watchIncidentID: String?
    private var watchSessionID: String?
    private var watchTimer: Timer?

    private func startWatch() {
        guard watchIncidentID == nil, let guardianCode = LiveLinkStore.shared.guardianCode,
              !guardianCode.isEmpty
        else { return }
        let session = EvidenceSessionID.make()
        Task {
            do {
                let result = try await incidentClient.startIncident(
                    sessionID: session,
                    wearerName: wearerName.isEmpty ? String(localized: "Someone") : wearerName,
                    contactCodes: [], dryRun: true, mode: "watch", guardianCode: guardianCode
                )
                guard isProtecting, watchIncidentID == nil else {
                    _ = try? await incidentClient.endIncident(result.id)
                    return
                }
                watchIncidentID = result.id
                watchSessionID = session
                scheduleLogFlush()
                watchTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.watchBeat() }
                }
            } catch {
                AppLog.shared.event("watch_failed", ["error": error.localizedDescription])
            }
        }
    }

    private func watchBeat() {
        guard let id = watchIncidentID else { return }
        if evidenceLog.count > 0 || !pendingItemPayload.isEmpty || !pendingTranscript.isEmpty {
            scheduleLogFlush()
        } else {
            Task { try? await incidentClient.postItems(incidentID: id, items: []) }
        }
    }

    private func stopWatch() {
        watchTimer?.invalidate()
        watchTimer = nil
        if let id = watchIncidentID {
            Task { _ = try? await incidentClient.endIncident(id) }
        }
        watchIncidentID = nil
        watchSessionID = nil
    }

    private func scheduleLogFlush() {
        guard logTarget != nil, !logFlushScheduled else { return }
        logFlushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            self.logFlushScheduled = false
            if let target = self.logTarget {
                await self.flushEvidenceLog(incident: target.id, session: target.session)
            }
        }
    }

    private var pendingTranscript: [[String: Any]] = []

    private func noteTranscript(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isProtecting, listenerOptIn, clean.count >= 2 else { return }
        pendingTranscript.append(["t": Date().timeIntervalSince1970, "text": String(clean.prefix(300))])
        if pendingTranscript.count > 200 { pendingTranscript.removeFirst(pendingTranscript.count - 200) }
        scheduleLogFlush()
    }

    private func flushTranscript(incident: String) async {
        guard !pendingTranscript.isEmpty else { return }
        let batch = Array(pendingTranscript.prefix(40))
        do {
            try await incidentClient.postTranscript(incidentID: incident, lines: batch)
            pendingTranscript.removeFirst(min(batch.count, pendingTranscript.count))
        } catch {
            AppLog.shared.event("transcript_failed", ["pending": String(pendingTranscript.count)])
        }
    }

    private func flushEvidenceLog(incident: String, session: String) async {
        await flushTranscript(incident: incident)
        for item in evidenceLog.drain() {
            var shotName: String?
            if let data = item.shot {
                shotSeq += 1
                let name = EvidenceSegmentName.filename(kind: .shot, seq: shotSeq)
                shotName = name
                uploadShot(data, name: name, seq: shotSeq, session: session)
            }
            pendingItemPayload.append(item.json(shotName: shotName))
        }
        guard !pendingItemPayload.isEmpty else { return }
        let batch = Array(pendingItemPayload.prefix(40))
        do {
            try await incidentClient.postItems(incidentID: incident, items: batch)
            pendingItemPayload.removeFirst(batch.count)
        } catch {
            if case VerifierError.serverStatus(let code) = error, (400..<500).contains(code), code != 429 {
                pendingItemPayload.removeFirst(min(batch.count, pendingItemPayload.count))
            }
            AppLog.shared.event("items_failed", [
                "pending": String(pendingItemPayload.count), "error": error.localizedDescription,
            ])
        }
    }

    private func uploadShot(_ data: Data, name: String, seq: Int, session: String) {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Evidence", isDirectory: true)
            .appendingPathComponent(session, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name)
        guard (try? data.write(to: file, options: .atomic)) != nil else { return }
        let uploader = shotUploader
        Task.detached {
            if await uploader.upload(file: file, sessionID: session, kind: .shot, seq: seq) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private func logCue(_ event: String, kind: String, score: Double, at time: TimeInterval, every: TimeInterval) {
        let key = "\(event):\(kind)"
        guard time - (lastGestureLog[key] ?? -.infinity) >= every else { return }
        lastGestureLog[key] = time
        AppLog.shared.event(event, ["cue": kind, "score": String(format: "%.2f", score)])
    }

    @Published var latencyLine = ""
    private var latencyTicks = 0

    private func updateLatency() {
        let stages = ["persons", "pose", "hands", "face"]
        latencyLine = LatencyMeter.shared.summary(stages: stages)
        latencyTicks += 1
        guard latencyTicks % 10 == 0, !latencyLine.isEmpty else { return }
        var fields: [String: String] = [:]
        for stage in stages {
            if let stats = LatencyMeter.shared.stats(stage) {
                fields[stage] = String(format: "%.0f/%.0f", stats.meanMs, stats.p95Ms)
            }
        }
        AppLog.shared.event("latency_ms_mean_p95", fields)
    }

    private func tickFps() {
        updateLatency()
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
        let topScore = scores.values.max() ?? 0
        let nowSeconds = Self.now
        threatAlert = pipeline.config.nextAlert(
            wasAlert: wasAlert, topScore: topScore, now: nowSeconds, lastAbove: lastAlertAbove
        )
        if topScore >= pipeline.config.alertThreshold { lastAlertAbove = nowSeconds }
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

    static func museSeesLine(objectHeld: String, level: String) -> String {
        let object = objectHeld.isEmpty ? String(localized: "nothing in hand") : objectHeld
        return L10n.format("Muse sees: %@ • threat %@", object, level)
    }

    fileprivate func publishVerification(_ result: VerifyResult) {
        guard isProtecting else { return }
        lastVerifyResult = L10n.format("Verify: %@ via %@ (%@)", result.threatLevel, result.path, result.reason)
        AppLog.shared.event("vision_verify", [
            "level": result.threatLevel, "path": result.path, "reason": result.reason,
            "object": result.objectHeld,
            "ms": String(Int(result.museLatencyMs)),
        ])
        verifyFailure = nil
        museSees = Self.museSeesLine(objectHeld: result.objectHeld, level: result.threatLevel)
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
    }

    func answerSafe() {
        safety.noteReply(.safePhrase, at: Self.now)
        syncProtectionState()
    }

    func answerUnsafe() {
        safety.noteReply(.unsafePhrase, at: Self.now)
        syncProtectionState()
    }

    #if DEBUG
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

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    @Published var idleBackendReachable: Bool?
    @Published var idleBackendLatencyMs: Int?
    @Published var idleMuseConfigured: Bool?
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
            if !status.reachable, !offlineMessageSaid {
                offlineMessageSaid = true
                confirm(String(localized: "Verification is offline"))
            }
        }
    }

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

    @AppStorage("distressWordsEnabled") var distressWordsEnabled = Defaults.current.distressWordsEnabled
    @Published var countdownDeadline: TimeInterval?
    @Published var evidenceStatus: String?
    @AppStorage("recordOnSOS") var recordOnSOS = Defaults.current.recordOnSOS
    nonisolated let evidence = EvidenceCapture()
    private var cancellables = Set<AnyCancellable>()
    @AppStorage("shoutingTriggersSOS") var shoutingTriggersSOS = Defaults.current.shoutingTriggersSOS
    private var loudness = LoudnessDetector(sensitivity: .current)
    private var levelPeak: Float = -120
    private var levelLoggedAt: TimeInterval = 0
    private let distressMatcher = DistressMatcher()
    private var pendingDistressStart = false
    private var countdownTimer: Timer?

    func cancelAutoSOS() {
        AppLog.shared.event("countdown_cancel", ["by": "button"])
        safety.cancelCountdown(at: Self.now)
        syncProtectionState()
        showToast(String(localized: "Auto-SOS cancelled"))
    }

    private func beginCountdown() {
        countdownDeadline = Self.now + safetyConfig.autoSosSeconds
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

    private func startEvidence(force: Bool = false) {
        guard force || recordOnSOS, !usingReplay, !evidence.isRecording else { return }
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
        listener.setAudioSink { [evidence] buffer, when in evidence.appendAudio(buffer, at: when) }
        evidenceStatus = EvidenceProgress().summary
    }

    private func stopEvidence() {
        listener.setAudioSink(nil)
        evidence.stop()
    }

    func manualSOS() {
        AppLog.shared.event("manual_sos")
        distressHeard()
    }

    private func distressHeard() {
        AppLog.shared.event("distress", ["protecting": "true"])
        safety.noteDistressWord(at: Self.now)
        syncProtectionState()
    }

    func safeArrivalExpired() {
        AppLog.shared.event("safe_arrival_expired", [:])
        pendingTimerCause = true
        if state == .idle {
            guard !pendingDistressStart else { return }
            pendingDistressStart = true
            Task {
                await startCamera()
                if state == .idle { pendingDistressStart = false }
            }
        } else {
            distressHeard()
        }
    }

    private func distressHeardWhileIdle() {
        guard distressWordsEnabled, !pendingDistressStart else { return }
        AppLog.shared.event("distress", ["protecting": "false", "action": "auto-start"])
        pendingDistressStart = true
        Task {
            await startCamera()
            if state == .idle { pendingDistressStart = false }
        }
    }

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
            if mapped == .asking || mapped == .suspected || mapped == .unsafe || mapped == .countdown {
                dimmed = false
            }
            if mapped == .countdown {
                beginCountdown()
            } else if previous == .countdown {
                endCountdown()
                if mapped != .unsafe {
                    pendingShoutCause = false
                    pendingGestureCause = false
                    pendingTimerCause = false
                }
            }
            if mapped == .asking, previous != .asking {
                askTrigger = conversationFlag != nil ? "flag" : "checkin"
            }
            if mapped == .unsafe {
                startEvidence()
                startEscalation()
            }
            if previous == .unsafe, mapped == .safe, sosActive {
                endSOS()
            }
            announce(mapped)
        }
    }

    var listeningCue: String? {
        safety.state == .listening ? safetyConfig.listeningCueText : nil
    }

    private func announce(_ state: ProtectionState) {
        switch state {
        case .suspected:
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

    private var contextWords: [String] {
        (safetyConfig.distressWords + safetyConfig.safePhrases + safetyConfig.unsafePhrases
            + ["Safeguard", "stop protecting"]).prefix(60).map { $0 }
    }

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

    private var lastPartialLog: (text: String, at: TimeInterval) = ("", 0)

    fileprivate func handlePartial(_ text: String, source: TranscriptSource) {
        if source == .cloud { sourcePolicy.noteCloud(at: Self.now) }
        if text != lastPartialLog.text, Self.now - lastPartialLog.at >= 0.8 {
            lastPartialLog = (text, Self.now)
            AppLog.shared.event("partial", [
                "text": text, "protecting": String(isProtecting), "src": source.rawValue,
            ])
        }
        let feedsConversation = source == .cloud || sourcePolicy.appleMayFeedConversation(at: Self.now)
        guard isProtecting else {
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
            if !aiJudgeEnabled { spotNames(text) }
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
            if alreadyHandled == reply { return }
            safety.noteReply(reply, at: Self.now)
            drainAskSpeech()
            syncProtectionState()
            return
        }
        let now = Self.now
        if stopConfirmation.isPending(at: now) {
            if commandParser.parse(text) != nil {
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
                    break
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
        if !aiJudgeEnabled { spotNames(text) }
        noteTranscript(text)
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

    private var hapticGate = SpeechHapticGate()
    private var judgeSchedule = SpeechJudgeSchedule()
    @AppStorage("aiJudgeEnabled") var aiJudgeEnabled = Defaults.current.aiJudgeEnabled

    private func rateChunk(_ text: String) {
        vibrate(SpeechHapticLevel.level(for: speechMatcher.match(text)?.severity ?? 0))
    }

    private func vibrate(_ wanted: SpeechHapticLevel) {
        let level = hapticGate.consume(wanted, at: Self.now)
        if level != .none { AppLog.shared.event("vibrate", ["level": String(describing: level)]) }
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

    private func judgeConversation(partial: String? = nil) {
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
                recordNames(result.names, snippet: snippet)
            } catch {
                judgeSchedule.finished()
                judgeStatus = L10n.format("AI judge failed: %@", error.localizedDescription)
                AppLog.shared.event("judge_failed", ["error": error.localizedDescription])
                spotNames(snippet)
                if let onDevice {
                    publishSpeechFallback(severity: onDevice.severity, category: onDevice.category.rawValue)
                }
            }
        }
    }

    private var namesRecorded: [String: String] = [:]
    private var nameLastCounted: [String: TimeInterval] = [:]

    private func spotNames(_ text: String) {
        guard isProtecting, listenerOptIn else { return }
        let fresh = NameSpotter.names(in: text).filter {
            let key = $0.name.lowercased()
            if let seen = namesRecorded[key], seen == "strongly possible" || seen == $0.rating { return false }
            namesRecorded[key] = $0.rating
            return true
        }
        recordNames(fresh, snippet: text)
    }

    private func recordNames(_ names: [SpokenName], snippet: String) {
        guard isProtecting, !names.isEmpty else { return }
        let source = String(snippet.suffix(120))
        let now = Self.now
        let rank = ["possible": 1, "strongly possible": 2]
        for name in names {
            let key = name.name.lowercased()
            let upgraded = (rank[name.rating] ?? 0) > (rank[namesRecorded[key] ?? ""] ?? 0)
            if let last = nameLastCounted[key], now - last < 15, !upgraded { continue }
            nameLastCounted[key] = now
            if upgraded || namesRecorded[key] == nil { namesRecorded[key] = name.rating }
            evidenceLog.add(LogItem(type: "name", text: name.name, rating: name.rating, source: source))
        }
        AppLog.shared.event("names_heard", ["count": String(names.count)])
        scheduleLogFlush()
    }

    private func publishJudgement(_ result: SpeechVerifyResult, onDevice: SpeechMatch?) {
        guard isProtecting else { return }
        let severity = SpeechMatcher.backendSeverity(result.severity)
        publishSpeechResult(result, onDeviceSeverity: onDevice?.severity ?? 0)
        guard severity >= ConversationFlag.minSeverity else {
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

    func launchSafetyFromFlag() {
        conversationFlag = nil
        answerUnsafe()
    }

    private let motionManager = CMMotionManager()
    private var recentAccel: [Double] = []

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
        case .callEmergency:
            confirm(String(localized: "Calling 112"))
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
        safety.noteSpeech(severity: severity, at: Self.now)
        noteSpeechToPipeline(severity: severity, at: Self.now)
        drainAskSpeech()
        syncProtectionState()
        lastSpeechInfo = L10n.format("Speech: %@ on-device (verification offline)", category)
    }

    private func startEscalation() {
        guard !sosActive else { return }
        if liveStreaming {
            liveStreaming = false
            liveTimer?.invalidate()
            liveTimer = nil
        }
        sosActive = true
        sosStartedAt = Date()
        sosCause = resolveSosCause()
        pendingShoutCause = false
        pendingGestureCause = false
        pendingTimerCause = false
        escalation = EscalationCoordinator()
        escalation.start()
        shotSeq = 0
        pendingItemPayload = []
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

    func endSOSButtonHeld() {
        safety.endUnsafe(at: Self.now)
        syncProtectionState()
    }

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
            let session = evidenceSessionID ?? ""
            Task {
                await flushEvidenceLog(incident: id, session: session)
                try? await incidentClient.endIncident(id)
            }
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

    private var incidentStartTask: Task<Bool, Never>?

    private func ensureIncident() async -> Bool {
        if incidentID != nil { return true }
        if let pending = incidentStartTask { return await pending.value }
        let task = Task { await self.startIncidentOnce() }
        incidentStartTask = task
        let ok = await task.value
        incidentStartTask = nil
        return ok
    }

    private func startIncidentOnce() async -> Bool {
        if incidentID != nil { return true }
        guard let session = evidenceSessionID else { return false }
        if let live = liveIncidentID {
            liveIncidentID = nil
            _ = try? await incidentClient.endIncident(live)
        }
        let fix = locationTracker.latest
        do {
            let result = try await incidentClient.startIncident(
                sessionID: session,
                wearerName: wearerName.isEmpty ? String(localized: "Someone") : wearerName,
                contactCodes: sosContacts.linkedCodes,
                dryRun: !sendRealAlerts,
                latitude: fix?.coordinate.latitude,
                longitude: fix?.coordinate.longitude,
                channelToken: LiveLinkStore.shared.token,
                guardianCode: LiveLinkStore.shared.guardianCode
            )
            incidentID = result.id
            liveURL = result.liveURL
            deliveryStatus = result.delivery
            scheduleLogFlush()
            return true
        } catch {
            return false
        }
    }

    private func runContactsTrack() async {
        guard sosActive else { return }
        if await ensureIncident() {
            trackDone(.contacts)
        } else {
            trackFailed(.contacts, reason: String(localized: "could not reach backend"))
        }
    }

    private func runStreamTrack() async {
        guard sosActive else { return }
        if await ensureIncident(), liveURL != nil {
            trackDone(.stream)
        } else {
            trackFailed(.stream, reason: String(localized: "live page unavailable"))
        }
    }

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

    private func runCabTrack() async {
        guard sosActive else { return }
        guard locationTracker.latest != nil else {
            trackFailed(.cab, reason: RouteChoice.noLocationMessage)
            return
        }
        trackDone(.cab)
    }

    var ridePickup: UberDeepLink.Place? {
        guard let fix = locationTracker.latest else { return nil }
        return UberDeepLink.Place(
            latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude,
            nickname: String(localized: "SOS: my location")
        )
    }

    var rideDropoff: UberDeepLink.Place? {
        guard let point = sosDestinationCoordinate else { return nil }
        return UberDeepLink.Place(
            latitude: point.latitude, longitude: point.longitude,
            nickname: sosDestinationName ?? String(localized: "Safe place")
        )
    }

    func openUberRide() {
        guard let pickup = ridePickup else {
            showToast(RouteChoice.noLocationMessage)
            return
        }
        AppLog.shared.event("uber_open", ["dropoff": rideDropoff == nil ? "none" : "set"])
        if let url = UberDeepLink.appURL(pickup: pickup, dropoff: rideDropoff),
           UIApplication.shared.canOpenURL(url)
        {
            UIApplication.shared.open(url)
        } else if let url = UberDeepLink.webURL(pickup: pickup, dropoff: rideDropoff) {
            UIApplication.shared.open(url)
        }
    }

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

    @Published private(set) var liveStreaming = false
    private var liveIncidentID: String?
    private var liveTimer: Timer?

    func startLiveStream() async {
        guard !liveStreaming, !sosActive else { return }
        guard LiveLinkStore.shared.url != nil else {
            showToast(String(localized: "Create your live link first"))
            return
        }
        if !isProtecting {
            await startCamera()
        }
        guard isProtecting else { return }
        liveStreaming = true
        locationTracker.requestPermission()
        locationTracker.start()
        startEvidence(force: true)
        let session = evidenceSessionID ?? EvidenceSessionID.make()
        evidenceSessionID = session
        let fix = locationTracker.latest
        do {
            let result = try await incidentClient.startIncident(
                sessionID: session,
                wearerName: wearerName.isEmpty ? String(localized: "Someone") : wearerName,
                contactCodes: [], dryRun: true,
                latitude: fix?.coordinate.latitude, longitude: fix?.coordinate.longitude,
                mode: "live",
                channelToken: LiveLinkStore.shared.token,
                guardianCode: LiveLinkStore.shared.guardianCode
            )
            liveIncidentID = result.id
            AppLog.shared.event("live_start", ["session": session])
            liveTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.streamLiveLocation() }
            }
            showToast(String(localized: "You are live. Share your link with who you choose."))
        } catch {
            liveStreaming = false
            stopEvidence()
            locationTracker.stop()
            showToast(String(localized: "Could not start the live stream"))
        }
    }

    func stopLiveStream() {
        guard liveStreaming else { return }
        liveStreaming = false
        liveTimer?.invalidate()
        liveTimer = nil
        if let id = liveIncidentID {
            liveIncidentID = nil
            Task { _ = try? await incidentClient.endIncident(id) }
        }
        if !sosActive {
            stopEvidence()
            locationTracker.stop()
        }
        AppLog.shared.event("live_end")
        showToast(String(localized: "Live stream ended"))
    }

    private func streamLiveLocation() {
        guard liveStreaming, let id = liveIncidentID, let fix = locationTracker.latest else { return }
        Task {
            try? await incidentClient.sendLocation(
                incidentID: id, latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude,
                accuracy: fix.horizontalAccuracy >= 0 ? fix.horizontalAccuracy : nil,
                timestamp: fix.timestamp.timeIntervalSince1970
            )
        }
    }

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

    @Published private(set) var staleContactCodes: Set<String> = []

    func refreshContacts() {
        Task {
            for contact in sosContacts.contacts where !contact.linked {
                do {
                    let status = try await incidentClient.contactStatus(code: contact.code)
                    sosContacts.setLinked(code: contact.code, linked: status.linked)
                    staleContactCodes.remove(contact.code)
                } catch VerifierError.serverStatus(404) {
                    staleContactCodes.insert(contact.code)
                } catch {
                }
            }
            saveContacts()
        }
    }

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
        startListener()
    }

    func stopPhrasePractice() {
        practicingPhrases = false
    }

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

    @Published var history = IncidentHistory()
    @Published private(set) var sosStartedAt: Date?
    private var sosCause: String?
    private var lastEvidenceProgress = EvidenceProgress()
    private var pendingShoutCause = false
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
            if pendingTimerCause { return "safeArrival" }
            if pendingGestureCause { return "gestures" }
            return pendingShoutCause ? "shouting" : "distressWord"
        case .noReply, .none:
            return askTrigger == "flag" ? "flag" : "noReply"
        }
    }

    func deleteAllMyData(keepingSetup: Bool = false) async -> DataWipeReport? {
        guard !sosActive else {
            showToast(String(localized: "End the SOS first"))
            return nil
        }
        let sessions = Set(history.entries.compactMap(\.evidenceSessionID))
        let codes = sosContacts.contacts.map(\.code)
        var accountDeleted: Bool?
        if AccountStore.shared.isSignedIn {
            accountDeleted = await AccountStore.shared.deleteAccount()
        }
        AccountStore.shared.clearLocal()
        if LiveLinkStore.shared.url != nil {
            let revoked = await LiveLinkStore.shared.deleteLink()
            if !revoked { LiveLinkStore.shared.forgetLink() }
        }
        LiveLinkStore.shared.clearGuardian()
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
    var verifyThrottle: VerifyThrottle
    let frameBuffer = FrameBuffer()
    let plateScanner = PlateScanner()
    var lastPlateScan = Date.distantPast
    var lastDetect = Date.distantPast
    let detectInterval: TimeInterval = 0.1

    init(config: ThreatConfig = ThreatConfig()) {
        self.config = config
        self.detector = PersonDetector(poseMatchDistance: config.poseMatchDistance)
        self.extractor = FeatureExtractor(config: config)
        self.scorer = ThreatScorer(config: config)
        self.proximityTracker = ProximityTracker(config: config)
        self.verifierGate = VerifierGate(config: config)
        self.sweepGate = NearSweepGate(config: config)
        self.verifyThrottle = VerifyThrottle(config: config)
    }

    func reset() {
        tracker.reset()
        extractor.reset()
        proximityTracker.reset()
        verifierGate.reset()
        sweepGate.reset()
        verifyThrottle.reset()
        frameBuffer.clear()
    }

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
        let frameCues = detector.lastFrameCues
        Task { await owner.publishFrameCues(frameCues, at: nowSeconds) }
        if now.timeIntervalSince(lastPlateScan) >= 0.8 {
            lastPlateScan = now
            let plates = plateScanner.scan(frame.pixelBuffer)
            if !plates.isEmpty { Task { await owner.publishPlates(plates, at: nowSeconds) } }
        }
        let tracks = tracker.update(detections: people)
        let live = tracks.filter { $0.missed == 0 }
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
        if verifyThrottle.consume(wanted: alertFired || sweepDue, at: nowSeconds) {
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

private final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
    func reset() { lock.withLock { count = 0 } }
}

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
