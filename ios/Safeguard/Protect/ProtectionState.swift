import SwiftUI

/// Display states for the shield ring and preview screens. UI-only in Phase 1;
/// the full SafetyStateMachine (prompt, 10 s no-reply, cooldown, code phrases)
/// arrives in Phase 5 and drives these states.
enum ProtectionState: String, CaseIterable {
    case idle, monitoring, suspected, asking, safe, unsafe, countdown

    var title: String {
        switch self {
        case .idle: String(localized: "Not protecting")
        case .monitoring: String(localized: "Protecting")
        case .suspected: String(localized: "Something seems off")
        case .asking: String(localized: "Are you safe?")
        case .safe: String(localized: "You're safe")
        case .unsafe: String(localized: "SOS — help is on the way")
        case .countdown: String(localized: "Auto-SOS starting")
        }
    }

    var subtitle: String {
        switch self {
        case .idle: String(localized: "Start protecting to watch for threatening behaviour.")
        case .monitoring: String(localized: "Watching for threatening behaviour nearby.")
        case .suspected: String(localized: "Checking what is happening around you.")
        case .asking: String(localized: "No reply in 10 seconds starts the SOS.")
        case .safe: String(localized: "Incident ended. Stay safe.")
        case .unsafe: String(localized: "Route, contacts, live stream and cab are starting.")
        case .countdown: String(localized: "Say \"open calculator\", tap Cancel, or double tap if you are OK.")
        }
    }

    var symbolName: String {
        switch self {
        case .idle: "shield"
        case .monitoring: "shield.fill"
        case .suspected: "exclamationmark.shield.fill"
        case .asking: "mic.fill"
        case .safe: "checkmark.shield.fill"
        case .unsafe: "sos.circle.fill"
        case .countdown: "timer"
        }
    }

    var color: Color {
        switch self {
        case .idle: .secondary
        case .monitoring: .teal
        case .suspected: .orange
        case .asking: .orange
        case .safe: .green
        case .unsafe: .red
        case .countdown: .red
        }
    }

    /// States in which the ring breathes (actively watching).
    var isProtecting: Bool { self == .monitoring }
}
