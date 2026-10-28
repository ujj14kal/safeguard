import Foundation

/// Each install gets its own signed token from the backend on first launch,
/// so no shared secret ships in the app or the repository. The token lives
/// in the Keychain and is replaced automatically if the server rejects it.
public actor DeviceRegistrar {
    public static let shared = DeviceRegistrar()
    static let key = "device.token"

    private let secrets: SecretStore
    private let fetch: @Sendable (URL) async -> String?
    private var inFlight: Task<String?, Never>?

    public init(
        secrets: SecretStore = KeychainSecretStore(),
        fetch: @escaping @Sendable (URL) async -> String? = DeviceRegistrar.requestToken
    ) {
        self.secrets = secrets
        self.fetch = fetch
    }

    public nonisolated var current: String? {
        secrets.read(Self.key).flatMap { String(data: $0, encoding: .utf8) }
    }

    @discardableResult
    public func ensure(baseURL: URL) async -> String? {
        if let existing = current { return existing }
        if let task = inFlight { return await task.value }
        let task = Task { [fetch, secrets] () -> String? in
            guard let token = await fetch(baseURL), !token.isEmpty else { return nil }
            secrets.write(Data(token.utf8), for: Self.key)
            return token
        }
        inFlight = task
        let token = await task.value
        inFlight = nil
        return token
    }

    public func renew(baseURL: URL) async -> String? {
        secrets.remove(Self.key)
        return await ensure(baseURL: baseURL)
    }

    public static let requestToken: @Sendable (URL) async -> String? = { baseURL in
        var request = URLRequest(
            url: baseURL.appendingPathComponent("device/register"), timeoutInterval: 20
        )
        request.httpMethod = "POST"
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        struct Body: Decodable { var token: String }
        return (try? JSONDecoder().decode(Body.self, from: data))?.token
    }
}
