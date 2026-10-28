import Foundation

public enum SetupStep: Int, Sendable, CaseIterable {
    case welcome
    case account
    case name
    case permissions
    case contacts
    case phrases
    case listening
    case dryRun
    case done
}

public enum SetupWarning: Sendable, Equatable {
    case contactsUnlinked
}

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

    public var progress: Double {
        Double(step.rawValue) / Double(SetupStep.allCases.count - 1)
    }

    public static func nameValid(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...40).contains(trimmed.count)
    }

    public static func contactsSatisfied(agreedCount: Int) -> Bool {
        agreedCount >= 2
    }

    public static func finishWarnings(unlinkedCount: Int) -> [SetupWarning] {
        unlinkedCount > 0 ? [.contactsUnlinked] : []
    }

    public static func canAdvance(
        from step: SetupStep, name: String = "", agreedContacts: Int = 0,
        phrasesValid: Bool = false, dryRunSeen: Bool = false
    ) -> Bool {
        switch step {
        case .welcome, .account, .permissions, .listening, .done:
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
