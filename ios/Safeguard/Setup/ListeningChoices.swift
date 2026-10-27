import SwiftUI

/// The six listening switches, with the one-sentence plain-language
/// explanation each. One source, used word-for-word by setup and Settings.
enum ListeningChoices {
    struct Choice: Identifiable {
        var id: String { key }
        let key: String
        let title: String
        let explanation: String
        let defaultValue: Bool
    }

    static let all: [Choice] = [
        Choice(
            key: "listenerOptIn",
            title: String(localized: "Listen for threatening speech"),
            explanation: String(localized: "Transcribes speech near you, on this phone only, to notice threatening or harassing talk. Raw audio is never stored or sent; transcripts live only in a short in-memory window."),
            defaultValue: Defaults.current.listenerOptIn
        ),
        Choice(
            key: "cloudEarEnabled",
            title: String(localized: "Cloud ear"),
            explanation: String(localized: "Streams live audio to your Safeguard backend, which relays it to Meta's speech model for accurate Hindi and Hinglish. Off keeps everything on this phone."),
            defaultValue: Defaults.current.cloudEarEnabled
        ),
        Choice(
            key: "aiJudgeEnabled",
            title: String(localized: "AI judge"),
            explanation: String(localized: "Sends the last few seconds of conversation as text — never audio — to an AI model to judge danger."),
            defaultValue: Defaults.current.aiJudgeEnabled
        ),
        Choice(
            key: "distressWordsEnabled",
            title: String(localized: "Distress words"),
            explanation: String(localized: "Words like “help” and “bachao” start a 5-second auto-SOS countdown you can cancel. On-device, always."),
            defaultValue: Defaults.current.distressWordsEnabled
        ),
        Choice(
            key: "shoutingTriggersSOS",
            title: String(localized: "Shouting"),
            explanation: String(localized: "Sudden loud shouting near you starts the same auto-SOS countdown. On-device loudness only; no words leave the phone."),
            defaultValue: Defaults.current.shoutingTriggersSOS
        ),
        Choice(
            key: "recordOnSOS",
            title: String(localized: "SOS recording and upload"),
            explanation: String(localized: "Records video and audio during an SOS and uploads it in parts so your contacts can watch. Nothing records at any other time."),
            defaultValue: Defaults.current.recordOnSOS
        ),
    ]

    /// How many of the six are currently on (Done screen summary).
    static func enabledCount() -> Int {
        all.filter { UserDefaults.standard.bool(forKey: $0.key) }.count
    }
}

/// One listening switch bound straight to its UserDefaults key.
struct ListeningToggle: View {
    let choice: ListeningChoices.Choice
    @AppStorage var enabled: Bool

    init(_ choice: ListeningChoices.Choice) {
        self.choice = choice
        _enabled = AppStorage(wrappedValue: choice.defaultValue, choice.key)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(choice.title, isOn: $enabled)
            Text(choice.explanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
