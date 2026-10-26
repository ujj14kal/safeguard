import SwiftUI

/// Tab shells. Real Contacts/Activity/Settings arrive in Phase 7; Settings
/// already hosts the debug section (debug builds only).
struct ContactsPlaceholderView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Contacts", systemImage: "person.2.fill",
                description: Text("Emergency contacts arrive in Phase 7.")
            )
            .navigationTitle("Contacts")
        }
    }
}

struct ActivityPlaceholderView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Activity", systemImage: "list.bullet.clipboard",
                description: Text("Incident history arrives in Phase 7.")
            )
            .navigationTitle("Activity")
        }
    }
}

struct SettingsView: View {
    @State private var debugRouteShown = false

    var body: some View {
        NavigationStack {
            Form {
                Section("About") {
                    LabeledContent("Version", value: "0.1.0 (Phase 1)")
                }
                #if DEBUG
                    Section("Debug") {
                        NavigationLink("Preview states") {
                            PreviewStatesView()
                        }
                        Text("The detection overlay arrives with Phase 2.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
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
}
