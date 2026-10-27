import XCTest

/// Account rules: client-side validation, the store's sign-up/in/out and
/// session handling (fake service, in-memory secrets, sandbox defaults).
final class AccountValidationTests: XCTestCase {
    func testEmail() {
        XCTAssertTrue(AccountValidation.emailValid("asha@example.test"))
        XCTAssertTrue(AccountValidation.emailValid("  a.b+c@mail.co.in "))
        XCTAssertFalse(AccountValidation.emailValid("asha@example"))
        XCTAssertFalse(AccountValidation.emailValid("@example.com"))
        XCTAssertFalse(AccountValidation.emailValid("a b@example.com"))
        XCTAssertFalse(AccountValidation.emailValid("asha@@example.com"))
    }

    func testPhoneIsOptionalButChecked() {
        XCTAssertTrue(AccountValidation.phoneValid(""))
        XCTAssertTrue(AccountValidation.phoneValid("+1 555 0101"))
        XCTAssertFalse(AccountValidation.phoneValid("12"))
        XCTAssertFalse(AccountValidation.phoneValid("abc1234567"))
    }

    func testPasswordRules() {
        XCTAssertNotNil(AccountValidation.passwordProblem("Ab1"))
        XCTAssertNotNil(AccountValidation.passwordProblem("alllowercase1"))
        XCTAssertNotNil(AccountValidation.passwordProblem("NoDigitsHere"))
        XCTAssertNotNil(AccountValidation.passwordProblem(String(repeating: "Aa1", count: 30)))
        XCTAssertNil(AccountValidation.passwordProblem("Zebra-crossing7"))
    }

    func testSignupProblemOrder() {
        func problem(
            name: String = "Asha", email: String = "a@b.co", pw: String = "Zebra-crossing7",
            phone: String = "", consent: Bool = true
        ) -> String? {
            AccountValidation.signupProblem(
                name: name, email: email, password: pw, phone: phone, consent: consent
            )
        }
        XCTAssertNil(problem())
        XCTAssertNotNil(problem(name: " "))
        XCTAssertNotNil(problem(email: "x"))
        XCTAssertNotNil(problem(pw: "short"))
        XCTAssertNotNil(problem(phone: "x"))
        XCTAssertNotNil(problem(consent: false))
    }

