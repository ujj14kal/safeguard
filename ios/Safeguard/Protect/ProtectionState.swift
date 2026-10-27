import SwiftUI

/// Display states for the shield ring and preview screens. UI-only in Phase 1;
/// the full SafetyStateMachine (prompt, 10 s no-reply, cooldown, code phrases)
/// arrives in Phase 5 and drives these states.
enum ProtectionState: String, CaseIterable {
    case idle, monitoring, suspected, asking, safe, unsafe, countdown

    var title: String {
        switch self {
        case .idle: "Not protecting"
        case .monitoring: "Protecting"
        case .suspected: "Something seems off"
        case .asking: "Are you safe?"
        case .safe: "You're safe"
        case .unsafe: "SOS — help is on the way"
        case .countdown: "Auto-SOS starting"
        }
    }

    var subtitle: String {
        switch self {
        case .idle: "Start protecting to watch for threatening behaviour."
        case .monitoring: "Watching for threatening behaviour nearby."
        case .suspected: "Checking what is happening around you."
        case .asking: "No reply in 10 seconds starts the SOS."
        case .safe: "Incident ended. Stay safe."
        case .unsafe: "Route, contacts, live stream and cab are starting."
        case .countdown: "Say \"open calculator\", tap Cancel, or double tap if you are OK."
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
