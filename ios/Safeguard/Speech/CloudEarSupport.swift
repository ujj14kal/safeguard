import Foundation

/// What the cloud speech service (Muse Voice Transcribe, relayed by the
/// backend's /asr) sends back.
public enum CloudEarEvent: Equatable, Sendable {
    /// The relay connected upstream; audio may flow.
    case ready
    /// The words so far in the current turn. Each partial REPLACES the last
    /// (the service runs in CUMULATIVE mode).
    case partial(String)
    /// A finished turn: the speaker paused.
    case turnComplete(String)
    case error(String)
    case other

    public static func parse(_ text: String) -> CloudEarEvent {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return .other }
        switch type {
        case "ready":
            return .ready
        case "transcript":
            let words = (object["transcript"] as? String) ?? ""
            return words.isEmpty ? .other : .partial(words)
        case "speechComplete":
            let words = (object["transcript"] as? String) ?? ""
            return words.isEmpty ? .other : .turnComplete(words)
        case "error":
            return .error((object["message"] as? String) ?? "cloud ear error")
        default:
            return .other
        }
    }
}

/// Packs 16 kHz mono samples into 80 ms binary frames (1,280 samples,
/// 2,560 bytes, little-endian), the frame size the service expects.
public struct PCMChunker: Sendable {
    public static let samplesPerChunk = 1_280
    private var pending: [Int16] = []

    public init() {}

    public mutating func append(_ samples: [Int16]) -> [Data] {
        pending.append(contentsOf: samples)
        var chunks: [Data] = []
        while pending.count >= Self.samplesPerChunk {
            let slice = pending.prefix(Self.samplesPerChunk)
            pending.removeFirst(Self.samplesPerChunk)
            chunks.append(slice.withUnsafeBufferPointer { buffer in
                Data(buffer: UnsafeBufferPointer(start: buffer.baseAddress, count: buffer.count))
            })
        }
        return chunks
    }

    public mutating func reset() { pending.removeAll() }
}

/// Reconnect delays for the cloud connection: quick at first, then settling.
public struct CloudEarBackoff: Sendable {
    public private(set) var attempt = 0
    public init() {}

    public mutating func nextDelay() -> TimeInterval {
        defer { attempt += 1 }
        return min(15, pow(2, Double(attempt)))
    }

    public mutating func reset() { attempt = 0 }
}

/// When the cloud ear should be listening. Privacy first: by default the
/// phone listens locally, and the cloud ear switches on only when something
/// calls for accurate hearing (a person near, an alert, a flagged word, an
/// SOS) and stays on for `holdSeconds` after the last reason. "Demo mode"
/// keeps it on all the time so the full pipeline can be shown.
public struct CloudEarGate: Sendable {
    public var holdSeconds: TimeInterval
    private var lastReason: TimeInterval = -.infinity

    public init(holdSeconds: TimeInterval = 45) {
        self.holdSeconds = holdSeconds
    }

    public mutating func shouldListen(
        enabled: Bool, alwaysOn: Bool, personNear: Bool, flagged: Bool, escalated: Bool,
        at time: TimeInterval
    ) -> Bool {
        guard enabled else { return false }
        if alwaysOn { return true }
        if personNear || flagged || escalated { lastReason = time }
        return time - lastReason < holdSeconds
    }

    public mutating func reset() { lastReason = -.infinity }
}

/// Which recogniser's text may feed the conversation window and the AI
/// judge. While the cloud ear is delivering, Apple's rougher text of the same
/// sentence is skipped there (it still feeds code phrases, commands and
/// distress words), so one sentence is never judged or counted twice.
public struct TranscriptSourcePolicy: Sendable {
    public var cloudFreshSeconds: TimeInterval = 8
    private var lastCloud: TimeInterval = -.infinity

    public init() {}

    public mutating func noteCloud(at time: TimeInterval) { lastCloud = time }

    public func appleMayFeedConversation(at time: TimeInterval) -> Bool {
        time - lastCloud > cloudFreshSeconds
    }
}

/// Which recogniser produced a piece of text.
public enum TranscriptSource: String, Sendable {
    case apple
    case cloud
}

public enum CloudEarURL {
    /// The relay URL: the backend's address with the websocket scheme.
    public static func relay(from base: URL) -> URL? {
        guard var components = URLComponents(
            url: base.appendingPathComponent("asr"), resolvingAgainstBaseURL: false
        ) else { return nil }
        let secure = components.scheme == "https"
        components.scheme = secure ? "wss" : "ws"
        return components.url
    }
}
