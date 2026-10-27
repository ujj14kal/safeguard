import SwiftUI

/// Main tab structure: Dashboard, Protect, Contacts, Activity, Settings.
/// First launch shows the blocking setup flow instead (old installs that
/// saw the one-screen onboarding go straight to the tabs).
struct ContentView: View {
    @State private var selection: Tab = .dashboard
    @AppStorage("onboardingSeen") private var onboardingSeen = false
    @AppStorage("setupComplete") private var setupComplete = false
    @AppStorage("setupStep") private var savedStep = SetupStep.welcome.rawValue
    @State private var rerunSetup = false
    @StateObject private var account = AccountStore.shared

    enum Tab: Hashable {
        case dashboard, protect, contacts, activity, settings
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

    /// An account is compulsory: nothing else is reachable until signed in.
    private var needsAccount: Bool {
        #if DEBUG
            if onboardingBypassed { return false }
        #endif
        return !account.isSignedIn
    }

    var body: some View {
        if needsAccount {
            AccountGateView()
        } else if showSetup {
            SetupFlowView(rerun: $rerunSetup)
        } else {
            tabsView
        }
    }

    private var tabsView: some View {
        TabView(selection: $selection.animation(DS.Motion.snappy)) {
            DashboardView()
                .tabItem { Label("Dashboard", systemImage: "square.grid.2x2.fill") }
                .tag(Tab.dashboard)
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
        .onReceive(NotificationCenter.default.publisher(for: .safeguardOpenActivity)) { _ in
            selection = .activity
        }
        .onReceive(NotificationCenter.default.publisher(for: .safeguardOpenDashboard)) { _ in
            selection = .dashboard
        }
        .onAppear {
            #if DEBUG
                // Headless screenshot hook (Simulator):
                // defaults write io.github.ujj14kal.safeguard debugInitialTab settings
                let initial = UserDefaults.standard.string(forKey: "debugInitialTab")
                if initial == "settings" {
                    selection = .settings
                } else if initial == "protect" {
                    selection = .protect
                } else if initial == "sos" {
                    selection = .protect
                    ProtectViewModel.shared.debugSimulateSOS()
                }
            #endif
        }
    }
}

#Preview {
    ContentView()
}
