import Foundation

public actor DeviceRegistrar {
    public static let shared = DeviceRegistrar()
    static let key = "device.token"

    private let secrets: SecretStore
    private let fetch: @Sendable (URL) async -> String?
    private let memory = MemoryToken()
    private var inFlight: Task<String?, Never>?

    public init(
        secrets: SecretStore = KeychainSecretStore(),
        fetch: @escaping @Sendable (URL) async -> String? = DeviceRegistrar.requestToken
    ) {
        self.secrets = secrets
        self.fetch = fetch
    }

    public nonisolated var current: String? {
        memory.value ?? secrets.read(Self.key).flatMap { String(data: $0, encoding: .utf8) }
    }

    @discardableResult
    public func ensure(baseURL: URL) async -> String? {
        if let existing = current { return existing }
        if let task = inFlight { return await task.value }
        let task = Task { [fetch, secrets, memory] () -> String? in
            guard let token = await fetch(baseURL), !token.isEmpty else { return nil }
            memory.value = token
            secrets.write(Data(token.utf8), for: Self.key)
            return token
        }
        inFlight = task
        let token = await task.value
        inFlight = nil
        return token
    }

    public func renew(baseURL: URL) async -> String? {
        memory.value = nil
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

private final class MemoryToken: @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    var value: String? {
        get { lock.withLock { token } }
        set { lock.withLock { token = newValue } }
    }
}
