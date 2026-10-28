import Foundation

public struct IncidentHistoryEntry: Sendable, Equatable, Codable {
    public var id: UUID
    public var startedAt: Date
    public var endedAt: Date
    public var cause: String
    public var trackOutcomes: [String: String]
    public var contactsAlerted: Int
    public var contactNames: [String]
    public var evidenceSaved: Int
    public var evidenceWaiting: Int
    public var liveURL: String?
    public var evidenceSessionID: String?

    public init(
        id: UUID = UUID(), startedAt: Date, endedAt: Date, cause: String,
        trackOutcomes: [String: String] = [:], contactsAlerted: Int = 0,
        contactNames: [String] = [], evidenceSaved: Int = 0,
        evidenceWaiting: Int = 0, liveURL: String? = nil,
        evidenceSessionID: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.cause = cause
        self.trackOutcomes = trackOutcomes
        self.contactsAlerted = contactsAlerted
        self.contactNames = contactNames
        self.evidenceSaved = evidenceSaved
        self.evidenceWaiting = evidenceWaiting
        self.liveURL = liveURL
        self.evidenceSessionID = evidenceSessionID
    }

    public var durationSeconds: Int {
        max(0, Int(endedAt.timeIntervalSince(startedAt)))
    }
}

public struct IncidentHistory: Sendable, Equatable {
    public static let retentionDays = 30
    public static let filename = "IncidentHistory.json"

    public private(set) var entries: [IncidentHistoryEntry]

    public init(entries: [IncidentHistoryEntry] = []) {
        self.entries = entries.sorted { $0.startedAt > $1.startedAt }
    }

    public mutating func append(_ entry: IncidentHistoryEntry) {
        entries.append(entry)
        entries.sort { $0.startedAt > $1.startedAt }
    }

    public mutating func remove(id: UUID) {
        entries.removeAll { $0.id == id }
    }

    public mutating func removeAll() {
        entries = []
    }

    public mutating func purge(olderThan now: Date = Date()) {
        let cutoff = now.addingTimeInterval(TimeInterval(-Self.retentionDays * 86400))
        entries.removeAll { $0.endedAt < cutoff }
    }

    public static func fileURL(
        documents: URL = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        )[0]
    ) -> URL {
        documents.appendingPathComponent(filename)
    }

    public static func load(from url: URL? = nil) -> IncidentHistory {
        let file = url ?? fileURL()
        guard let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode([IncidentHistoryEntry].self, from: data)
        else {
            return IncidentHistory()
        }
        var history = IncidentHistory(entries: decoded)
        history.purge()
        return history
    }

    public func save(to url: URL? = nil) {
        let file = url ?? Self.fileURL()
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: file, options: .atomic)
        }
    }
}
