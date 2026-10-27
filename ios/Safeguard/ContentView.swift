import SwiftUI

/// Main tab structure: Protect, Contacts, Activity, Settings.
/// First launch shows the blocking setup flow instead (old installs that
/// saw the one-screen onboarding go straight to the tabs).
struct ContentView: View {
    @State private var selection: Tab = .protect
    @AppStorage("onboardingSeen") private var onboardingSeen = false
    @AppStorage("setupComplete") private var setupComplete = false
    @AppStorage("setupStep") private var savedStep = SetupStep.welcome.rawValue
    @State private var rerunSetup = false

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

    /// Blocking setup: no way to reach the app until it completes.
    /// The debug bypass stays DEBUG-only (screenshots start past it).
    private var showSetup: Bool {
        if rerunSetup { return true }
        #if DEBUG
            if onboardingBypassed { return false }
        #endif
        return !setupComplete && !onboardingSeen
    }

    var body: some View {
        if showSetup {
            SetupFlowView(rerun: $rerunSetup)
        } else {
            tabsView
        }
    }

    private var tabsView: some View {
        TabView(selection: $selection) {
            ProtectView()
                .tabItem { Label("Protect", systemImage: "shield.fill") }
                .tag(Tab.protect)
            ContactsView()
                .tabItem { Label("Contacts", systemImage: "person.2.fill") }
                .tag(Tab.contacts)
            ActivityView()
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
        .onReceive(NotificationCenter.default.publisher(for: .safeguardRunSetup)) { _ in
            savedStep = SetupStep.welcome.rawValue
            rerunSetup = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .safeguardOpenContacts)) { _ in
            selection = .contacts
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
    }
}

#Preview {
    ContentView()
}
