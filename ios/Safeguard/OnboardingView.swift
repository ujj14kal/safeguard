import SwiftUI

/// First-run sheet: what Safeguard does, the conversation-listener opt-in
/// (default OFF) with its plain-language disclosure, and the stay-quiet tip.
/// Shown once; the toggle also lives in Settings.
struct OnboardingView: View {
    static let listenerDisclosure =
        "When on, Safeguard transcribes speech near you, on this phone only, " +
        "to notice threatening or harassing talk. Raw audio is never stored " +
        "and never sent anywhere; transcripts live only in a short in-memory " +
        "window and are discarded when you stop. With \"AI judges the " +
        "conversation\" on, the last few seconds of the transcript, as text " +
        "only, are sent to your Safeguard backend so an AI model can tell " +
        "whether the talk is safe; switch it off to keep everything on this " +
        "phone."

    static let stayQuietTip =
        "If you feel uneasy, try to stay quiet for a few seconds. Safeguard " +
        "listens to your surroundings, on this phone only, and nothing is " +
        "recorded. If you need help right away, say your unsafe phrase at " +
        "any time."

    @AppStorage("listenerOptIn") private var listenerOptIn = false
    var onDone: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.large) {
                    VStack(alignment: .leading, spacing: DS.Spacing.small) {
                        Image(systemName: "shield.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.teal)
                            .accessibilityHidden(true)
                        Text("Welcome to Safeguard")
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        Text(
                            "Safeguard watches for threatening behaviour by people " +
                                "nearby — never appearance or identity — and checks " +
                                "in with you by voice when something seems off."
                        )
                        .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: DS.Spacing.small) {
                        Text("Listen for threatening speech")
                            .font(.headline)
                        Text(Self.listenerDisclosure)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Toggle("Listen for threatening speech", isOn: $listenerOptIn)
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("You can change this anytime in Settings.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: DS.Spacing.small) {
                        Text("Tip: stay quiet for a moment")
                            .font(.headline)
                        Text(Self.stayQuietTip)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button("Continue") { onDone() }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                }
                .padding()
            }
            .navigationTitle("Safeguard")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview {
    OnboardingView(onDone: {})
}
