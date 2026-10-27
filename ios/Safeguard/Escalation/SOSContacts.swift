import Foundation

/// One emergency contact: a name, a backend invite code, and whether they
/// pressed Start on the Telegram link. `link` is the invite URL returned
/// when the contact was added, for the share sheet. No phone numbers
/// anywhere — linking is by chat id, held server-side only.
public struct SOSContact: Sendable, Equatable, Codable {
    public var name: String
    public var code: String
    public var linked: Bool
    public var link: String?

    public init(name: String, code: String, linked: Bool = false, link: String? = nil) {
        self.name = name
        self.code = code
        self.linked = linked
        self.link = link
    }
}

/// Pure contact list (at most 5). The view model persists it and talks to
/// the backend; this type holds the rules the tests pin.
public struct SOSContactStore: Sendable, Equatable {
    public static let maxContacts = 5

    public private(set) var contacts: [SOSContact]

    public init(contacts: [SOSContact] = []) {
        self.contacts = Array(contacts.prefix(Self.maxContacts))
    }

    public var isFull: Bool { contacts.count >= Self.maxContacts }

    /// Codes of linked contacts, for /incident/start.
    public var linkedCodes: [String] {
        contacts.filter(\.linked).map(\.code)
    }

    /// Adds a contact from an invite response. False when full, blank, or
    /// a duplicate code.
    @discardableResult
    public mutating func add(name: String, code: String, link: String? = nil) -> Bool {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isFull, !clean.isEmpty, !code.isEmpty,
              !contacts.contains(where: { $0.code == code })
        else {
            return false
        }
        contacts.append(SOSContact(name: clean, code: code, link: link))
        return true
    }

    public mutating func remove(code: String) {
        contacts.removeAll { $0.code == code }
    }

    public mutating func setLinked(code: String, linked: Bool) {
        if let index = contacts.firstIndex(where: { $0.code == code }) {
            contacts[index].linked = linked
        }
    }
}
