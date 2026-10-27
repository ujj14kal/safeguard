import Contacts
import Foundation

/// One person from this phone's address book (name + first number).
/// Read only to let the wearer pick trusted contacts; it stays on the
/// phone.
public struct PhoneContact: Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var phone: String?

    public init(id: String, name: String, phone: String?) {
        self.id = id
        self.name = name
        self.phone = phone
    }
}

/// Pure list helpers (search + order), pinned by tests.
public enum PhoneContactList {
    /// Contacts matching `query` in name or number, A to Z. Blank query
    /// returns everyone.
    public static func filter(_ contacts: [PhoneContact], query: String) -> [PhoneContact] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digits = text.filter(\.isNumber)
        let matches = contacts.filter { contact in
            if text.isEmpty { return true }
            if contact.name.lowercased().contains(text) { return true }
            if !digits.isEmpty, let key = contact.phone?.filter(\.isNumber), key.contains(digits) { return true }
            return false
        }
        return matches.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

/// Address-book access. Asked with a reason first (the view shows it),
/// never at launch.
enum PhoneContactsAccess {
    static func status() -> PermissionStatus {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: return .granted
        case .limited: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notAsked
        @unknown default: return .notAsked
        }
    }

    static func request() async -> Bool {
        do {
            return try await CNContactStore().requestAccess(for: .contacts)
        } catch {
            return false
        }
    }

    /// Every contact that has a name, off the main thread.
    static func fetch() async -> [PhoneContact] {
        await Task.detached(priority: .userInitiated) {
            let store = CNContactStore()
            let keys: [CNKeyDescriptor] = [
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor,
            ]
            let request = CNContactFetchRequest(keysToFetch: keys)
            var out: [PhoneContact] = []
            try? store.enumerateContacts(with: request) { contact, _ in
                let name = "\(contact.givenName) \(contact.familyName)"
                    .trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                out.append(PhoneContact(
                    id: contact.identifier, name: name,
                    phone: contact.phoneNumbers.first?.value.stringValue
                ))
            }
            return out
        }.value
    }
}
