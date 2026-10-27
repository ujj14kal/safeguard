import SwiftUI

/// Step 5: code phrases. Shows the defaults, allows editing with
/// validation, and practices by listening. Saves live while valid.
struct SetupPhrasesStep: View {
    @StateObject private var model = ProtectViewModel.shared
    @State private var safe = ""
    @State private var unsafe = ""
    @Binding var valid: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.medium) {
            Text("Code phrases")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
            Text("A safe phrase answers “I'm OK”. An unsafe phrase starts an SOS at once — even mid-sentence, even with everything off.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: DS.Spacing.small) {
                Text("Safe phrase")
                    .font(.headline)
                TextField("Safe phrase", text: $safe)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .textInputAutocapitalization(.never)
                Text("Unsafe phrase")
                    .font(.headline)
                TextField("Unsafe phrase", text: $unsafe)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .textInputAutocapitalization(.never)
                ForEach(validationMessages(), id: \.self) { message in
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(DS.Colors.danger)
                }
            }
            Text("Each phrase needs at least 2 words. They must differ, neither may contain the other, and neither may be a distress word.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("A distress word starts a 5-second countdown you can cancel. No reply to the spoken check-in within 10 seconds starts an SOS.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            PhrasePracticeView()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            let config = SafetyConfig()
            if safe.isEmpty {
                safe = CodePhraseStore.customSafe.isEmpty
                    ? config.safePhrases[0] : CodePhraseStore.customSafe
            }
            if unsafe.isEmpty {
                unsafe = CodePhraseStore.customUnsafe.isEmpty
                    ? config.unsafePhrases[0] : CodePhraseStore.customUnsafe
            }
            revalidate()
        }
        .onChange(of: safe) { _, _ in revalidate() }
        .onChange(of: unsafe) { _, _ in revalidate() }
    }

    private func failures() -> [CodePhraseValidation.Failure] {
        CodePhraseValidation.validate(safe: safe, unsafe: unsafe)
    }

    private func validationMessages() -> [String] {
        failures().map { failure in
            switch failure {
            case .tooShort:
                String(localized: "Each phrase needs at least 2 words.")
            case .same:
                String(localized: "The two phrases must differ.")
            case .containsOther:
                String(localized: "Neither phrase may contain the other.")
            case .isDistressWord:
                String(localized: "A code phrase cannot be a distress word.")
            case .collidesWithDefault:
                String(localized: "The safe phrase would always trigger Unsafe instead.")
            }
        }
    }

    /// Valid edits save immediately (matching a built-in variant keeps all
    /// variants by storing nothing); invalid edits never save.
    private func revalidate() {
        let failures = failures()
        valid = failures.isEmpty
        guard failures.isEmpty else { return }
        let config = SafetyConfig()
        let cleanSafe = safe.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanUnsafe = unsafe.trimmingCharacters(in: .whitespacesAndNewlines)
        CodePhraseStore.customSafe = config.safePhrases.contains(cleanSafe) ? "" : cleanSafe
        CodePhraseStore.customUnsafe = config.unsafePhrases.contains(cleanUnsafe) ? "" : cleanUnsafe
        model.refreshPhrases()
    }
}

/// Practice step, shared by setup and Settings: listens and reports what
/// it heard. Never acts — the view model short-circuits while practicing.
struct PhrasePracticeView: View {
    @StateObject private var model = ProtectViewModel.shared
    @State private var practicing = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            Text("Practice")
                .font(.headline)
            Text("Say a code phrase and check Safeguard hears it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if canListen {
                HStack {
                    Button(practicing ? String(localized: "Stop") : String(localized: "Start listening")) {
                        practicing ? stop() : start()
                    }
                    .buttonStyle(.borderedProminent)
                    .minTouchTarget()
                    Spacer()
                    Text(heardText)
                        .font(.headline)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(format: "Practice result: %@", heardText))
            } else {
                Text("Microphone or speech recognition is off, so practice can't hear you. Turn them on in Settings to practice.")
                    .font(.footnote)
                    .foregroundStyle(DS.Colors.warning)
            }
        }
        .onDisappear(perform: stop)
    }

    private var canListen: Bool {
        SetupPermissions.status(of: .microphone) == .granted
            && SetupPermissions.status(of: .speech) == .granted
    }

    /// Pre-localised: shown as a label and read inside an announcement.
    private var heardText: String {
        switch model.practiceHeard {
        case .none:
            String(localized: "Say a code phrase…")
        case .noMatch:
            String(localized: "Heard: nothing")
        case .safe:
            String(localized: "Heard: safe phrase")
        case .unsafe:
            String(localized: "Heard: unsafe phrase")
        }
    }

    private func start() {
        practicing = true
        model.startPhrasePractice()
    }

    private func stop() {
        practicing = false
        model.stopPhrasePractice()
    }
}
