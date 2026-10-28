import Foundation

public enum CloudEarEvent: Equatable, Sendable {
    case ready
    case partial(String)
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

public struct CloudEarBackoff: Sendable {
    public private(set) var attempt = 0
    public init() {}

    public mutating func nextDelay() -> TimeInterval {
        defer { attempt += 1 }
        return min(15, pow(2, Double(attempt)))
    }

    public mutating func reset() { attempt = 0 }
}

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

public struct TranscriptSourcePolicy: Sendable {
    public var cloudFreshSeconds: TimeInterval = 8
    private var lastCloud: TimeInterval = -.infinity

    public init() {}

    public mutating func noteCloud(at time: TimeInterval) { lastCloud = time }

    public func appleMayFeedConversation(at time: TimeInterval) -> Bool {
        time - lastCloud > cloudFreshSeconds
    }
}

public enum TranscriptSource: String, Sendable {
    case apple
    case cloud
}

public enum CloudEarURL {
    public static func relay(from base: URL) -> URL? {
        guard var components = URLComponents(
            url: base.appendingPathComponent("asr"), resolvingAgainstBaseURL: false
        ) else { return nil }
        let secure = components.scheme == "https"
        components.scheme = secure ? "wss" : "ws"
        return components.url
    }
}
