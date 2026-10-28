import SwiftUI

struct ContentView: View {
    @State private var selection: Tab = .dashboard
    @AppStorage("onboardingSeen") private var onboardingSeen = false
    @AppStorage("setupComplete") private var setupComplete = false
    @AppStorage("setupStep") private var savedStep = SetupStep.welcome.rawValue
    @State private var rerunSetup = false
    @StateObject private var account = AccountStore.shared
    @StateObject private var safeArrival = SafeArrivalStore.shared
    @StateObject private var protection = ProtectViewModel.shared
    @AppStorage("autoStartProtecting") private var autoStart = Defaults.autoStartProtectingDefault
    @State private var autoStartTried = false
    @Environment(\.scenePhase) private var scenePhase
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    enum Tab: Hashable {
        case dashboard, contacts, activity, settings
    }

    #if DEBUG
        private var onboardingBypassed: Bool {
            UserDefaults.standard.string(forKey: "debugInitialTab") != nil
                || UserDefaults.standard.string(forKey: "debugInitialRoute") != nil
        }
    #endif

    private var showSetup: Bool {
        if rerunSetup { return true }
        #if DEBUG
            if onboardingBypassed { return false }
        #endif
        return !setupComplete && !onboardingSeen
    }

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
        ZStack {
            tabs
            if protection.isProtecting {
                ProtectView()
                    .transition(.opacity)
                    .zIndex(1)
            } else if protection.isStarting {
                ZStack {
                    DS.Colors.background.opacity(0.96).ignoresSafeArea()
                    LoadingScreen(
                        title: String(localized: "Starting protection"),
                        steps: LoadingScreen.protectionSteps
                    )
                }
                .transition(.opacity)
                .zIndex(2)
            }
        }
        .animation(DS.Motion.smooth, value: protection.isProtecting)
        .animation(DS.Motion.smooth, value: protection.isStarting)
        .task { await autoStartIfWanted() }
    }

    private func autoStartIfWanted() async {
        guard autoStart, setupComplete, !autoStartTried, !protection.isProtecting,
              SetupPermissions.status(of: .camera) == .granted
        else { return }
        autoStartTried = true
        try? await Task.sleep(for: .milliseconds(3900))
        guard !protection.isProtecting else { return }
        await protection.startCamera()
    }

    private var tabs: some View {
        TabView(selection: $selection.animation(DS.Motion.snappy)) {
            DashboardView()
                .tabItem { Label("Dashboard", systemImage: "square.grid.2x2.fill") }
                .tag(Tab.dashboard)
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
        .onReceive(tick) { _ in checkSafeArrival() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { checkSafeArrival() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .safeguardOpenSettings)) { _ in
            selection = .settings
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
                let initial = UserDefaults.standard.string(forKey: "debugInitialTab")
                if initial == "settings" {
                    selection = .settings
                } else if initial == "sos" {
                    ProtectViewModel.shared.debugSimulateSOS()
                }
            #endif
        }
    }
}

#Preview {
    ContentView()
}

extension ContentView {
    fileprivate func checkSafeArrival() {
        guard safeArrival.consumeOverdue() else { return }
        ProtectViewModel.shared.safeArrivalExpired()
    }
}
