import Foundation

public struct DataWipeReport: Sendable, Equatable {
    public var removedKeys: [String] = []
    public var removedFiles: [String] = []
    public var backendDeleted: [String] = []
    public var backendFailed: [String] = []
}

public enum DataWipe {
    @discardableResult
    public static func wipeLocal(
        defaults: UserDefaults = .standard, documents: URL? = nil,
        domain: String? = nil, keeping: [String] = []
    ) -> DataWipeReport {
        var report = DataWipeReport()
        let store = defaults
        var present = store.persistentDomain(
            forName: domain ?? Bundle.main.bundleIdentifier ?? ""
        ) ?? [:]
        for key in Defaults.ownedKeys where present[key] != nil && !keeping.contains(key) {
            store.removeObject(forKey: key)
            present.removeValue(forKey: key)
            report.removedKeys.append(key)
        }
        let docs = documents ?? FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        )[0]
        let history = docs.appendingPathComponent(IncidentHistory.filename)
        if FileManager.default.fileExists(atPath: history.path) {
            try? FileManager.default.removeItem(at: history)
            if !FileManager.default.fileExists(atPath: history.path) {
                report.removedFiles.append(IncidentHistory.filename)
            }
        }
        let evidence = docs.appendingPathComponent("Evidence", isDirectory: true)
        if FileManager.default.fileExists(atPath: evidence.path) {
            try? FileManager.default.removeItem(at: evidence)
            if !FileManager.default.fileExists(atPath: evidence.path) {
                report.removedFiles.append("Evidence")
            }
        }
        AppLog.shared.clearQueue()
        return report
    }
}
