import Foundation
import SwiftUI

/// The person's standing live link and guardian code, as Settings shows
/// them. The link is created only after the person approves it; it stays
/// the same for every live stream and every SOS, so it can be shared once.
@MainActor
public final class LiveLinkStore: ObservableObject {
    public static let shared = LiveLinkStore()

    static let urlKey = "liveChannelURL"
    static let tokenKey = "liveChannelToken"
    static let deviceKey = "deviceID"

    @Published public private(set) var url: String?
    @Published public private(set) var guardianCode: String?
    @Published public private(set) var isBusy = false
    @Published public var errorMessage: String?

    private let client: IncidentClient
    private let defaults: UserDefaults

    public init(client: IncidentClient = IncidentClient(), defaults: UserDefaults = .standard) {
        self.client = client
        self.defaults = defaults
        url = defaults.string(forKey: Self.urlKey)
        guardianCode = defaults.string(forKey: GuardianCode.key)
    }

    /// Sent with every incident so the family link stays stable.
    public var token: String? { defaults.string(forKey: Self.tokenKey) }

    /// A random id for this phone, so the backend can hand back the same
    /// link again. Not tied to the person, a device, or an account.
    public var deviceID: String {
        if let existing = defaults.string(forKey: Self.deviceKey) { return existing }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: Self.deviceKey)
        return fresh
    }

    // MARK: Live link

    @discardableResult
    public func createLink(wearerName: String) async -> Bool {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let made = try await client.createChannel(deviceID: deviceID, wearerName: wearerName)
            defaults.set(made.url, forKey: Self.urlKey)
            defaults.set(made.token, forKey: Self.tokenKey)
            url = made.url
            return true
        } catch {
            errorMessage = String(localized: "Could not create the link. Check your connection and try again.")
            return false
        }
    }

    /// Re-reads the link from the server: same token, current address. The
    /// address changes when the backend's public address does (a quick
    /// tunnel restarts with a new one), so the saved copy can go stale.
    public func refreshLink(wearerName: String) async {
        guard url != nil, !isBusy else { return }
        if let made = try? await client.createChannel(deviceID: deviceID, wearerName: wearerName) {
            defaults.set(made.url, forKey: Self.urlKey)
            defaults.set(made.token, forKey: Self.tokenKey)
            url = made.url
        }
    }

    /// Revokes the link on the server and forgets it here. The old URL
    /// stops working at once.
    @discardableResult
    public func deleteLink() async -> Bool {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            _ = try await client.revokeChannel(deviceID: deviceID)
        } catch {
            errorMessage = String(localized: "Could not reach the server, so the link may still work. Try again.")
            return false
        }
        forgetLink()
        return true
    }

    /// Local forget only (used by "Delete all my data" after revoking).
    public func forgetLink() {
        defaults.removeObject(forKey: Self.urlKey)
        defaults.removeObject(forKey: Self.tokenKey)
        url = nil
    }

    // MARK: Guardian

    @discardableResult
    public func setGuardian(code raw: String) async -> Bool {
        errorMessage = nil
        guard let code = GuardianCode.normalized(raw) else {
            errorMessage = String(localized: "Enter the code as XXXX-XXXX-XXXX.")
            return false
        }
        isBusy = true
        defer { isBusy = false }
        do {
            guard try await client.guardianCodeExists(code) else {
                errorMessage = String(localized: "That guardian code was not found. Check it with your guardian.")
                return false
            }
        } catch {
            errorMessage = String(localized: "Could not reach the server to check the code.")
            return false
        }
        defaults.set(code, forKey: GuardianCode.key)
        guardianCode = code
        return true
    }

    public func clearGuardian() {
        defaults.removeObject(forKey: GuardianCode.key)
        guardianCode = nil
    }
}
