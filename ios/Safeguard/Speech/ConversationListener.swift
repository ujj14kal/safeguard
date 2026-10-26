import AVFoundation
import Speech

/// Final transcripts arrive once per finished utterance. Partial transcripts
/// (the growing text of the utterance in progress) arrive too, so the code
/// phrases are heard within a word or two instead of after a pause.
protocol ConversationListenerDelegate: AnyObject {
    func listener(_ listener: ConversationListener, didTranscribe text: String)
    func listener(_ listener: ConversationListener, didHearPartial text: String)
}

/// The ONE audio engine + speech recognizer for everything voice. It only
/// transcribes (final utterances, on-device); the view model decides what
/// each transcript feeds. Code phrases and voice commands always run;
/// threat scanning (window, matcher, /verify-speech) is opt-in and guarded
/// in the view model, so with the toggle off transcripts are scanned and
/// dropped immediately and no window is ever built.
///
/// Privacy, enforced structurally: transcription is on-device only
/// (`requiresOnDeviceRecognition`, no server fallback); raw audio buffers
/// are never stored. This file has no file, network, or log call that could
/// carry audio or transcript text.
@MainActor
final class ConversationListener: ObservableObject {
    weak var delegate: ConversationListenerDelegate?

    /// True only while actually transcribing.
    @Published private(set) var isLive = false
    /// Why the mic is deaf (permission, interruption, error). Nil when live.
    @Published private(set) var deafReason: String?

    private var session: ListeningSession
    private var recognizer: SFSpeechRecognizer?
    private var engine: AVAudioEngine?
    /// The request the tap feeds. Lock-boxed: the audio tap appends on a
    /// realtime thread (Apple's own pattern — no actor hop per buffer)
    /// while restarts swap it from the main actor.
    private let requestBox = RequestBox()
    private var task: SFSpeechRecognitionTask?
    private var restartTimer: Timer?
    private var interruptionObserver: NSObjectProtocol?

    private final class RequestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var boxed: SFSpeechAudioBufferRecognitionRequest?

        var request: SFSpeechAudioBufferRecognitionRequest? {
            get { lock.withLock { boxed } }
            set { lock.withLock { boxed = newValue } }
        }
    }

    init(speechConfig: SpeechConfig = SpeechConfig()) {
        self.session = ListeningSession(config: speechConfig)
    }

    // MARK: - Permissions

    /// Microphone + speech recognition, both required. Call before `start`.
    static func requestPermissions() async -> Bool {
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        return mic && speech
    }

    // MARK: - Run

    func start() {
        stop()
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            goDeaf("Speech recognition unavailable")
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            // Hard rule: on-device or nothing. Never fall back to server
            // recognition, which would upload the wearer's audio.
            goDeaf("On-device speech recognition unavailable")
            return
        }
        do {
            try configureAudioSession()
        } catch {
            goDeaf("Could not start audio (\(error.localizedDescription))")
            return
        }
        self.recognizer = recognizer
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // One tap for the whole run: every buffer reaches exactly one
        // recognition request, so restarts have no gap.
        let box = requestBox
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            box.request?.append(buffer)
        }
        do {
            try engine.start()
        } catch {
            goDeaf("Could not start audio (\(error.localizedDescription))")
            return
        }
        session.start(at: Self.now)
        startRequest()
        restartTimer?.invalidate()
        restartTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.restartIfDue() }
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in self?.handleInterruption(note) }
        }
        publishState()
    }

    func stop() {
        restartTimer?.invalidate()
        restartTimer = nil
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
        task?.cancel()
        task = nil
        requestBox.request?.endAudio()
        requestBox.request = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        recognizer = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        session.stop()
        publishState()
    }

    // MARK: - Private

    /// Play-and-record with the camera running: the mic stays hot while the
    /// speaker says the check-in question; other audio ducks under us.
    private func configureAudioSession() throws {
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers])
        try audio.setActive(true)
    }

    private func startRequest() {
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        // Partials keep the safety-critical code phrases low-latency; the
        // threat scan still only sees final text.
        request.shouldReportPartialResults = true
        requestBox.request = request
        let generation = session.generation
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                self?.handleResult(result, error: error, generation: generation)
            }
        }
    }

    private func handleResult(
        _ result: SFSpeechRecognitionResult?, error: Error?, generation: Int?
    ) {
        if let error {
            // A stale task's error (routine restart cancel) is not deaf.
            // Stale RESULTS still count: they cover pre-swap audio the new
            // request never saw, so dropping them would miss real speech.
            if generation != session.generation {
                return
            }
            goDeaf("Recognition failed (\(error.localizedDescription))")
            return
        }
        guard let result else { return }
        let text = result.bestTranscription.formattedString
        guard !text.isEmpty else { return }
        if result.isFinal {
            delegate?.listener(self, didTranscribe: text)
        } else {
            delegate?.listener(self, didHearPartial: text)
        }
    }

    private func restartIfDue() {
        if session.restartIfDue(at: Self.now) {
            swapRequest()
        }
        publishState()
    }

    /// Swap recognition requests with no gap: the new request is live
    /// before the old one ends, and the tap never stops, so every buffer
    /// reaches exactly one request.
    private func swapRequest() {
        let oldRequest = requestBox.request
        startRequest()
        // endAudio (not cancel): the old task must finish and deliver its
        // final result, or the last stretch of speech would be lost.
        oldRequest?.endAudio()
    }

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw)
        else {
            return
        }
        switch type {
        case .began:
            task?.cancel()
            task = nil
            requestBox.request?.endAudio()
            requestBox.request = nil
            session.noteInterruption()
            publishState()
        case .ended:
            // Come back by ourselves when the call/Siri ends: the wearer
            // must not have to remember to re-arm protection.
            let options = (info[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            if AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) {
                session.start(at: Self.now)
                startRequest()
                publishState()
            }
        @unknown default:
            break
        }
    }

    private func goDeaf(_ reason: String) {
        session.noteError(reason)
        // Published directly (no publishState): failures before start leave
        // the session idle, but the UI must still show the reason.
        isLive = false
        deafReason = reason
    }

    private func publishState() {
        isLive = session.isLive
        switch session.state {
        case .deaf(let reason):
            deafReason = reason
        case .idle, .listening:
            deafReason = nil
        }
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}
