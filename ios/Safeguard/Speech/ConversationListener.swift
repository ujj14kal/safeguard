import AVFoundation
import Speech

protocol ConversationListenerDelegate: AnyObject {
    func listener(_ listener: ConversationListener, didTranscribe text: String, source: TranscriptSource)
    func listener(_ listener: ConversationListener, didHearPartial text: String, source: TranscriptSource)
}

@MainActor
final class ConversationListener: ObservableObject {
    weak var delegate: ConversationListenerDelegate?

    var localeIdentifier = SpeechLocale.english

    @Published private(set) var isLive = false
    @Published private(set) var deafReason: String?
    @Published private(set) var lastHeard = ""

    private var session: ListeningSession
    private var recognizer: SFSpeechRecognizer?
    private var engine: AVAudioEngine?
    private let requestBox = RequestBox()
    private let sinkBox = SinkBox()
    private let levelBox = LevelBox()
    private let cloud = CloudEar()

    @Published private(set) var cloudStatus = CloudEarState.off.summary
    @Published private(set) var cloudIsLive = false

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

    func setCloudEar(_ on: Bool) {
        if on { cloud.start() } else { cloud.stop() }
    }
    private let gainBox = GainBox()

    var contextualStrings: [String] = []

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

    private final class GainBox: @unchecked Sendable {
        private let lock = NSLock()
        private var autoGain = AutoGain(sensitivity: .current)
        private var buffersSinceCheck = 0

        func boosted(_ buffer: AVAudioPCMBuffer, rms: Float) -> AVAudioPCMBuffer {
            let gain = lock.withLock { () -> Float in
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

    static func requestPermissions() async -> Bool {
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        return mic && speech
    }

    func start() {
        stop()
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.isAvailable
        else {
            goDeaf(L10n.format("Speech recognition unavailable for %@", localeIdentifier))
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
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

    private func configureAudioSession() throws {
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
        try audio.setActive(true)
    }

    private func startRequest() {
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
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
            if generation != session.generation {
                return
            }
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

    private func swapRequest() {
        let oldRequest = requestBox.request
        startRequest()
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
