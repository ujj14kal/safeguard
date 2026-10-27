import AVFoundation
import Speech

/// Final transcripts arrive once per finished utterance. Partial transcripts
/// (the growing text of the utterance in progress) arrive too, so the code
/// phrases are heard within a word or two instead of after a pause.
protocol ConversationListenerDelegate: AnyObject {
    func listener(_ listener: ConversationListener, didTranscribe text: String, source: TranscriptSource)
    func listener(_ listener: ConversationListener, didHearPartial text: String, source: TranscriptSource)
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

    /// BCP-47 locale of the recogniser (see `SpeechLocale`). Set before `start`.
    var localeIdentifier = SpeechLocale.english

    /// True only while actually transcribing.
    @Published private(set) var isLive = false
    /// Why the mic is deaf (permission, interruption, error). Nil when live.
    @Published private(set) var deafReason: String?
    /// The latest transcript text, for the Debug overlay only. It lives in
    /// memory, is replaced by the next utterance and cleared on stop.
    @Published private(set) var lastHeard = ""

    private var session: ListeningSession
    private var recognizer: SFSpeechRecognizer?
    private var engine: AVAudioEngine?
    /// The request the tap feeds. Lock-boxed: the audio tap appends on a
    /// realtime thread (Apple's own pattern — no actor hop per buffer)
    /// while restarts swap it from the main actor.
    private let requestBox = RequestBox()
    private let sinkBox = SinkBox()
    private let levelBox = LevelBox()
    private let cloud = CloudEar()

    /// The cloud ear's state, for the Debug line and Settings.
    @Published private(set) var cloudStatus = CloudEarState.off.summary
    @Published private(set) var cloudIsLive = false

