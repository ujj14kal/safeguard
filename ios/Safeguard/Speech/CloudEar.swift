import AVFoundation
import Foundation

enum CloudEarState: Equatable {
    case off
    case connecting
    case live
    case failed(String)

    var summary: String {
        switch self {
        case .off: String(localized: "Cloud ear: off")
        case .connecting: String(localized: "Cloud ear: connecting")
        case .live: String(localized: "Cloud ear: live")
        case .failed(let why): L10n.format("Cloud ear: %@", why)
        }
    }
}

/// Streams the microphone to Meta's Muse Voice Transcribe through the
/// backend's `/asr` relay and hands back live text: a growing partial while
/// someone talks, and a finished turn when they pause. It reconnects by
/// itself, and the listener keeps Apple's recogniser running underneath, so a
/// dropped connection never leaves the app deaf.
final class CloudEar: @unchecked Sendable {
    typealias TextHandler = @Sendable (_ text: String, _ isFinal: Bool) -> Void

    private let lock = NSLock()
    private let resampler = PCM16Resampler()
    private var chunker = PCMChunker()
    private var backoff = CloudEarBackoff()
    private var task: URLSessionWebSocketTask?
    private var session: URLSession = .shared
    private var wanted = false
    private var ready = false
    private var inFlight = 0
    private var generation = 0
    private var onText: TextHandler?
    private var onState: (@Sendable (CloudEarState) -> Void)?
    private var state: CloudEarState = .off

    var currentState: CloudEarState { lock.withLock { state } }
    var isLive: Bool { currentState == .live }

    func configure(onText: @escaping TextHandler, onState: @escaping @Sendable (CloudEarState) -> Void) {
        lock.withLock {
            self.onText = onText
            self.onState = onState
        }
    }

    private func set(_ new: CloudEarState) {
        let handler: (@Sendable (CloudEarState) -> Void)? = lock.withLock {
            guard state != new else { return nil }
            state = new
            return onState
        }
        handler?(new)
    }

    func start() {
        let already: Bool = lock.withLock {
            defer { wanted = true }
            return wanted
        }
        guard !already else { return }
        connect()
    }

    func stop() {
        let task: URLSessionWebSocketTask? = lock.withLock {
            wanted = false
            ready = false
            generation += 1
            chunker.reset()
            let current = self.task
            self.task = nil
            return current
        }
        task?.cancel(with: .normalClosure, reason: nil)
        set(.off)
    }

    private func connect() {
        guard let url = CloudEarURL.relay(from: VerifierConfig.default.baseURL) else {
            set(.failed("bad backend address"))
            return
        }
        set(.connecting)
        let (task, gen): (URLSessionWebSocketTask, Int) = lock.withLock {
            generation += 1
            let request = VerifierConfig.default.authorize(URLRequest(url: url))
            let task = session.webSocketTask(with: request)
            self.task = task
            ready = false
            inFlight = 0
            chunker.reset()
            return (task, generation)
        }
        task.resume()
        receive(on: task, generation: gen)
    }

    private func receive(on task: URLSessionWebSocketTask, generation gen: Int) {
        task.receive { [weak self] result in
            guard let self, self.lock.withLock({ self.generation == gen }) else { return }
            switch result {
            case .failure(let error):
                self.lost(error.localizedDescription, generation: gen)
            case .success(let message):
                if case .string(let text) = message { self.handle(text, generation: gen) }
                self.receive(on: task, generation: gen)
            }
        }
    }

    private func handle(_ text: String, generation gen: Int) {
        switch CloudEarEvent.parse(text) {
        case .ready:
            lock.withLock {
                ready = true
                backoff.reset()
            }
            set(.live)
        case .partial(let words):
            lock.withLock { onText }?(words, false)
        case .turnComplete(let words):
            lock.withLock { onText }?(words, true)
        case .error(let message):
            lost(message, generation: gen)
        case .other:
            break
        }
    }

    /// The connection ended or failed: try again after a growing delay while
    /// the ear is still wanted.
    private func lost(_ reason: String, generation gen: Int) {
        let delay: TimeInterval? = lock.withLock {
            guard generation == gen, wanted else { return nil }
            generation += 1
            ready = false
            task?.cancel(with: .goingAway, reason: nil)
            task = nil
            return backoff.nextDelay()
        }
        set(.failed(reason))
        guard let delay else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.lock.withLock({ self.wanted && self.task == nil }) else { return }
            self.connect()
        }
    }

    /// One microphone buffer. Frames are sent only while the relay is ready,
    /// and dropped (never queued up) if the network falls behind: the
    /// service rejects audio that arrives slower than real time.
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard lock.withLock({ wanted && ready }), let samples = resampler.convert(buffer) else { return }
        let (frames, task): ([Data], URLSessionWebSocketTask?) = lock.withLock {
            (chunker.append(samples), self.task)
        }
        guard let task else { return }
        for frame in frames {
            let backlog = lock.withLock { inFlight }
            if backlog > 25 { continue }
            lock.withLock { inFlight += 1 }
            task.send(.data(frame)) { [weak self] _ in
                self?.lock.withLock { self?.inFlight -= 1 }
            }
        }
    }
}
