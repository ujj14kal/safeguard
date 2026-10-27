import SwiftUI

@main
struct SafeguardApp: App {
    @State private var showSplash = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                if showSplash {
                    SplashView()
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .statusBarHidden(showSplash)
            // Dark theme, forced app-wide (the splash stays white by design).
            .preferredColorScheme(.dark)
            .task {
                _ = ProtectViewModel.shared
                // An earlier build downloaded a 889 MB on-device model; it is
                // no longer used, so reclaim the space.
                if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                    try? FileManager.default.removeItem(at: docs.appendingPathComponent("huggingface"))
                }
                await dismissSplash()
            }
        }
    }

    /// Holds the splash for `SplashView.holdSeconds`, then cross-fades into the app.
    private func dismissSplash() async {
        #if DEBUG
            // Skip while developing: defaults write io.github.ujj14kal.safeguard skipSplash -bool YES
            if UserDefaults.standard.bool(forKey: "skipSplash") {
                showSplash = false
                return
            }
        #endif
        try? await Task.sleep(for: .seconds(SplashView.holdSeconds))
        withAnimation(.easeInOut(duration: SplashView.fadeOutSeconds)) {
            showSplash = false
        }
    }
}

/// In-app splash: the logo with "SafeGuard" beneath it, shown for about 3.5 s
/// on every launch, then a smooth cross-fade into the app.
///
/// The system launch screen (Info.plist `UILaunchScreen`) already shows the
/// same `LaunchLogo` image, centred on the same white, at the same size. This
/// view therefore starts with the logo fully visible in exactly that place, so
/// there is no flash or jump at the hand-off; only the title animates in.
struct SplashView: View {
    /// How long the splash stays before fading out (the brief asked for 3-4 s).
    static let holdSeconds: Double = 3.5
    static let fadeOutSeconds: Double = 0.6

    /// Logo is 220 pt tall (the asset's natural size); the title sits below it.
    private static let titleOffset: CGFloat = 110 + 44

    private static let brandPurple = DS.Colors.brandPurple

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var titleVisible = false
    @State private var settled = false

    var body: some View {
        ZStack {
            Color("LaunchBackground")
                .ignoresSafeArea()
            Image("LaunchLogo")
                .scaleEffect(settled && !reduceMotion ? 1.04 : 1.0)
                .accessibilityHidden(true)
            Text("SafeGuard")
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(Self.brandPurple)
                .opacity(titleVisible ? 1 : 0)
                .offset(y: Self.titleOffset + (titleVisible || reduceMotion ? 0 : 10))
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("SafeGuard")
        .onAppear {
            // Title fades and rises into place after a short beat.
            withAnimation(.easeOut(duration: 0.9).delay(0.5)) {
                titleVisible = true
            }
            // The logo breathes very slightly for the rest of the hold.
            withAnimation(.easeInOut(duration: Self.holdSeconds)) {
                settled = true
            }
        }
    }
}

#Preview {
    SplashView()
}
