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
        /// Interrupted or errored. Never looks active: `isLive` is false.
        case deaf(reason: String)
    }

    // NOTE: there is deliberately no paused-for-TTS state. Pausing would
    // deafen the unsafe code phrase, which must work at ANY time while
    // protecting. The app "ignores itself" instead: our spoken texts match
    // no code phrase and no threat pattern, and voice commands are gated
    // on `speakingNow` in the view model.

    public private(set) var state: State = .idle
    private let restartInterval: TimeInterval

    public init(config: SpeechConfig = SpeechConfig()) {
        self.restartInterval = config.restartIntervalSeconds
    }

    /// True only while actually transcribing. Deaf is not live.
    public var isLive: Bool {
        if case .listening = state { return true }
        return false
    }

    /// Current recognition-request generation (nil unless listening).
    /// The listener tags each task with its generation so a stale task's
    /// error (e.g. from a routine restart cancel) is ignored.
    public var generation: Int? {
        if case let .listening(generation, _) = state { return generation }
        return nil
    }

    public mutating func start(at time: TimeInterval) {
        switch state {
        case .idle, .deaf:
            state = .listening(generation: 0, requestStart: time)
        case .listening:
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

    /// Phone call, Siri, or another app took the microphone.
    public mutating func noteInterruption() {
        switch state {
        case .listening:
            state = .deaf(reason: "Microphone interrupted")
        case .idle, .deaf:
            break
        }
    }

    public mutating func noteError(_ message: String) {
        switch state {
        case .listening:
            state = .deaf(reason: message)
        case .idle, .deaf:
            break
        }
    }
}
