import Foundation

public struct SOSContact: Sendable, Equatable, Codable {
    public var name: String
    public var code: String
    public var linked: Bool
    public var link: String?
    public var agreed: Bool
    public var phone: String?

    public init(
        name: String, code: String, linked: Bool = false,
        link: String? = nil, agreed: Bool = false, phone: String? = nil
    ) {
        self.phone = phone
        self.name = name
        self.code = code
        self.linked = linked
        self.link = link
        self.agreed = agreed
    }

    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        name = try box.decode(String.self, forKey: .name)
        code = try box.decode(String.self, forKey: .code)
        linked = try box.decodeIfPresent(Bool.self, forKey: .linked) ?? false
        link = try box.decodeIfPresent(String.self, forKey: .link)
        agreed = try box.decodeIfPresent(Bool.self, forKey: .agreed) ?? false
        phone = try box.decodeIfPresent(String.self, forKey: .phone)
    }
}

public struct SOSContactStore: Sendable, Equatable {
    public static let maxContacts = 5

    public private(set) var contacts: [SOSContact]

    public init(contacts: [SOSContact] = []) {
        self.contacts = Array(contacts.prefix(Self.maxContacts))
    }

    public var isFull: Bool { contacts.count >= Self.maxContacts }

    public var linkedCodes: [String] {
        contacts.filter(\.linked).map(\.code)
    }

    @discardableResult
    public mutating func add(
        name: String, code: String, link: String? = nil, phone: String? = nil
    ) -> Bool {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isFull, !clean.isEmpty, !code.isEmpty,
              !contacts.contains(where: { $0.code == code })
        else {
            return false
        }
        contacts.append(SOSContact(name: clean, code: code, link: link, phone: phone))
        return true
    }

    public func containsPhone(_ phone: String?) -> Bool {
        guard let key = PhoneNumber.key(phone) else { return false }
        return contacts.contains { PhoneNumber.key($0.phone) == key }
    }

    public mutating func remove(code: String) {
        contacts.removeAll { $0.code == code }
    }

    public mutating func setLinked(code: String, linked: Bool) {
        if let index = contacts.firstIndex(where: { $0.code == code }) {
            contacts[index].linked = linked
        }
    }

    public mutating func setAgreed(code: String, agreed: Bool) {
        if let index = contacts.firstIndex(where: { $0.code == code }) {
            contacts[index].agreed = agreed
        }
    }

    public var agreedCount: Int {
        contacts.filter(\.agreed).count
    }
}

public enum PhoneNumber {
    public static func key(_ phone: String?) -> String? {
        guard let phone else { return nil }
        let digits = phone.filter(\.isNumber)
        guard digits.count >= 7 else { return nil }
        return String(digits.suffix(10))
    }
}
