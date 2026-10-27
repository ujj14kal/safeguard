import SwiftUI

/// First-run setup: full-screen, blocking, resumable. The machine owns the
/// step order and gating; this view owns the widgets. Closing mid-flow
/// resumes at the same step; Settings can re-open it without deleting data.
struct SetupFlowView: View {
    @AppStorage("setupStep") private var savedStep = SetupStep.welcome.rawValue
    @AppStorage("setupComplete") private var setupComplete = false
    @StateObject private var model = ProtectViewModel.shared
    @State private var machine = SetupMachine()
    @State private var name = ""
    @State private var phrasesValid = true
    @State private var dryRunSeen = false
    @Binding var rerun: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                setupProgress
                ScrollView {
                    stepContent
                        .padding()
                }
                navBar
            }
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                machine.step = SetupStep(rawValue: savedStep) ?? .welcome
                name = model.wearerName
            }
            .onChange(of: machine.step) { _, step in
                savedStep = step.rawValue
            }
        }
    }

    private var setupProgress: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Step \(machine.step.rawValue + 1) of \(SetupStep.allCases.count)")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ProgressView(value: machine.progress)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Setup step \(machine.step.rawValue + 1) of \(SetupStep.allCases.count)"
        )
    }

    @ViewBuilder
    private var stepContent: some View {
        switch machine.step {
        case .welcome:
            SetupWelcomeStep()
        case .name:
            SetupNameStep(name: $name)
        case .permissions:
            SetupPermissionsStep()
        case .contacts:
            SetupContactsStep()
        case .phrases:
            SetupPhrasesStep(valid: $phrasesValid)
        case .listening:
            SetupListeningStep()
        case .dryRun:
            SetupDryRunStep(seen: $dryRunSeen)
        case .done:
            SetupDoneStep()
        }
    }

    private var canAdvance: Bool {
        SetupMachine.canAdvance(
            from: machine.step, name: name,
            agreedContacts: model.sosContacts.agreedCount,
            phrasesValid: phrasesValid, dryRunSeen: dryRunSeen
        )
    }

    private var navBar: some View {
        HStack {
            if !machine.isFirst {
                Button("Back") { machine.back() }
                    .buttonStyle(.bordered)
            }
            Spacer()
            if machine.isLast {
                Button("Finish") { finish() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Next") { advance() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAdvance)
            }
        }
        .padding()
    }

    private func advance() {
        if machine.step == .name {
            model.wearerName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        machine.next()
    }

    private func finish() {
        savedStep = SetupStep.welcome.rawValue
        setupComplete = true
        rerun = false
    }
}

/// Step 1: what Safeguard does — and does NOT do.
struct SetupWelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.medium) {
            Image(systemName: "shield.fill")
                .font(.system(size: 56))
                .foregroundStyle(DS.Colors.accent)
                .accessibilityHidden(true)
            Text("Welcome to Safeguard")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
            VStack(alignment: .leading, spacing: DS.Spacing.small) {
                Text("Safeguard watches for threatening behaviour by people nearby.")
                Text("It checks in with you by voice when something seems off.")
                Text("If you don't answer, it alerts your trusted contacts with your live location.")
            }
            .font(.title3)
            VStack(alignment: .leading, spacing: DS.Spacing.small) {
                Text("Safeguard cannot call the police for you.")
                Text("It is not a guarantee of safety.")
            }
            .font(.headline)
            .foregroundStyle(DS.Colors.warning)
            .accessibilityElement(children: .combine)
            Text("This setup takes about 3 minutes.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Step 2: the wearer's name for contact alerts.
struct SetupNameStep: View {
    @Binding var name: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.medium) {
            Text("What should we call you?")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
            Text("Used in alerts to your contacts.")
                .foregroundStyle(.secondary)
            TextField("Your name", text: $name)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.words)
                .disableAutocorrection(true)
                .font(.title2)
            if !name.isEmpty, !SetupMachine.nameValid(name) {
                Text("Use 1 to 40 characters.")
                    .font(.footnote)
                    .foregroundStyle(DS.Colors.danger)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Step 8: summary of what is on, off, and warned about.
struct SetupDoneStep: View {
    @StateObject private var model = ProtectViewModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.medium) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text("You're set up")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
            VStack(alignment: .leading, spacing: DS.Spacing.small) {
                summaryRow(
                    "Name", model.wearerName.isEmpty ? "Not set" : model.wearerName
                )
                summaryRow(
                    "Contacts",
                    "\(model.sosContacts.agreedCount) agreed, " +
                        "\(model.sosContacts.contacts.filter(\.linked).count) linked"
                )
                summaryRow(
                    "Code phrases",
                    CodePhraseStore.customSafe.isEmpty ? "Defaults" : "Yours"
                )
                summaryRow(
                    "Listening", "\(ListeningChoices.enabledCount()) of 6 on"
                )
            }
            let unlinked = model.sosContacts.contacts.filter { !$0.linked }.count
            if !SetupMachine.finishWarnings(unlinkedCount: unlinked).isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Label(
                        "Contacts still waiting: \(unlinked)",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    Text("They get no alerts until they press Start.")
                        .font(.footnote)
                }
                .foregroundStyle(DS.Colors.warning)
            }
            Text("You can change anything later in Settings.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summaryRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
        }
        .accessibilityElement(children: .combine)
    }
}
