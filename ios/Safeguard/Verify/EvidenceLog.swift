import Foundation

public struct LogItem: Sendable, Equatable {
    public var type: String
    public var text: String
    public var rating: String
    public var time: Date
    public var source: String?
    public var shot: Data?
    public var count: Int

    public init(
        type: String, text: String, rating: String, time: Date = Date(),
        source: String? = nil, shot: Data? = nil, count: Int = 1
    ) {
        self.type = type
        self.text = text
        self.rating = rating
        self.time = time
        self.source = source
        self.shot = shot
        self.count = count
    }

    public func json(shotName: String?) -> [String: Any] {
        var body: [String: Any] = [
            "type": type, "text": text, "rating": rating,
            "t": time.timeIntervalSince1970, "count": count,
        ]
        if let source { body["source"] = String(source.prefix(160)) }
        if let shotName { body["shot"] = shotName }
        return body
    }
}

public final class EvidenceLog: @unchecked Sendable {
    public static let maxAge: TimeInterval = 600
    public static let capacity = 60

    private let lock = NSLock()
    private var items: [LogItem] = []

    public init() {}

    public var count: Int { lock.withLock { items.count } }

    public func add(_ item: LogItem, now: Date = Date()) {
        lock.withLock {
            if item.type != "gesture",
               let index = items.firstIndex(where: {
                   $0.type == item.type && $0.text.lowercased() == item.text.lowercased()
               })
            {
                items[index].count += item.count
                if item.rating == "strongly possible" { items[index].rating = item.rating }
                if items[index].source == nil { items[index].source = item.source }
            } else {
                items.append(item)
            }
            trim(now: now)
        }
    }

    public func drain(now: Date = Date()) -> [LogItem] {
        lock.withLock {
            trim(now: now)
            defer { items.removeAll() }
            return items
        }
    }

    public func requeue(_ batch: [LogItem], now: Date = Date()) {
        lock.withLock {
            items.insert(contentsOf: batch, at: 0)
            trim(now: now)
        }
    }

    public func clear() {
        lock.withLock { items.removeAll() }
    }

    private func trim(now: Date) {
        items.removeAll { now.timeIntervalSince($0.time) > Self.maxAge }
        if items.count > Self.capacity { items.removeFirst(items.count - Self.capacity) }
    }
}
