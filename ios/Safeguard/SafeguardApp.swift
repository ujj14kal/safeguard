import SwiftUI

@main
struct SafeguardApp: App {
    @State private var showSplash = true

    init() {
        VerifierConfig.reconcileBuildURL()
    }

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
            .preferredColorScheme(.dark)
            .task {
                CueEngineFactory.make = { MediaPipeCueEngine() }
                _ = ProtectViewModel.shared
                if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                    try? FileManager.default.removeItem(at: docs.appendingPathComponent("huggingface"))
                }
                await dismissSplash()
            }
        }
    }

    private func dismissSplash() async {
        #if DEBUG
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

struct SplashView: View {
    static let holdSeconds: Double = 3.5
    static let fadeOutSeconds: Double = 0.6

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
            Text("Safeguard")
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(Self.brandPurple)
                .opacity(titleVisible ? 1 : 0)
                .offset(y: Self.titleOffset + (titleVisible || reduceMotion ? 0 : 10))
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Safeguard")
        .onAppear {
            withAnimation(.easeOut(duration: 0.9).delay(0.5)) {
                titleVisible = true
            }
            withAnimation(.easeInOut(duration: Self.holdSeconds)) {
                settled = true
            }
        }
    }
}

#Preview {
    SplashView()
}
