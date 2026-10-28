import Foundation
import Security

public protocol SecretStore: AnyObject, Sendable {
    func read(_ key: String) -> Data?
    func write(_ data: Data, for key: String)
    func remove(_ key: String)
}

public final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    private let service: String

    public init(service: String = "io.github.ujj14kal.safeguard.account") {
        self.service = service
    }

    private func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    public func read(_ key: String) -> Data? {
        var request = query(key)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    public func write(_ data: Data, for key: String) {
        remove(key)
        var item = query(key)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    public func remove(_ key: String) {
        SecItemDelete(query(key) as CFDictionary)
    }
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var values: [String: Data] = [:]
    private let lock = NSLock()

    public init() {}

    public func read(_ key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    public func write(_ data: Data, for key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = data
    }

    public func remove(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = nil
    }
}
