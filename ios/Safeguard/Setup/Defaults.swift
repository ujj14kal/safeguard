import Foundation

/// One home for every Settings default. Release builds are safe by
/// default: every listening switch OFF except distress words (the on-device
/// code phrases need no switch at all — they work with everything off).
/// DEBUG keeps today's developer defaults so demos keep working.
/// `values(debug:)` is the pure seam the tests pin; `current` picks by
/// build configuration.
public struct DefaultSet: Sendable, Equatable {
    public var listenerOptIn: Bool
    public var aiJudgeEnabled: Bool
    public var cloudEarEnabled: Bool
    public var cloudEarAlwaysOn: Bool
    public var distressWordsEnabled: Bool
    public var shoutingTriggersSOS: Bool
    public var recordOnSOS: Bool
    public var debugLogEnabled: Bool

    public init(
        listenerOptIn: Bool, aiJudgeEnabled: Bool, cloudEarEnabled: Bool,
        cloudEarAlwaysOn: Bool, distressWordsEnabled: Bool,
        shoutingTriggersSOS: Bool, recordOnSOS: Bool, debugLogEnabled: Bool
    ) {
        self.listenerOptIn = listenerOptIn
        self.aiJudgeEnabled = aiJudgeEnabled
        self.cloudEarEnabled = cloudEarEnabled
        self.cloudEarAlwaysOn = cloudEarAlwaysOn
        self.distressWordsEnabled = distressWordsEnabled
        self.shoutingTriggersSOS = shoutingTriggersSOS
        self.recordOnSOS = recordOnSOS
        self.debugLogEnabled = debugLogEnabled
    }

    /// The release set, pinned by tests: only distress words on.
    public static let release = DefaultSet(
        listenerOptIn: false, aiJudgeEnabled: false, cloudEarEnabled: false,
        cloudEarAlwaysOn: false, distressWordsEnabled: true,
        shoutingTriggersSOS: false, recordOnSOS: false, debugLogEnabled: false
    )

    /// Today's developer set (listener still opt-in, everything else on).
    public static let debug = DefaultSet(
        listenerOptIn: false, aiJudgeEnabled: true, cloudEarEnabled: true,
        cloudEarAlwaysOn: true, distressWordsEnabled: true,
        shoutingTriggersSOS: true, recordOnSOS: true, debugLogEnabled: true
    )
}

public enum Defaults {
    public static func values(debug: Bool) -> DefaultSet {
        debug ? .debug : .release
    }

    public static var current: DefaultSet {
        #if DEBUG
            values(debug: true)
        #else
            values(debug: false)
        #endif
    }

    // MARK: - Owned UserDefaults keys

    /// Every UserDefaults key the app writes. "Delete all my data" removes
    /// exactly these; the test pins the list so new keys cannot be missed.
    public static let ownedKeys = [
        "onboardingSeen",
        "setupComplete",
        "setupStep",
        "setupContactDrafts",
        "wearerName",
        "sendRealAlerts",
        "sosContactsJSON",
        "listenerOptIn",
        "speechLanguage",
        "aiJudgeEnabled",
        "cloudEarEnabled",
        "cloudEarAlwaysOn",
        "distressWordsEnabled",
        "shoutingTriggersSOS",
        "recordOnSOS",
        "debugLogEnabled",
        "customSafePhrase",
        "customUnsafePhrase",
        "backendBaseURL",
        "debugOverlayEnabled",
        "debugInitialTab",
        "debugInitialRoute",
        "skipSplash",
    ]
}
