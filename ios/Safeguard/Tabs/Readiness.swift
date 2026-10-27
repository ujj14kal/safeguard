import Foundation

// MARK: - Readiness (pure checks, shared with the Protect page)

enum ReadinessLevel: Equatable {
    case ok, warning, problem
}

enum ReadinessFix: Equatable {
    case systemSettings
    case contacts
    case settingsTab
    case none
}

struct ReadinessItem: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let level: ReadinessLevel
    let fix: ReadinessFix
}

/// What the Dashboard reports: is this phone actually ready to protect?
/// Inputs are plain values so tests can pin every rule.
struct ReadinessInput: Equatable {
    var camera: PermissionStatus
    var microphone: PermissionStatus
    var speech: PermissionStatus
    var location: PermissionStatus
    /// nil = still checking.
    var backendReachable: Bool?
    var contactCount: Int
    var linkedCount: Int
    var sendsRealAlerts: Bool
}

enum Readiness {
    static let minimumContacts = 2

    static func items(_ input: ReadinessInput) -> [ReadinessItem] {
        var out: [ReadinessItem] = []
        for (permission, status) in [
            (SetupPermission.camera, input.camera),
            (.microphone, input.microphone),
            (.speech, input.speech),
            (.location, input.location),
        ] {
            out.append(permissionItem(permission, status))
        }
        out.append(backendItem(input.backendReachable))
        out.append(contactsItem(count: input.contactCount, linked: input.linkedCount))
        out.append(alertsItem(real: input.sendsRealAlerts))
        return out
    }

    private static func permissionItem(_ permission: SetupPermission, _ status: PermissionStatus) -> ReadinessItem {
        let symbol: String
        switch permission {
        case .camera: symbol = "camera.fill"
        case .microphone: symbol = "mic.fill"
        case .speech: symbol = "waveform"
        case .location: symbol = "location.fill"
        }
        switch status {
        case .granted:
            return ReadinessItem(
                id: permission.rawValue, title: permission.title,
                detail: String(localized: "Allowed"), symbol: symbol, level: .ok, fix: .none
            )
        case .notAsked:
            return ReadinessItem(
                id: permission.rawValue, title: permission.title,
                detail: String(localized: "Not asked yet"), symbol: symbol, level: .warning,
                fix: .systemSettings
            )
        case .denied:
            return ReadinessItem(
                id: permission.rawValue, title: permission.title,
                detail: permission.missingImpact, symbol: symbol, level: .problem,
                fix: .systemSettings
            )
        }
    }

    private static func backendItem(_ reachable: Bool?) -> ReadinessItem {
        switch reachable {
        case .some(true):
            return ReadinessItem(
                id: "backend", title: String(localized: "Safeguard server"),
                detail: String(localized: "Reachable"), symbol: "server.rack", level: .ok, fix: .none
            )
        case .some(false):
            return ReadinessItem(
                id: "backend", title: String(localized: "Safeguard server"),
                detail: String(localized: "Offline: only on-device protection works"),
                symbol: "server.rack", level: .problem, fix: .settingsTab
            )
        case .none:
            return ReadinessItem(
                id: "backend", title: String(localized: "Safeguard server"),
                detail: String(localized: "Checking…"), symbol: "server.rack", level: .warning, fix: .none
            )
        }
    }

    private static func contactsItem(count: Int, linked: Int) -> ReadinessItem {
        if linked >= minimumContacts {
            return ReadinessItem(
                id: "contacts", title: String(localized: "Trusted contacts"),
                detail: L10n.format("%d of %d will get alerts", linked, count),
                symbol: "person.2.fill", level: .ok, fix: .none
            )
        }
        if count == 0 {
            return ReadinessItem(
                id: "contacts", title: String(localized: "Trusted contacts"),
                detail: String(localized: "Nobody will be alerted. Add at least 2."),
                symbol: "person.2.fill", level: .problem, fix: .contacts
            )
        }
        return ReadinessItem(
            id: "contacts", title: String(localized: "Trusted contacts"),
            detail: L10n.format("%d of %d pressed Start. Ask the others to.", linked, count),
            symbol: "person.2.fill", level: .warning, fix: .contacts
        )
    }

    private static func alertsItem(real: Bool) -> ReadinessItem {
        real
            ? ReadinessItem(
                id: "alerts", title: String(localized: "Alert mode"),
                detail: String(localized: "Real alerts are on"), symbol: "bell.badge.fill",
                level: .ok, fix: .none
            )
            : ReadinessItem(
                id: "alerts", title: String(localized: "Alert mode"),
                detail: String(localized: "Test mode: contacts get no messages"),
                symbol: "bell.slash.fill", level: .warning, fix: .settingsTab
            )
    }

    /// "5 of 7 ready" progress.
    static func readyCount(_ items: [ReadinessItem]) -> Int {
        items.filter { $0.level == .ok }.count
    }
}

// MARK: - Stats (pure)

struct DashboardStats: Equatable {
    var eventsLast30Days: Int
    var lastEventDate: Date?
    var evidenceSaved: Int
    var contactsAlerted: Int
    var averageDurationSeconds: Int

    static func from(_ entries: [IncidentHistoryEntry], now: Date = Date()) -> DashboardStats {
        let cutoff = now.addingTimeInterval(-30 * 86400)
        let recent = entries.filter { $0.startedAt >= cutoff }
        let total = recent.reduce(0) { $0 + $1.durationSeconds }
        return DashboardStats(
            eventsLast30Days: recent.count,
            lastEventDate: entries.map(\.startedAt).max(),
            evidenceSaved: recent.reduce(0) { $0 + $1.evidenceSaved },
            contactsAlerted: recent.reduce(0) { $0 + $1.contactsAlerted },
            averageDurationSeconds: recent.isEmpty ? 0 : total / recent.count
        )
    }
}
