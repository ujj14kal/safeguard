import SwiftUI
import UIKit

/// Finished Settings: profile, people, phrases, listening, alerts,
/// permissions, data, about, and the DEBUG-only developer section.
struct SettingsView: View {
    @ObservedObject private var model = ProtectViewModel.shared
    @AppStorage("debugOverlayEnabled") private var debugOverlayEnabled = Defaults.debugOverlayDefault
    @StateObject private var account = AccountStore.shared
    @AppStorage("gesturesTriggerSOS") private var gesturesTriggerSOS = true
    @AppStorage(ListenSensitivity.key) private var listenSensitivity = ListenSensitivity.defaultLevel.rawValue
    @State private var showingAccount = false
    @State private var confirmDeleteAccount = false
    @AppStorage("autoStartProtecting") private var autoStartProtecting = Defaults.autoStartProtectingDefault
    @AppStorage(VerifierConfig.backendURLDefaultsKey) private var backendURL = ""
    @AppStorage("speechLanguage") private var speechLanguage = "auto"
    @AppStorage("cloudEarAlwaysOn") private var cloudEarAlwaysOn = Defaults.current.cloudEarAlwaysOn
    @AppStorage("debugLogEnabled") private var debugLogEnabled = Defaults.current.debugLogEnabled
    @State private var showingRealAlertsConfirm = false
    @State private var showingWipeConfirm = false
    @State private var wiping = false
    @State private var wipeReport: DataWipeReport?
    @State private var connectionStatus: String?
    @State private var connectionOK = false
    @State private var testingConnection = false
    @State private var debugRouteShown = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                LiveSettingsSection()
                profileSection
                peopleSection
                codephrasesSection
                listeningSection
                alertsSection
                permissionsSection
                dataSection
                aboutSection
                #if DEBUG
                    developerSection
                #endif
                rerunSection
            }
            .navigationTitle("Settings")
            .confirmationDialog(
                "Send real alerts?",
                isPresented: $showingRealAlertsConfirm,
                titleVisibility: .visible
            ) {
                Button("Send real alerts") {
                    model.sendRealAlerts = true
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your contacts will get real Telegram alerts on the next SOS. Only people who pressed Start get them.")
            }
            .confirmationDialog(
                "Delete all my data?",
                isPresented: $showingWipeConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete everything", role: .destructive) {
                    runWipe()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This cannot be undone. Contacts, history, recordings, settings and backend evidence are all deleted.")
            }
            .sheet(isPresented: $showingAccount) {
                NavigationStack {
                    ScrollView {
                        AccountFlowView(onFinished: { showingAccount = false })
                            .padding()
                    }
                    .background(DS.Colors.background)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showingAccount = false }
                        }
                    }
                }
            }
            .confirmationDialog(
                "Delete your account?", isPresented: $confirmDeleteAccount, titleVisibility: .visible
            ) {
                Button("Delete my account", role: .destructive) {
                    Task { await account.deleteAccount() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your profile is removed from the Safeguard server and you are signed out. Contacts, history and recordings on this phone stay until you use Delete all my data.")
            }
            .alert("Delete all my data", isPresented: Binding(
                get: { wipeReport != nil },
                set: { if !$0 { wipeReport = nil } }
            )) {
                Button("Done — restart setup") {
                    // The wipe kept this key so the report could show; now go.
                    UserDefaults.standard.removeObject(forKey: "setupComplete")
                    wipeReport = nil
                }
            } message: {
                Text(wipeMessage)
            }
            #if DEBUG
                .navigationDestination(isPresented: $debugRouteShown) {
                    PreviewStatesView()
                }
                .onAppear {
                    if UserDefaults.standard.string(forKey: "debugInitialRoute") == "preview-states",
                       !debugRouteShown
                    {
                        debugRouteShown = true
                    }
                }
            #endif
        }
    }


    private var accountSection: some View {
        Section {
            if let profile = account.profile {
                NavigationLink {
                    ProfileView()
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(data: account.avatarData, name: profile.name, size: 52)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name).font(.headline)
                            Text(profile.email).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                Button("Sign out") { Task { await account.signOut() } }
                Button("Delete my account", role: .destructive) { confirmDeleteAccount = true }
            } else {
                Button("Create account or sign in") { showingAccount = true }
            }
            if let error = account.errorMessage {
                Text(error).font(.footnote).foregroundStyle(DS.Colors.danger)
            }
        } header: {
            Text("Account")
        } footer: {
            Text("Your account keeps your profile and optional photo on the Safeguard server.")
        }
    }

    private var profileSection: some View {
                    Section("Profile") {
                        TextField("Your display name", text: $model.wearerName)
                            .textInputAutocapitalization(.words)
                            .disableAutocorrection(true)
                        Text("Shown in SOS alerts to your contacts.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
    }
    private var peopleSection: some View {
                    Section("People") {
                        Button("Emergency contacts") {
                            NotificationCenter.default.post(
                                name: .safeguardOpenContacts, object: nil
                            )
                        }
                    }
    }
    private var codephrasesSection: some View {
                    Section("Code phrases") {
                        NavigationLink("Edit code phrases") {
                            SetupPhrasesStep(valid: .constant(true))
                                .padding()
                                .navigationTitle("Code phrases")
                                .navigationBarTitleDisplayMode(.inline)
                        }
                    }
    }
    private var listeningSection: some View {
                    Section {
                        ForEach(ListeningChoices.all) { choice in
                            ListeningToggle(choice)
                        }
                        Picker("Listening sensitivity", selection: $listenSensitivity) {
                            Text("Normal").tag(ListenSensitivity.normal.rawValue)
                            Text("High").tag(ListenSensitivity.high.rawValue)
                            Text("Maximum").tag(ListenSensitivity.max.rawValue)
                        }
                        Toggle("More than 5 rude gestures starts an SOS", isOn: $gesturesTriggerSOS)
                        Toggle("Start protecting when the app opens", isOn: $autoStartProtecting)
                        Picker("Speech language", selection: $speechLanguage) {
                            Text("Automatic").tag("auto")
                            Text("English (India)").tag("en")
                            Text("Hindi").tag("hi")
                        }
                    } header: {
                        Text("Listening")
                    } footer: {
                        Text("Recording laws differ by country: check yours before switching listening on.")
                    }
    }
    private var alertsSection: some View {
                    Section("Alerts") {
                        Toggle("Send real alerts", isOn: Binding(
                            get: { model.sendRealAlerts },
                            set: { enabled in
                                if enabled {
                                    showingRealAlertsConfirm = true
                                } else {
                                    model.sendRealAlerts = false
                                }
                            }
                        ))
                        Button("Send test alert to my contacts") {
                            model.sendTestAlert()
                        }
                    }
    }
    private var permissionsSection: some View {
                    Section("Permissions") {
                        ForEach(SetupPermission.allCases) { permission in
                            permissionRow(permission)
                        }
                    }
    }
    private var dataSection: some View {
                    Section("Data") {
                        Button("Delete all my data", role: .destructive) {
                            showingWipeConfirm = true
                        }
                        .disabled(wiping)
                        Text(Self.dataExplanation)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
    }
    private var aboutSection: some View {
                    Section("About") {
                        LabeledContent("Version", value: AboutInfo.version)
                        LabeledContent("Build", value: AboutInfo.build)
                        Text(Self.aboutPrivacy)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
    }
    #if DEBUG
        private var developerSection: some View {
                        Section {
                            NavigationLink("Preview states") {
                                PreviewStatesView()
                            }
                            Button("Simulate SOS (no camera)") { model.debugSimulateSOS() }
                            Toggle("Detection overlay", isOn: $debugOverlayEnabled)
                            Toggle("Cloud ear always on (demo)", isOn: $cloudEarAlwaysOn)
                            Toggle(
                                "Debug log (sends what is heard to your backend)",
                                isOn: $debugLogEnabled
                            )
                            TextField("http://192.168.1.20:8000", text: $backendURL)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Button {
                                testConnection()
                            } label: {
                                if testingConnection {
                                    ProgressView()
                                } else {
                                    Text("Test connection")
                                }
                            }
                            .disabled(testingConnection)
                            if let connectionStatus {
                                Label {
                                    Text(connectionStatus)
                                } icon: {
                                    Image(
                                        systemName: connectionOK
                                            ? "checkmark.circle.fill" : "xmark.circle.fill"
                                    )
                                }
                                .font(.footnote)
                                .foregroundStyle(connectionOK ? DS.Colors.ok : DS.Colors.danger)
                            }
                        } header: {
                            Text("Developer")
                        } footer: {
                            Text("The Mac running the backend, on the same Wi-Fi. Leave empty to use the build-time URL. 127.0.0.1 only works in the Simulator.")
                        }
        }
    #endif
    private var rerunSection: some View {
                    Section {
                        Button("Run setup again") {
                            NotificationCenter.default.post(
                                name: .safeguardRunSetup, object: nil
                            )
                        }
                    } footer: {
                        Text("Walks through first-run setup again without deleting anything.")
                    }
    }

    private func permissionRow(_ permission: SetupPermission) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                Text(permission.reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if SetupPermissions.status(of: permission) == .granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(DS.Colors.ok)
                    .accessibilityLabel(Text(format: "%@ granted", permission.title))
            } else {
                Button("Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
                .buttonStyle(.bordered)
                .minTouchTarget()
                .accessibilityLabel(Text(format: "Open Settings for %@", permission.title))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func runWipe() {
        guard !wiping else { return }
        wiping = true
        Task {
            let report = await model.deleteAllMyData(keepingSetup: true)
            await MainActor.run {
                wiping = false
                wipeReport = report
            }
        }
    }

    private var wipeMessage: String {
        guard let report = wipeReport else { return "" }
        var parts: [String] = []
        parts.append(String(
            format: String(localized: "Settings cleared: %d."),
            report.removedKeys.count
        ))
        if report.removedFiles.isEmpty {
            parts.append(String(localized: "No local history or recordings."))
        } else {
            parts.append(String(
                format: String(localized: "Removed: %@."),
                report.removedFiles.joined(separator: ", ") as NSString
            ))
        }
        let backendOK = report.backendDeleted.count
        let backendFailed = report.backendFailed.count
        if backendOK + backendFailed == 0 {
            parts.append(String(localized: "Nothing stored on the backend."))
        } else {
            parts.append(String(
                format: String(localized: "Backend: %d deleted, %d failed."),
                backendOK, backendFailed
            ))
            if backendFailed > 0 {
                parts.append(String(localized: "Some backend items could not be deleted (offline?). Delete them from the backend directly."))
            }
        }
        return parts.joined(separator: " ")
    }

    #if DEBUG
        private func testConnection() {
            testingConnection = true
            connectionStatus = nil
            Task {
                let url = VerifierConfig.default.baseURL
                let ok = await VerifierClient().checkHealth()
                connectionOK = ok
                connectionStatus = ok
                    ? L10n.format("Reachable: %@", url.absoluteString)
                    : L10n.format(
                        "Cannot reach %@. Check the URL, Wi-Fi, and that the backend listens on 0.0.0.0.",
                        url.absoluteString
                    )
                testingConnection = false
            }
        }
    #endif
}

extension SettingsView {
    static let dataExplanation = String(localized: "Wipes contacts, history, saved recordings and settings on this phone, and asks the backend to delete your evidence and contacts. Setup will restart.")

    static let aboutPrivacy = String(localized: "Safeguard watches for threatening behaviour — never appearance or identity. Transcripts stay on this phone unless you switch on a cloud helper; cloud features send data to your own Safeguard backend and on to Meta's models.")
}

/// Version and build read from the bundle (never a hard-coded label).
enum AboutInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }
}