    func testSessionExpiryMargin() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let live = AccountSession(accessToken: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(600))
        XCTAssertFalse(live.isExpired(now: now))
        let soon = AccountSession(accessToken: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(30))
        XCTAssertTrue(soon.isExpired(now: now))
    }

    func testReadableServerMessages() {
        let empty = Data("{}".utf8)
        XCTAssertEqual(AccountClient.readable(empty, status: 409),
                       "An account with this email already exists. Try signing in.")
        XCTAssertEqual(AccountClient.readable(Data(#"{"detail":"wrong email or password"}"#.utf8), status: 401),
                       "Wrong email or password.")
        XCTAssertEqual(AccountClient.readable(Data(#"{"detail":"use at least 8 characters"}"#.utf8), status: 422),
                       "use at least 8 characters")
        XCTAssertFalse(AccountClient.readable(empty, status: 500).contains("500"))
    }
}

@MainActor
final class AccountStoreTests: XCTestCase {
    private final class FakeService: AccountService, @unchecked Sendable {
        var signUpCalls = 0
        var refreshCalls = 0
        var deleted = false
        var signedOut = false
        var failSignIn = false
        var requireConfirmation = false
        var expiresIn: TimeInterval = 3600
        let tokenBase = "tok-" + String(repeating: "x", count: 6)

        func result(name: String, email: String, withSession: Bool) -> AccountAuthResult {
            AccountAuthResult(
                profile: AccountProfile(id: "u1", email: email, name: name, language: "en"),
                session: withSession
                    ? AccountSession(accessToken: tokenBase, refreshToken: "ref-" + tokenBase,
                                     expiresAt: Date().addingTimeInterval(expiresIn))
                    : nil,
                needsConfirmation: !withSession
            )
        }

        func signUp(name: String, email: String, password: String, phone: String?, language: String) async throws -> AccountAuthResult {
            signUpCalls += 1
            return result(name: name, email: email, withSession: !requireConfirmation)
        }

        func signIn(email: String, password: String) async throws -> AccountAuthResult {
            if failSignIn { throw AccountError("Wrong email or password.", status: 401) }
            return result(name: "Asha", email: email, withSession: true)
        }

        func refresh(refreshToken: String) async throws -> AccountSession {
            refreshCalls += 1
            return AccountSession(accessToken: "renewed", refreshToken: "ref2", expiresAt: Date().addingTimeInterval(3600))
        }

        func profile(accessToken: String) async throws -> AccountProfile {
            AccountProfile(id: "u1", email: "a@b.co", name: "Fresh")
        }

        func updateProfile(accessToken: String, name: String?, phone: String?, language: String?) async throws -> AccountProfile {
            AccountProfile(id: "u1", email: "a@b.co", name: name ?? "Asha", phone: phone)
        }

        func signOut(accessToken: String) async { signedOut = true }
        func deleteAccount(accessToken: String) async throws { deleted = true }
    }

    private var suite: UserDefaults!
    private var secrets: InMemorySecretStore!
    private var service: FakeService!
    private var store: AccountStore!
    private let pw = "Zebra-crossing7"

    override func setUp() {
        super.setUp()
        let name = "account-tests-\(UUID().uuidString)"
        suite = UserDefaults(suiteName: name)
        suite.removePersistentDomain(forName: name)
        secrets = InMemorySecretStore()
        service = FakeService()
        store = AccountStore(service: service, secrets: secrets, defaults: suite)
    }

    func testSignUpStoresSessionProfileAndName() async {
        let ok = await store.signUp(
            name: " Asha ", email: " Asha@Example.test ", password: pw, phone: "",
            consent: true, language: "en"
        )
        XCTAssertTrue(ok)
        XCTAssertEqual(store.profile?.name, "Asha")
        XCTAssertEqual(store.profile?.email, "asha@example.test")
        XCTAssertNotNil(secrets.read(AccountStore.sessionKey))
        XCTAssertNotNil(suite.data(forKey: AccountStore.profileKey))
        XCTAssertEqual(suite.string(forKey: "wearerName"), "Asha")
    }

    func testBadFormNeverReachesTheService() async {
        let ok = await store.signUp(
            name: "Asha", email: "bad", password: pw, phone: "", consent: true, language: "en"
        )
        XCTAssertFalse(ok)
        XCTAssertEqual(service.signUpCalls, 0)
        XCTAssertNotNil(store.errorMessage)
    }

    func testConfirmationRequiredMeansNotSignedIn() async {
        service.requireConfirmation = true
        let ok = await store.signUp(
            name: "Asha", email: "a@b.co", password: pw, phone: "", consent: true, language: "en"
        )
        XCTAssertTrue(ok)
        XCTAssertTrue(store.needsConfirmation)
        XCTAssertFalse(store.isSignedIn)
        XCTAssertNil(secrets.read(AccountStore.sessionKey))
    }

    func testWrongPasswordShowsServerMessage() async {
        service.failSignIn = true
        let ok = await store.signIn(email: "a@b.co", password: "nope")
        XCTAssertFalse(ok)
        XCTAssertEqual(store.errorMessage, "Wrong email or password.")
        XCTAssertFalse(store.isSignedIn)
    }

    func testSignOutClearsEverythingLocal() async {
        _ = await store.signIn(email: "a@b.co", password: pw)
        await store.signOut()
        XCTAssertTrue(service.signedOut)
        XCTAssertFalse(store.isSignedIn)
        XCTAssertNil(secrets.read(AccountStore.sessionKey))
        XCTAssertNil(suite.data(forKey: AccountStore.profileKey))
    }

    func testExpiredSessionIsRefreshed() async {
        service.expiresIn = 10 // inside the 60 s margin
        _ = await store.signIn(email: "a@b.co", password: pw)
        let token = await store.validAccessToken()
        XCTAssertEqual(token, "renewed")
        XCTAssertEqual(service.refreshCalls, 1)
    }

    func testRestoresFromStorageOnNextLaunch() async {
        _ = await store.signIn(email: "a@b.co", password: pw)
        let again = AccountStore(service: service, secrets: secrets, defaults: suite)
        XCTAssertTrue(again.isSignedIn)
    }

    func testProfileWithoutSessionIsNotRestored() async {
        _ = await store.signIn(email: "a@b.co", password: pw)
        secrets.remove(AccountStore.sessionKey)
        let again = AccountStore(service: service, secrets: secrets, defaults: suite)
        XCTAssertFalse(again.isSignedIn)
    }

    func testDeleteAccountWipesLocalToo() async {
        _ = await store.signIn(email: "a@b.co", password: pw)
        let ok = await store.deleteAccount()
        XCTAssertTrue(ok)
        XCTAssertTrue(service.deleted)
        XCTAssertFalse(store.isSignedIn)
        XCTAssertNil(secrets.read(AccountStore.sessionKey))
    }

    func testProfileUpdateValidatesName() async {
        _ = await store.signIn(email: "a@b.co", password: pw)
        let bad = await store.updateProfile(name: "   ", phone: nil)
        XCTAssertFalse(bad)
        let good = await store.updateProfile(name: "Asha R", phone: nil)
        XCTAssertTrue(good)
        XCTAssertEqual(store.profile?.name, "Asha R")
        XCTAssertEqual(suite.string(forKey: "wearerName"), "Asha R")
    }
}
