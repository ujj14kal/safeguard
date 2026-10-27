import Foundation
import SwiftUI

/// The signed-in state of this phone. Tokens live in the Keychain, the
/// cached profile (for Settings) in UserDefaults; the source of truth is
/// the backend. The app works without an account: this store only adds
/// the profile and its backup.
@MainActor
public final class AccountStore: ObservableObject {
    public static let shared = AccountStore()

    static let profileKey = "accountProfileJSON"
    static let sessionKey = "account.session"

    @Published public private(set) var profile: AccountProfile?
    @Published public private(set) var isBusy = false
    @Published public var errorMessage: String?
    /// Set after a sign-up that needs the email link opened first.
    @Published public private(set) var needsConfirmation = false

    private let service: AccountService
    private let secrets: SecretStore
    private let defaults: UserDefaults

    public init(
        service: AccountService = AccountClient(),
        secrets: SecretStore = KeychainSecretStore(),
        defaults: UserDefaults = .standard
    ) {
        self.service = service
        self.secrets = secrets
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.profileKey),
           let cached = try? JSONDecoder().decode(AccountProfile.self, from: data),
           loadSession() != nil
        {
            profile = cached
        }
    }

    public var isSignedIn: Bool { profile != nil }

    // MARK: Sign up / in / out

    @discardableResult
    public func signUp(
        name: String, email: String, password: String, phone: String,
        consent: Bool, language: String
    ) async -> Bool {
        if let problem = AccountValidation.signupProblem(
            name: name, email: email, password: password, phone: phone, consent: consent
        ) {
            errorMessage = problem
            return false
        }
        return await run {
            let result = try await self.service.signUp(
                name: Self.clean(name), email: Self.clean(email).lowercased(),
                password: password, phone: Self.clean(phone), language: language
            )
            self.accept(result)
        }
    }

    @discardableResult
    public func signIn(email: String, password: String) async -> Bool {
        if let problem = AccountValidation.signinProblem(email: email, password: password) {
            errorMessage = problem
            return false
        }
        return await run {
            let result = try await self.service.signIn(
                email: Self.clean(email).lowercased(), password: password
            )
            self.accept(result)
        }
    }

    public func signOut() async {
        if let token = loadSession()?.accessToken {
            await service.signOut(accessToken: token)
        }
        clearLocal()
    }

    /// Deletes the account on the server, then everything local.
    @discardableResult
    public func deleteAccount() async -> Bool {
        guard let token = await validAccessToken() else {
            errorMessage = String(localized: "Please sign in again.")
            return false
        }
        let done = await run { try await self.service.deleteAccount(accessToken: token) }
        if done { clearLocal() }
        return done
    }

    /// Forgets the account on this phone only (used by "Delete all my
    /// data", which separately asks the server to delete the account).
    public func clearLocal() {
        secrets.remove(Self.sessionKey)
        defaults.removeObject(forKey: Self.profileKey)
        profile = nil
        needsConfirmation = false
    }

    // MARK: Profile

    @discardableResult
    public func updateProfile(name: String?, phone: String?, language: String? = nil) async -> Bool {
        if let name, !SetupMachine.nameValid(name) {
            errorMessage = String(localized: "Enter your name (1 to 40 characters).")
            return false
        }
        if let phone, !AccountValidation.phoneValid(phone) {
            errorMessage = String(localized: "Enter a valid phone number, or leave it empty.")
            return false
        }
        guard let token = await validAccessToken() else { return false }
        return await run {
            let updated = try await self.service.updateProfile(
                accessToken: token, name: name.map(Self.clean), phone: phone.map(Self.clean),
                language: language
            )
            self.profile = updated
            self.persist(updated)
            self.defaults.set(updated.name, forKey: "wearerName")
        }
    }

    /// Pulls the latest profile (name edits made elsewhere); a dead
    /// session signs this phone out quietly.
    public func refreshProfile() async {
        guard isSignedIn, let token = await validAccessToken() else { return }
        if let fresh = try? await service.profile(accessToken: token) {
            profile = fresh
            persist(fresh)
        }
    }

    /// A usable access token, refreshing it when it is about to expire.
    public func validAccessToken() async -> String? {
        guard let session = loadSession() else { return nil }
        if !session.isExpired() { return session.accessToken }
        do {
            let renewed = try await service.refresh(refreshToken: session.refreshToken)
            save(renewed)
            return renewed.accessToken
        } catch let error as AccountError where error.status == 401 {
            clearLocal()
            return nil
        } catch {
            return nil
        }
    }

    // MARK: Internals

    private func accept(_ result: AccountAuthResult) {
        needsConfirmation = result.needsConfirmation
        if let session = result.session {
            save(session)
            profile = result.profile
            persist(result.profile)
            // The name the alerts use follows the account.
            defaults.set(result.profile.name, forKey: "wearerName")
        }
    }

    private func run(_ work: @escaping () async throws -> Void) async -> Bool {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await work()
            return true
        } catch let error as AccountError {
            errorMessage = error.message
            return false
        } catch {
            errorMessage = String(localized: "Something went wrong. Please try again.")
            return false
        }
    }

    private func loadSession() -> AccountSession? {
        guard let data = secrets.read(Self.sessionKey) else { return nil }
        return try? JSONDecoder().decode(AccountSession.self, from: data)
    }

    private func save(_ session: AccountSession) {
        if let data = try? JSONEncoder().encode(session) {
            secrets.write(data, for: Self.sessionKey)
        }
    }

    private func persist(_ profile: AccountProfile) {
        if let data = try? JSONEncoder().encode(profile) {
            defaults.set(data, forKey: Self.profileKey)
        }
    }

    private static func clean(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
