import SwiftUI

/// Tab shells. Activity history arrives in Phase 7; Settings already
/// hosts the debug section (debug builds only). Contacts is real.
struct ActivityPlaceholderView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Activity", systemImage: "list.bullet.clipboard")
                    .foregroundStyle(DS.Colors.accent)
            } description: {
                Text("Incident history arrives in Phase 7.")
            }
            .navigationTitle("Activity")
        }
    }
}

struct SettingsView: View {
    @State private var debugRouteShown = false
    @AppStorage("debugOverlayEnabled") private var debugOverlayEnabled = false
    @AppStorage(VerifierConfig.backendURLDefaultsKey) private var backendURL = ""
    @AppStorage("listenerOptIn") private var listenerOptIn = Defaults.current.listenerOptIn
    @AppStorage("speechLanguage") private var speechLanguage = "auto"
    @AppStorage("aiJudgeEnabled") private var aiJudgeEnabled = Defaults.current.aiJudgeEnabled
    @AppStorage("cloudEarEnabled") private var cloudEarEnabled = Defaults.current.cloudEarEnabled
    @AppStorage("cloudEarAlwaysOn") private var cloudEarAlwaysOn = Defaults.current.cloudEarAlwaysOn
    @ObservedObject private var protect = ProtectViewModel.shared
    @AppStorage("distressWordsEnabled") private var distressWordsEnabled = Defaults.current.distressWordsEnabled
    @AppStorage("recordOnSOS") private var recordOnSOS = Defaults.current.recordOnSOS
    @AppStorage("shoutingTriggersSOS") private var shoutingTriggersSOS = Defaults.current.shoutingTriggersSOS
    @AppStorage("debugLogEnabled") private var debugLogEnabled = Defaults.current.debugLogEnabled
    @State private var connectionStatus: String?
    @State private var testingConnection = false
    @State private var showingRealAlertsConfirm = false

    var body: some View {
        NavigationStack {
            Form {
                Section("About") {
                    LabeledContent("Version", value: "0.6.0 (Phase 6)")
                }
                Section {
                    TextField("Your display name", text: $protect.wearerName)
                        .textInputAutocapitalization(.words)
                        .disableAutocorrection(true)
                    Toggle("Send real alerts", isOn: Binding(
                        get: { protect.sendRealAlerts },
                        set: { enabled in
                            if enabled {
                                showingRealAlertsConfirm = true
                            } else {
                                protect.sendRealAlerts = false
                            }
                        }
                    ))
                    Button("Send test alert to my contacts") {
                        protect.sendTestAlert()
                    }
                } header: {
                    Text("SOS")
                } footer: {
                    Text("Real alerts go out over Telegram only to contacts who pressed Start. Dry-run (off) only logs on the backend. Your display name is shown in SOS alerts.")
                }
                .confirmationDialog(
                    "Send real alerts?",
                    isPresented: $showingRealAlertsConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Send real alerts") {
                        protect.sendRealAlerts = true
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Your contacts will get real Telegram alerts on the next SOS. Only people who pressed Start get them.")
                }
                Section {
                    Toggle("Listen for threatening speech", isOn: $listenerOptIn)
                    Toggle("Cloud ear (Meta Muse Voice Transcribe)", isOn: $cloudEarEnabled)
                    Toggle("Cloud ear always on (demo)", isOn: $cloudEarAlwaysOn)
                    LabeledContent("Status", value: protect.cloudStatus)
                    Toggle("AI judges the conversation", isOn: $aiJudgeEnabled)
                    Toggle("Distress words start auto-SOS", isOn: $distressWordsEnabled)
                    Toggle("Shouting starts auto-SOS", isOn: $shoutingTriggersSOS)
                    Toggle("Record and upload during an SOS", isOn: $recordOnSOS)
                    Toggle("Debug log (sends what is heard to your backend)", isOn: $debugLogEnabled)
                    Picker("Speech language", selection: $speechLanguage) {
                        Text("Automatic").tag("auto")
                        Text("English (India)").tag("en")
                        Text("हिन्दी (Hindi)").tag("hi")
                    }
                } header: {
                    Text("Conversation listener")
                } footer: {
                    Text(OnboardingView.listenerDisclosure + " Recording laws differ by country: check yours before switching this on.")
                }
                #if DEBUG
                    Section("Debug") {
                        NavigationLink("Preview states") {
                            PreviewStatesView()
                        }
                        Toggle("Detection overlay", isOn: $debugOverlayEnabled)
                    }
                    Section {
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
                            Label(
                                connectionStatus,
                                systemImage: connectionStatus.hasPrefix("Reachable")
                                    ? "checkmark.circle.fill" : "xmark.circle.fill"
                            )
                            .font(.footnote)
                            .foregroundStyle(
                                connectionStatus.hasPrefix("Reachable") ? Color.green : Color.red
                            )
                        }
                    } header: {
                        Text("Verification backend")
                    } footer: {
                        Text("The Mac running the backend, on the same Wi-Fi. Leave empty to use the build-time URL. 127.0.0.1 only works in the Simulator.")
                    }
                #endif
            }
            .navigationTitle("Settings")
            #if DEBUG
                .navigationDestination(isPresented: $debugRouteShown) {
                    PreviewStatesView()
                }
                .onAppear {
                    // Headless screenshot hook (Simulator):
                    // defaults write io.github.ujj14kal.safeguard debugInitialRoute preview-states
                    if UserDefaults.standard.string(forKey: "debugInitialRoute") == "preview-states",
                       !debugRouteShown
                    {
                        debugRouteShown = true
                    }
                }
            #endif
        }
    }

    #if DEBUG
        private func testConnection() {
            testingConnection = true
            connectionStatus = nil
            Task {
                let url = VerifierConfig.default.baseURL
                let ok = await VerifierClient().checkHealth()
                connectionStatus = ok
                    ? "Reachable: \(url.absoluteString)"
                    : "Cannot reach \(url.absoluteString). Check the URL, Wi-Fi, and that the backend listens on 0.0.0.0."
                testingConnection = false
            }
        }
    #endif
}
