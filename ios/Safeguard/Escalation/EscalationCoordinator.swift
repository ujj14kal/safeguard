import Foundation

public enum EscalationTrack: String, Sendable, CaseIterable {
    case route
    case contacts
    case stream
    case cab

    public var title: String {
        switch self {
        case .route:
            return String(localized: "Route")
        case .contacts:
            return String(localized: "Contacts")
        case .stream:
            return String(localized: "Live stream")
        case .cab:
            return String(localized: "Cab")
        }
    }
}

public enum TrackStatus: Sendable, Equatable {
    case pending
    case running
    case done
    case failed(reason: String)
}

public struct EscalationRetryPolicy: Sendable {
    public var delays: [TimeInterval]

    public init(delays: [TimeInterval] = [2, 8, 30]) {
        self.delays = delays
    }

    public func delay(beforeRetry attempt: Int) -> TimeInterval? {
        guard attempt >= 1, attempt <= delays.count else { return nil }
        return delays[attempt - 1]
    }
}

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

    public func attempts(of track: EscalationTrack) -> Int {
        if let count = attempts[track] { return count }
        return started ? 1 : 0
    }

    public func reason(of track: EscalationTrack) -> String? {
        if case .failed(let reason) = status(of: track) {
            return reason
        }
        return nil
    }

    public mutating func start() {
        guard !started else { return }
        started = true
        for track in EscalationTrack.allCases {
            statuses[track] = .running
            attempts[track] = 1
        }
    }

    public mutating func complete(_ track: EscalationTrack) {
        guard started, !ended, status(of: track) == .running else { return }
        statuses[track] = .done
        retryAt[track] = nil
    }

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

    public mutating func end() {
        guard started, !ended else { return }
        ended = true
        for track in EscalationTrack.allCases {
            switch status(of: track) {
            case .running, .pending:
                statuses[track] = .failed(reason: String(localized: "SOS ended"))
            case .done, .failed:
                break
            }
            retryAt[track] = nil
        }
    }
}
