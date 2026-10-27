import Foundation

/// First-run setup steps, in order. One idea per screen.
public enum SetupStep: Int, Sendable, CaseIterable {
    case welcome
    case name
    case permissions
    case contacts
    case phrases
    case listening
    case dryRun
    case done
}

/// Warnings the Done screen must show.
public enum SetupWarning: Sendable, Equatable {
    case contactsUnlinked
}

/// Pure setup flow: step navigation plus the gating rules. Views own the
/// widgets (text fields, toggles, contact rows); the machine owns what
/// "may advance" means, so tests pin it without UI.
public struct SetupMachine: Sendable, Equatable {
    public var step: SetupStep

    public init(step: SetupStep = .welcome) {
        self.step = step
    }

    public mutating func next() {
        if let advanced = SetupStep(rawValue: step.rawValue + 1) {
            step = advanced
        }
    }

    public mutating func back() {
        if let previous = SetupStep(rawValue: step.rawValue - 1) {
            step = previous
        }
    }

    public var isFirst: Bool { step == .welcome }
    public var isLast: Bool { step == .done }

    /// 0...1 progress for the indicator.
    public var progress: Double {
        Double(step.rawValue) / Double(SetupStep.allCases.count - 1)
    }

    // MARK: - Gating

    /// Wearer name: required, trimmed, 1-40 characters.
    public static func nameValid(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...40).contains(trimmed.count)
    }

    /// Contacts step: at least 2 contacts whose "this person agreed"
    /// checkbox is ticked.
    public static func contactsSatisfied(agreedCount: Int) -> Bool {
        agreedCount >= 2
    }

    /// Finishing with unlinked contacts is allowed, but warns.
    public static func finishWarnings(unlinkedCount: Int) -> [SetupWarning] {
        unlinkedCount > 0 ? [.contactsUnlinked] : []
    }

    /// Whether Next/Finish may advance from `step` given the flow inputs.
    public static func canAdvance(
        from step: SetupStep, name: String = "", agreedContacts: Int = 0,
        phrasesValid: Bool = false, dryRunSeen: Bool = false
    ) -> Bool {
        switch step {
        case .welcome, .permissions, .listening, .done:
            return true
        case .name:
            return nameValid(name)
        case .contacts:
            return contactsSatisfied(agreedCount: agreedContacts)
        case .phrases:
            return phrasesValid
        case .dryRun:
            return dryRunSeen
        }
    }
}
