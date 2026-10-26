import SwiftUI

/// Main tab structure: Protect, Contacts, Activity, Settings.
/// Contacts/Activity/Settings are shells until Phase 7.
struct ContentView: View {
    @State private var selection: Tab = .protect

    enum Tab: Hashable {
        case protect, contacts, activity, settings
    }

    var body: some View {
        TabView(selection: $selection) {
            ProtectView()
                .tabItem { Label("Protect", systemImage: "shield.fill") }
                .tag(Tab.protect)
            ContactsPlaceholderView()
                .tabItem { Label("Contacts", systemImage: "person.2.fill") }
                .tag(Tab.contacts)
            ActivityPlaceholderView()
                .tabItem { Label("Activity", systemImage: "list.bullet.clipboard") }
                .tag(Tab.activity)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .onAppear {
            #if DEBUG
                // Headless screenshot hook (Simulator):
                // defaults write com.safeguard.app debugInitialTab settings
                if UserDefaults.standard.string(forKey: "debugInitialTab") == "settings" {
                    selection = .settings
                }
            #endif
        }
    }
}

#Preview {
    ContentView()
}
