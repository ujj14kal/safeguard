import Foundation

/// The app follows the system language (English or Hindi). Contacts'
/// alerts go out in this language, and the check-in question is spoken
/// with a matching voice.
public enum AppLanguage {
    public static var isHindi: Bool {
        Bundle.main.preferredLocalizations.first == "hi"
    }

    /// "hi" or "en" for /incident/start.
    public static var alertLang: String {
        isHindi ? "hi" : "en"
    }

    /// Voice locale for spoken prompts, or nil for the system default
    /// (English keeps today's behaviour exactly).
    public static var speechVoiceLanguage: String? {
        isHindi ? "hi-IN" : nil
    }
}
