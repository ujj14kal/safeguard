import SwiftUI

/// Main tab structure: Protect, Contacts, Activity, Settings.
/// Contacts/Activity/Settings are shells until Phase 7.
struct ContentView: View {
    @State private var selection: Tab = .protect
    @AppStorage("onboardingSeen") private var onboardingSeen = false

    enum Tab: Hashable {
        case protect, contacts, activity, settings
    }

    #if DEBUG
        /// Headless hooks bypass onboarding: screenshots start past it.
        private var onboardingBypassed: Bool {
            UserDefaults.standard.string(forKey: "debugInitialTab") != nil
                || UserDefaults.standard.string(forKey: "debugInitialRoute") != nil
        }
    #endif

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
        .tint(DS.Colors.accent)
        .onReceive(NotificationCenter.default.publisher(for: .safeguardOpenSettings)) { _ in
            selection = .settings
        }
        .onReceive(NotificationCenter.default.publisher(for: .safeguardGoBack)) { _ in
            selection = .protect
        }
        .onAppear {
            #if DEBUG
                // Headless screenshot hook (Simulator):
                // defaults write io.github.ujj14kal.safeguard debugInitialTab settings
                if UserDefaults.standard.string(forKey: "debugInitialTab") == "settings" {
                    selection = .settings
                }
            #endif
        }
        .sheet(
            isPresented: Binding(
                get: {
                    #if DEBUG
                        !onboardingSeen && !onboardingBypassed
                    #else
                        !onboardingSeen
                    #endif
                },
                set: { if !$0 { onboardingSeen = true } }
            )
        ) {
            OnboardingView(onDone: { onboardingSeen = true })
        }
    }
}

#Preview {
    ContentView()
}
