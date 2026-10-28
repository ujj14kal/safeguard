import Foundation

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

    public static let release = DefaultSet(
        listenerOptIn: false, aiJudgeEnabled: false, cloudEarEnabled: false,
        cloudEarAlwaysOn: false, distressWordsEnabled: true,
        shoutingTriggersSOS: false, recordOnSOS: false, debugLogEnabled: false
    )

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

    public static var debugOverlayDefault: Bool {
        #if DEBUG
            true
        #else
            false
        #endif
    }

    public static var autoStartProtectingDefault: Bool {
        #if DEBUG
            true
        #else
            false
        #endif
    }

    public static let ownedKeys = [
        "onboardingSeen",
        "setupComplete",
        "setupStep",
        "wearerName",
        "accountProfileJSON",
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
        "autoStartProtecting",
        "listenSensitivity",
        "gesturesTriggerSOS",
        "guardianCode",
        "liveChannelURL",
        "liveChannelToken",
        "deviceID",
        "customSafePhrase",
        "customUnsafePhrase",
        "backendBaseURL",
        "lastBuildBackendURL",
        "debugOverlayEnabled",
        "debugInitialTab",
        "debugInitialRoute",
        "skipSplash",
    ]
}
