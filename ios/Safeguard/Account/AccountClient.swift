import Foundation

/// The backend calls the account screens need. A protocol so the store is
/// tested with a fake and no network.
public protocol AccountService: Sendable {
    func signUp(
        name: String, email: String, password: String, phone: String?, language: String,
        guardianCode: String?
    ) async throws -> AccountAuthResult
    func signIn(email: String, password: String) async throws -> AccountAuthResult
    func refresh(refreshToken: String) async throws -> AccountSession
    func profile(accessToken: String) async throws -> AccountProfile
    func updateProfile(
        accessToken: String, name: String?, phone: String?, language: String?
    ) async throws -> AccountProfile
    func signOut(accessToken: String) async
    func deleteAccount(accessToken: String) async throws
}

/// Talks to this app's own backend (never to Supabase directly: the keys
/// stay on the server). Every request carries the app token.
public struct AccountClient: AccountService {
    private let config: @Sendable () -> VerifierConfig
    private let session: URLSession

    public init(
        config: @escaping @Sendable () -> VerifierConfig = { VerifierConfig.default },
        session: URLSession = .shared
    ) {
        self.config = config
        self.session = session
    }

    // MARK: Wire types

    struct UserBody: Decodable {
        var id: String
        var email: String?
        var name: String?
        var phone: String?
        var language: String?
    }

    struct SessionBody: Decodable {
        var access_token: String
        var refresh_token: String
        var expires_in: Int
    }

    struct AuthBody: Decodable {
        var user: UserBody
        var session: SessionBody?
        var needs_confirmation: Bool?
    }

    struct RefreshBody: Decodable {
        var session: SessionBody
    }

    // MARK: Calls

    public func signUp(
        name: String, email: String, password: String, phone: String?, language: String,
        guardianCode: String?
    ) async throws -> AccountAuthResult {
        var body: [String: Any] = [
            "name": name, "email": email, "password": password,
            "language": language, "consent": true,
        ]
        if let phone, !phone.isEmpty { body["phone"] = phone }
        if let guardianCode, !guardianCode.isEmpty { body["guardian_code"] = guardianCode }
        return try await auth("auth/signup", body: body)
    }

    public func signIn(email: String, password: String) async throws -> AccountAuthResult {
        try await auth("auth/login", body: ["email": email, "password": password])
    }

    public func refresh(refreshToken: String) async throws -> AccountSession {
        let data = try await send(request("auth/refresh", method: "POST", json: ["refresh_token": refreshToken]))
        return try Self.session(from: decode(RefreshBody.self, data).session)
    }

    public func profile(accessToken: String) async throws -> AccountProfile {
        let data = try await send(request("me", method: "GET", bearer: accessToken))
        return Self.profile(from: try decode(UserBody.self, data))
    }

    public func updateProfile(
        accessToken: String, name: String?, phone: String?, language: String?
    ) async throws -> AccountProfile {
        var body: [String: Any] = [:]
        if let name { body["name"] = name }
        if let phone { body["phone"] = phone }
        if let language { body["language"] = language }
        let data = try await send(request("me", method: "PUT", json: body, bearer: accessToken))
        return Self.profile(from: try decode(UserBody.self, data))
    }

    public func signOut(accessToken: String) async {
        _ = try? await send(request("auth/logout", method: "POST", json: [:], bearer: accessToken))
    }

    public func deleteAccount(accessToken: String) async throws {
        _ = try await send(request("me", method: "DELETE", bearer: accessToken))
    }

    // MARK: Plumbing

    private func auth(_ path: String, body: [String: Any]) async throws -> AccountAuthResult {
        let data = try await send(request(path, method: "POST", json: body))
        let parsed = try decode(AuthBody.self, data)
        let session = try parsed.session.map { try Self.session(from: $0) }
        return AccountAuthResult(
            profile: Self.profile(from: parsed.user),
            session: session,
            needsConfirmation: parsed.needs_confirmation ?? (session == nil)
        )
    }

    private func request(
        _ path: String, method: String, json: [String: Any]? = nil, bearer: String? = nil
    ) throws -> URLRequest {
        var request = URLRequest(
            url: config().baseURL.appendingPathComponent(path), timeoutInterval: 30
        )
        request.httpMethod = method
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        return config().authorize(request)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AccountError(String(localized: "Could not reach the Safeguard server. Check your connection."))
        }
        guard let http = response as? HTTPURLResponse else {
            throw AccountError(String(localized: "Unexpected reply from the server."))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AccountError(Self.readable(data, status: http.statusCode), status: http.statusCode)
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw AccountError(String(localized: "Unexpected reply from the server."))
        }
    }

    /// Server text for the few cases the person can act on; calm generic
    /// words for the rest (never a raw status code or stack).
    static func readable(_ data: Data, status: Int) -> String {
        struct Detail: Decodable { var detail: String? }
        let detail = (try? JSONDecoder().decode(Detail.self, from: data))?.detail ?? ""
        switch status {
        case 401:
            return detail.contains("password") || detail.contains("email")
                ? String(localized: "Wrong email or password.")
                : String(localized: "Please sign in again.")
        case 409:
            return String(localized: "An account with this email already exists. Try signing in.")
        case 422:
            return detail.isEmpty ? String(localized: "Please check the details and try again.") : detail
        case 429:
            return String(localized: "Too many attempts. Wait a minute and try again.")
        case 503:
            return String(localized: "Accounts are not available right now. You can continue without one.")
        default:
            return String(localized: "Something went wrong. Please try again.")
        }
    }

    static func profile(from body: UserBody) -> AccountProfile {
        AccountProfile(
            id: body.id, email: body.email ?? "", name: body.name ?? "",
            phone: body.phone, language: body.language ?? "en"
        )
    }

    static func session(from body: SessionBody) throws -> AccountSession {
        AccountSession(
            accessToken: body.access_token, refreshToken: body.refresh_token,
            expiresAt: Date().addingTimeInterval(TimeInterval(body.expires_in))
        )
    }
}