    /// Sets up the cloud ear's callbacks. Call once.
    func configureCloudEar() {
        cloud.configure(
            onText: { [weak self] text, isFinal in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.lastHeard = text
                    if isFinal {
                        self.delegate?.listener(self, didTranscribe: text, source: .cloud)
                    } else {
                        self.delegate?.listener(self, didHearPartial: text, source: .cloud)
                    }
                }
            },
            onState: { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.cloudStatus = state.summary
                    self.cloudIsLive = state == .live
                    AppLog.shared.event("cloud_ear", ["state": state.summary])
                }
            }
        )
    }

    /// Turns the cloud ear on or off. Apple's recogniser keeps running
    /// either way.
    func setCloudEar(_ on: Bool) {
        if on { cloud.start() } else { cloud.stop() }
    }
    private let gainBox = GainBox()

    /// Words the recogniser should favour (distress words, code phrases, key
    /// threats). Set before `start`; Apple recommends well under ~100.
    var contextualStrings: [String] = []

    /// Called on the audio thread with each buffer's raw level (dBFS RMS).
    func setLevelHandler(_ handler: (@Sendable (Float) -> Void)?) {
        levelBox.handler = handler
    }

    private final class LevelBox: @unchecked Sendable {
        private let lock = NSLock()
        private var boxed: (@Sendable (Float) -> Void)?
        var handler: (@Sendable (Float) -> Void)? {
            get { lock.withLock { boxed } }
            set { lock.withLock { boxed = newValue } }
        }
    }

    /// Lifts quiet speech for the recogniser (the recorder keeps raw audio).
    private final class GainBox: @unchecked Sendable {
        private let lock = NSLock()
        private var autoGain = AutoGain(sensitivity: .current)
        private var buffersSinceCheck = 0

        func boosted(_ buffer: AVAudioPCMBuffer, rms: Float) -> AVAudioPCMBuffer {
            let gain = lock.withLock { () -> Float in
                // A Settings change takes effect within about a second.
                buffersSinceCheck += 1
                if buffersSinceCheck >= 10 {
                    buffersSinceCheck = 0
                    autoGain.apply(.current)
                }
                return autoGain.update(rms: rms)
            }
            guard gain > 1.05, let source = buffer.floatChannelData,
                  let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
                  let target = copy.floatChannelData
            else { return buffer }
            copy.frameLength = buffer.frameLength
            for channel in 0..<Int(buffer.format.channelCount) {
                for frame in 0..<Int(buffer.frameLength) {
                    target[channel][frame] = max(-1, min(1, source[channel][frame] * gain))
                }
            }
            return copy
        }
    }

    static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        let count = Int(buffer.frameLength)
        for frame in 0..<count { sum += data[0][frame] * data[0][frame] }
        return (sum / Float(count)).squareRoot()
    }

    /// Receives every microphone buffer (the SOS recorder). Nil normally.
    func setAudioSink(_ sink: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?) {
        sinkBox.handler = sink
    }

    private final class SinkBox: @unchecked Sendable {
        private let lock = NSLock()
        private var boxed: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?

        var handler: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)? {
            get { lock.withLock { boxed } }
            set { lock.withLock { boxed = newValue } }
        }
    }
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
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.isAvailable
        else {
            goDeaf(L10n.format("Speech recognition unavailable for %@", localeIdentifier))
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            // Apple's recogniser is the always-on local tier: on-device or
            // nothing. (The cloud ear is a separate, visible, optional tier.)
            goDeaf(L10n.format("On-device speech for %@ is not available on this iPhone", localeIdentifier))
            return
        }
        AppLog.shared.event("listener_start", ["engine": "apple", "locale": localeIdentifier])
        do {
            try configureAudioSession()
        } catch {
            goDeaf(L10n.format("Could not start audio (%@)", error.localizedDescription))
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
        let sink = sinkBox
        let levels = levelBox
        let gains = gainBox
        let ear = cloud
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, when in
            let rms = Self.rms(of: buffer)
            levels.handler?(20 * log10(max(rms, 1e-6)))
            sink.handler?(buffer, when)
            let boosted = gains.boosted(buffer, rms: rms)
            box.request?.append(boosted)
            ear.feed(boosted)
        }
        do {
            try engine.start()
        } catch {
            goDeaf(L10n.format("Could not start audio (%@)", error.localizedDescription))
            return
        }
        session.start(at: Self.now)
        restartTimer?.invalidate()
        restartTimer = nil
        startRequest()
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
        lastHeard = ""
        publishState()
    }

    // MARK: - Private

    /// Play-and-record with the camera running: the mic stays hot while the
    /// speaker says the check-in question; other audio ducks under us.
    private func configureAudioSession() throws {
        let audio = AVAudioSession.sharedInstance()
        // .default mode: the processing modes (voice chat, measurement)
        // either cut quiet speech or turn gain off. Hear everything, and let
        // our own gain stage level it for the recogniser.
        try audio.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
        try audio.setActive(true)
    }

    private func startRequest() {
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        // Partials keep the safety-critical code phrases low-latency; the
        // threat scan still only sees final text.
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.contextualStrings = contextualStrings
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
            // A stale task's error (routine restart cancel) is ignored.
            // Stale RESULTS still count: they cover pre-swap audio the new
            // request never saw, so dropping them would miss real speech.
            if generation != session.generation {
                return
            }
            // "No speech detected" and similar end the task quietly; the
            // recogniser then sends nothing more. Start a new request.
            restartAfterTaskEnd()
            return
        }
        guard let result else { return }
        let text = result.bestTranscription.formattedString
        if !text.isEmpty {
            lastHeard = text
            if result.isFinal {
                delegate?.listener(self, didTranscribe: text, source: .apple)
            } else {
                delegate?.listener(self, didHearPartial: text, source: .apple)
            }
        }
        // A final result ends the task: without a new request the mic would
        // be deaf until the 50 s restart.
        if result.isFinal, generation == session.generation {
            restartAfterTaskEnd()
        }
    }

    private func restartAfterTaskEnd() {
        switch session.noteTaskEnded(at: Self.now) {
        case .restart:
            swapRequest()
        case .deaf(let reason):
            goDeaf(reason)
        }
        publishState()
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
