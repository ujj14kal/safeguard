import Foundation

public enum AppLanguage {
    public static var isHindi: Bool {
        Bundle.main.preferredLocalizations.first == "hi"
    }

    public static var alertLang: String {
        isHindi ? "hi" : "en"
    }

    public static var speechVoiceLanguage: String? {
        isHindi ? "hi-IN" : nil
    }
}
