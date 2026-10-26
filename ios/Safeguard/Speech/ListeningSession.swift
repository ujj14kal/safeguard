import Foundation

/// Pure lifecycle for one conversation-listening run: gapless recognition
/// restarts, TTS pausing, and honest deaf states. The real
/// ConversationListener drives AVFoundation; this type holds every decision
/// the tests can check.
public struct ListeningSession: Sendable {
    public enum State: Sendable, Equatable {
        case idle
        /// Live. `generation` counts recognition requests: each restart
        /// bumps it, and audio buffers always feed exactly one request.
        case listening(generation: Int, requestStart: TimeInterval)
        /// TTS is speaking: recognition paused, resumes after.
        case paused(generation: Int)
        /// Interrupted or errored. Never looks active: `isLive` is false.
        case deaf(reason: String)
    }

    public private(set) var state: State = .idle
    private let restartInterval: TimeInterval

    public init(config: SpeechConfig = SpeechConfig()) {
        self.restartInterval = config.restartIntervalSeconds
    }

    /// True only while actually transcribing. Paused and deaf are not live.
    public var isLive: Bool {
        if case .listening = state { return true }
        return false
    }

    public mutating func start(at time: TimeInterval) {
        switch state {
        case .idle, .deaf:
            state = .listening(generation: 0, requestStart: time)
        case .listening, .paused:
            break
        }
    }

    public mutating func stop() {
        state = .idle
    }

    /// Starts a fresh recognition request when the system time limit
    /// approaches. Returns true exactly when the caller must restart.
    @discardableResult
    public mutating func restartIfDue(at time: TimeInterval) -> Bool {
        if case let .listening(generation, requestStart) = state,
           time - requestStart >= restartInterval
        {
            state = .listening(generation: generation + 1, requestStart: time)
            return true
        }
        return false
    }

    /// The app started speaking: pause so we never transcribe ourselves.
    public mutating func pauseForSpeech() {
        if case let .listening(generation, _) = state {
            state = .paused(generation: generation)
        }
    }

    /// TTS finished: resume with a fresh request (same transcript stream).
    public mutating func resumeAfterSpeech(at time: TimeInterval) {
        if case let .paused(generation) = state {
            state = .listening(generation: generation + 1, requestStart: time)
        }
    }

    /// Phone call, Siri, or another app took the microphone.
    public mutating func noteInterruption() {
        switch state {
        case .listening, .paused:
            state = .deaf(reason: "Microphone interrupted")
        case .idle, .deaf:
            break
        }
    }

    public mutating func noteError(_ message: String) {
        switch state {
        case .listening, .paused:
            state = .deaf(reason: message)
        case .idle, .deaf:
            break
        }
    }
}
