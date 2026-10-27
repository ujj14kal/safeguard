import Foundation

/// Pure event queue behind `AppLog`: capped, oldest dropped first, drained in
/// batches. Kept separate so the policy is testable without a network.
public struct AppLogBuffer: Sendable {
    public private(set) var events: [[String: String]] = []
    private let cap: Int

    public init(cap: Int = 500) {
        self.cap = cap
    }

    public mutating func append(_ event: [String: String]) {
        events.append(event)
        if events.count > cap { events.removeFirst(events.count - cap) }
    }

    public var isEmpty: Bool { events.isEmpty }
    public var count: Int { events.count }

    /// Takes up to `limit` events off the front.
    public mutating func drain(limit: Int = 100) -> [[String: String]] {
        let batch = Array(events.prefix(limit))
        events.removeFirst(batch.count)
        return batch
    }

    /// Puts a failed batch back at the front (still capped).
    public mutating func requeue(_ batch: [[String: String]]) {
        events.insert(contentsOf: batch, at: 0)
        if events.count > cap { events.removeFirst(events.count - cap) }
    }
}

/// Debug event log: what the app hears and what it decides to do, sent in
/// small batches to the backend (`POST /applog`, read back at
/// `backend/logs/app-events.jsonl`). It holds transcripts ON PURPOSE, for
/// testing, so it is a Settings switch ("Debug log") and must be off for
/// real use. Failures are silent: logging must never affect the app.
public final class AppLog: @unchecked Sendable {
    public static let shared = AppLog()
    public static let enabledKey = "debugLogEnabled"

    private let lock = NSLock()
    private var buffer = AppLogBuffer()
    private var flushScheduled = false
    private var sending = false
    private let session: URLSession
    private let config: @Sendable () -> VerifierConfig

    public init(
        session: URLSession = .shared,
        config: @escaping @Sendable () -> VerifierConfig = { VerifierConfig.default }
    ) {
        self.session = session
        self.config = config
        UserDefaults.standard.register(defaults: [Self.enabledKey: Defaults.current.debugLogEnabled])
    }

    public var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    /// Queued (unsent) event count, for tests and the wipe report.
    public var queuedCount: Int { lock.withLock { buffer.count } }

    /// Drops every queued event. "Delete all my data" calls this.
    public func clearQueue() {
        lock.withLock { _ = buffer.drain(limit: Int.max) }
    }

    /// Records one event. `kind` is a short name ("heard", "judge", "state");
    /// fields are plain strings.
    public func event(_ kind: String, _ fields: [String: String] = [:]) {
        guard isEnabled else { return }
        var event = fields
        event["kind"] = kind
        event["t"] = String(format: "%.2f", ProcessInfo.processInfo.systemUptime)
        event["wall"] = ISO8601DateFormatter().string(from: Date())
        lock.withLock {
            buffer.append(event)
            if !flushScheduled {
                flushScheduled = true
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.flush()
                }
            }
        }
    }

    private func flush() {
        let batch: [[String: String]] = lock.withLock {
            flushScheduled = false
            guard !sending, !buffer.isEmpty else { return [] }
            sending = true
            return buffer.drain(limit: 100)
        }
        guard !batch.isEmpty else { return }
        var request = URLRequest(
            url: config().baseURL.appendingPathComponent("applog"), timeoutInterval: 8
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["events": batch])
        request = config().authorize(request)
        session.dataTask(with: request) { [weak self] _, response, error in
            guard let self else { return }
            let ok = error == nil && (response as? HTTPURLResponse)?.statusCode == 200
            self.lock.withLock {
                self.sending = false
                if !ok { self.buffer.requeue(batch) }
                if !self.buffer.isEmpty, !self.flushScheduled {
                    self.flushScheduled = true
                    // Back off a little after a failure.
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + (ok ? 0.5 : 5)) {
                        self.flush()
                    }
                }
            }
        }.resume()
    }
}
