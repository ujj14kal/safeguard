import SwiftUI

/// Tab shells. Real Contacts/Activity/Settings arrive in Phase 7; Settings
/// already hosts the debug section (debug builds only).
struct ContactsPlaceholderView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Contacts", systemImage: "person.2.fill")
                    .foregroundStyle(DS.Colors.accent)
            } description: {
                Text("Emergency contacts arrive in Phase 7.")
            }
            .navigationTitle("Contacts")
        }
    }
}

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
    @AppStorage("listenerOptIn") private var listenerOptIn = false
    @AppStorage("speechLanguage") private var speechLanguage = "auto"
    @State private var connectionStatus: String?
    @State private var testingConnection = false

    var body: some View {
        NavigationStack {
            Form {
                Section("About") {
                    LabeledContent("Version", value: "0.5.0 (Phase 5)")
                }
                Section {
                    Toggle("Listen for threatening speech", isOn: $listenerOptIn)
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
