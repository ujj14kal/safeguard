import Foundation

/// Texts the app shares on the wearer's behalf. The alert/end messages are
/// composed server-side (the backend owns the share links); this builder
/// covers what the app composes itself. Rule, pinned by tests: details the
/// wearer typed + fixed template words only — never transcripts,
/// appearance, or anything about other people.
public enum SOSMessageBuilder {
    /// The mock-cab banner. Every cab surface shows it: the app must never
    /// pretend the demo cab is real.
    public static let demoBanner = "DEMO — no real cab service is connected."

    /// "Share cab details" text for the contacts' Telegram thread.
    public static func cabShare(
        driver: String, plate: String, etaMinutes: Int, liveURL: String
    ) -> String {
        "DEMO cab (no real cab service is connected): \(driver), \(plate), "
            + "arriving in about \(etaMinutes) min. Family live page: \(liveURL)"
    }
}
