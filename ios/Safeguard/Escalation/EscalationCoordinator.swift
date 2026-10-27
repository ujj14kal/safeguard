import Foundation

/// The four SOS escalation tracks. They start together and fail
/// independently: one track failing never stops the others.
public enum EscalationTrack: String, Sendable, CaseIterable {
    case route
    case contacts
    case stream
    case cab

    public var title: String {
        switch self {
        case .route: "Route"
        case .contacts: "Contacts"
        case .stream: "Live stream"
        case .cab: "Cab"
        }
    }
}

public enum TrackStatus: Sendable, Equatable {
    case pending
    case running
    case done
    case failed(reason: String)
}

/// Retry waits between attempts (seconds). Transient failures retry with
/// backoff; when the waits run out the track fails terminally.
public struct EscalationRetryPolicy: Sendable {
    public var delays: [TimeInterval]

    public init(delays: [TimeInterval] = [2, 8, 30]) {
        self.delays = delays
    }

    /// Seconds to wait before retry attempt `attempt` (1-based), or nil
    /// when the attempts are used up.
    public func delay(beforeRetry attempt: Int) -> TimeInterval? {
        guard attempt >= 1, attempt <= delays.count else { return nil }
        return delays[attempt - 1]
    }
}

/// Pure escalation state: which tracks run, which finished, which failed,
/// and when each retry is due. Timestamps are explicit (the view model
/// passes system uptime), so tests drive time without waiting.
public struct EscalationCoordinator: Sendable {
    public private(set) var statuses: [EscalationTrack: TrackStatus]
    public private(set) var started = false
    public private(set) var ended = false

    private var attempts: [EscalationTrack: Int] = [:]
    private var retryAt: [EscalationTrack: TimeInterval] = [:]
    private let policy: EscalationRetryPolicy

    public init(policy: EscalationRetryPolicy = EscalationRetryPolicy()) {
        self.policy = policy
        self.statuses = Dictionary(
            uniqueKeysWithValues: EscalationTrack.allCases.map { ($0, .pending) }
        )
    }

    public func status(of track: EscalationTrack) -> TrackStatus {
        statuses[track] ?? .pending
    }

    /// Starts all four tracks together. Later calls are no-ops.
    public mutating func start() {
        guard !started else { return }
        started = true
        for track in EscalationTrack.allCases {
            statuses[track] = .running
            attempts[track] = 1
        }
    }

    /// Marks one track finished. Other tracks are untouched.
    public mutating func complete(_ track: EscalationTrack) {
        guard started, !ended, status(of: track) == .running else { return }
        statuses[track] = .done
        retryAt[track] = nil
    }

    /// Records one failed attempt: schedules a retry with backoff, or fails
    /// the track terminally when the waits run out. Never touches the
    /// other tracks.
    public mutating func fail(_ track: EscalationTrack, reason: String, at time: TimeInterval) {
        guard started, !ended, status(of: track) == .running else { return }
        let attempt = attempts[track] ?? 1
        if let wait = policy.delay(beforeRetry: attempt) {
            attempts[track] = attempt + 1
            retryAt[track] = time + wait
        } else {
            statuses[track] = .failed(reason: reason)
            retryAt[track] = nil
        }
    }

    /// Tracks whose retry wait has passed (each returned once, until its
    /// next `fail` re-arms it). The caller retries the work, then calls
    /// `complete` or `fail` again.
    public mutating func dueRetries(at time: TimeInterval) -> [EscalationTrack] {
        guard started, !ended else { return [] }
        var due: [EscalationTrack] = []
        for track in EscalationTrack.allCases {
            if status(of: track) == .running,
               let at = retryAt[track], time >= at
            {
                retryAt[track] = nil
                due.append(track)
            }
        }
        return due
    }

    /// Ends the SOS: running and pending tracks stop as "SOS ended"
    /// (honest — they did not finish), done/failed stay as they were.
    public mutating func end() {
        guard started, !ended else { return }
        ended = true
        for track in EscalationTrack.allCases {
            switch status(of: track) {
            case .running, .pending:
                statuses[track] = .failed(reason: "SOS ended")
            case .done, .failed:
                break
            }
            retryAt[track] = nil
        }
    }
}
