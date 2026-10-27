import Foundation

/// The signed-in person's profile, as the backend returns it. Email and
/// phone live on this phone only as a cached copy for the Settings screen.
public struct AccountProfile: Codable, Equatable, Sendable {
    public var id: String
    public var email: String
    public var name: String
    public var phone: String?
    public var language: String

    public init(id: String, email: String, name: String, phone: String? = nil, language: String = "en") {
        self.id = id
        self.email = email
        self.name = name
        self.phone = phone
        self.language = language
    }
}

public struct AccountSession: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    /// Refresh a little early so a call never races the expiry.
    public func isExpired(now: Date = Date(), margin: TimeInterval = 60) -> Bool {
        now.addingTimeInterval(margin) >= expiresAt
    }
}

/// What sign-up / sign-in produced. `session` is nil when the project
/// requires the email link to be opened first.
public struct AccountAuthResult: Equatable, Sendable {
    public var profile: AccountProfile
    public var session: AccountSession?
    public var needsConfirmation: Bool
}

/// A failure with text the person can read.
public struct AccountError: Error, Equatable, LocalizedError, Sendable {
    public var message: String
    public var status: Int?

    public init(_ message: String, status: Int? = nil) {
        self.message = message
        self.status = status
    }

    public var errorDescription: String? { message }
}

/// Client-side checks, mirroring the server so mistakes show before a
/// network call. The server stays the authority.
public enum AccountValidation {
    public static let minPasswordLength = 8
    public static let maxPasswordLength = 72

    public static func emailValid(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 320, !text.contains(" ") else { return false }
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[0].count <= 64 else { return false }
        let domain = parts[1]
        guard let dot = domain.lastIndex(of: "."), dot != domain.startIndex else { return false }
        return domain.distance(from: dot, to: domain.endIndex) > 2
    }

    /// Empty is fine (optional); otherwise 7-19 digits/spaces/dashes.
    public static func phoneValid(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return true }
        let body = text.hasPrefix("+") ? String(text.dropFirst()) : text
        guard (7...19).contains(body.count), let first = body.first, first.isNumber else { return false }
        return body.allSatisfy { $0.isNumber || $0 == " " || $0 == "-" }
    }

    public static func passwordProblem(_ password: String) -> String? {
        if password.count < minPasswordLength {
            return L10n.format("Use at least %d characters.", minPasswordLength)
        }
        if password.count > maxPasswordLength {
            return L10n.format("Use at most %d characters.", maxPasswordLength)
        }
        if password.lowercased() == password || !password.contains(where: \.isNumber) {
            return String(localized: "Mix upper and lower case letters and add a number.")
        }
        return nil
    }

    /// First thing wrong with a sign-up form, or nil when it can be sent.
    public static func signupProblem(
        name: String, email: String, password: String, phone: String, consent: Bool
    ) -> String? {
        if !SetupMachine.nameValid(name) { return String(localized: "Enter your name (1 to 40 characters).") }
        if !emailValid(email) { return String(localized: "Enter a valid email address.") }
        if let problem = passwordProblem(password) { return problem }
        if !phoneValid(phone) { return String(localized: "Enter a valid phone number, or leave it empty.") }
        if !consent { return String(localized: "Agree to the privacy notice to continue.") }
        return nil
    }

    public static func signinProblem(email: String, password: String) -> String? {
        if !emailValid(email) { return String(localized: "Enter a valid email address.") }
        if password.isEmpty { return String(localized: "Enter your password.") }
        return nil
    }
}
