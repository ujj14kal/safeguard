import XCTest


final class BuildURLReconcileTests: XCTestCase {
    private func suite() -> UserDefaults {
        let name = "reconcile-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testNewBuildAddressClearsAStaleOverride() {
        let defaults = suite()
        defaults.set("http://10.0.0.5:8000", forKey: VerifierConfig.backendURLDefaultsKey)
        defaults.set("https://old.example.test", forKey: VerifierConfig.lastBuildURLDefaultsKey)
        VerifierConfig.reconcileBuildURL(defaults: defaults, plistValue: "https://new.example.test")
        XCTAssertNil(defaults.string(forKey: VerifierConfig.backendURLDefaultsKey))
        XCTAssertEqual(defaults.string(forKey: VerifierConfig.lastBuildURLDefaultsKey), "https://new.example.test")
    }

    func testSameBuildAddressKeepsTheOverride() {
        let defaults = suite()
        defaults.set("https://built.example.test", forKey: VerifierConfig.lastBuildURLDefaultsKey)
        defaults.set("http://10.0.0.5:8000", forKey: VerifierConfig.backendURLDefaultsKey)
        VerifierConfig.reconcileBuildURL(defaults: defaults, plistValue: "https://built.example.test")
        XCTAssertEqual(defaults.string(forKey: VerifierConfig.backendURLDefaultsKey), "http://10.0.0.5:8000")
    }

    func testFirstLaunchRecordsTheAddress() {
        let defaults = suite()
        VerifierConfig.reconcileBuildURL(defaults: defaults, plistValue: "https://built.example.test")
        XCTAssertEqual(defaults.string(forKey: VerifierConfig.lastBuildURLDefaultsKey), "https://built.example.test")
    }
}
