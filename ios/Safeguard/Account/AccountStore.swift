import Foundation
import SwiftUI

@MainActor
public final class AccountStore: ObservableObject {
    public static let shared = AccountStore()

    static let profileKey = "accountProfileJSON"
    static let sessionKey = "account.session"

    @Published public private(set) var profile: AccountProfile?
    @Published public private(set) var isBusy = false
    @Published public var errorMessage: String?
    @Published public private(set) var needsConfirmation = false
    @Published public private(set) var serverUnreachable = false

    private let service: AccountService
    private let secrets: SecretStore
    private let defaults: UserDefaults
    private let avatarCache: URL

    @Published public private(set) var avatarData: Data?

    public init(
        service: AccountService = AccountClient(),
        secrets: SecretStore = KeychainSecretStore(),
        defaults: UserDefaults = .standard,
        avatarCache: URL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("account-avatar.jpg")
    ) {
        self.service = service
        self.secrets = secrets
        self.defaults = defaults
        self.avatarCache = avatarCache
        avatarData = try? Data(contentsOf: avatarCache)
        if let data = defaults.data(forKey: Self.profileKey),
           let cached = try? JSONDecoder().decode(AccountProfile.self, from: data),
           loadSession() != nil || cached.isOffline
        {
            profile = cached
        }
    }

    public var isSignedIn: Bool { profile != nil }

    @discardableResult
    public func signUp(
        name: String, email: String, password: String, phone: String,
        consent: Bool, language: String, guardianCode: String = ""
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
                password: password, phone: Self.clean(phone), language: language,
                guardianCode: GuardianCode.normalized(guardianCode)
            )
            self.accept(result)
            if let code = GuardianCode.normalized(guardianCode), result.session != nil {
                self.defaults.set(code, forKey: GuardianCode.key)
            }
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

    @discardableResult
    public func continueOffline(name: String) -> Bool {
        guard SetupMachine.nameValid(name) else {
            errorMessage = String(localized: "Enter your name (1 to 40 characters).")
            return false
        }
        let local = AccountProfile(
            id: AccountProfile.offlineID, email: "", name: Self.clean(name),
            language: AppLanguage.alertLang
        )
        profile = local
        persist(local)
        defaults.set(local.name, forKey: "wearerName")
        errorMessage = nil
        serverUnreachable = false
        return true
    }

    public func signOut() async {
        if let token = loadSession()?.accessToken {
            await service.signOut(accessToken: token)
        }
        clearLocal()
    }

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

    public func clearLocal() {
        secrets.remove(Self.sessionKey)
        defaults.removeObject(forKey: Self.profileKey)
        try? FileManager.default.removeItem(at: avatarCache)
        avatarData = nil
        profile = nil
        needsConfirmation = false
        serverUnreachable = false
    }

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

    public func refreshProfile() async {
        guard isSignedIn, let token = await validAccessToken() else { return }
        if let fresh = try? await service.profile(accessToken: token) {
            profile = fresh
            persist(fresh)
        }
        await loadAvatar()
    }

    public func loadAvatar() async {
        guard isSignedIn, let token = await validAccessToken() else { return }
        guard let fetched = try? await service.avatar(accessToken: token) else { return }
        cacheAvatar(fetched)
    }

    @discardableResult
    public func setAvatar(_ image: UIImage) async -> Bool {
        guard let jpeg = AvatarImage.jpeg(from: image) else {
            errorMessage = String(localized: "Could not save the photo. Try again.")
            return false
        }
        guard let token = await validAccessToken() else { return false }
        let done = await run { try await self.service.setAvatar(accessToken: token, jpeg: jpeg) }
        if done { cacheAvatar(jpeg) }
        return done
    }

    @discardableResult
    public func removeAvatar() async -> Bool {
        guard let token = await validAccessToken() else { return false }
        let done = await run { try await self.service.removeAvatar(accessToken: token) }
        if done { cacheAvatar(nil) }
        return done
    }

    private func cacheAvatar(_ data: Data?) {
        avatarData = data
        if let data {
            try? FileManager.default.createDirectory(
                at: avatarCache.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? data.write(to: avatarCache, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: avatarCache)
        }
    }

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

    private func accept(_ result: AccountAuthResult) {
        needsConfirmation = result.needsConfirmation
        if let session = result.session {
            save(session)
            profile = result.profile
            persist(result.profile)
            defaults.set(result.profile.name, forKey: "wearerName")
        }
    }

    private func run(_ work: @escaping () async throws -> Void) async -> Bool {
        isBusy = true
        errorMessage = nil
        serverUnreachable = false
        defer { isBusy = false }
        do {
            try await work()
            return true
        } catch let error as AccountError {
            errorMessage = error.message
            serverUnreachable = error.status == nil || error.status == 503
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
