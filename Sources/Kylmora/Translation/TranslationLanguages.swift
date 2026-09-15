import Foundation

/// Defines supported translation languages, display names, and language code helpers.
public struct TranslationLanguage: Identifiable, Hashable, Sendable {
    public let code: String
    public let englishName: String
    public let nativeName: String

    public var id: String { code }

    public var displayTitle: String {
        if englishName == nativeName {
            return englishName
        }
        return "\(englishName) (\(nativeName))"
    }

    public init(code: String, englishName: String, nativeName: String) {
        self.code = code
        self.englishName = englishName
        self.nativeName = nativeName
    }
}

public enum TranslationLanguages {
    public static let all: [TranslationLanguage] = [
        TranslationLanguage(code: "en", englishName: "English", nativeName: "English"),
        TranslationLanguage(code: "es", englishName: "Spanish", nativeName: "Español"),
        TranslationLanguage(code: "fr", englishName: "French", nativeName: "Français"),
        TranslationLanguage(code: "de", englishName: "German", nativeName: "Deutsch"),
        TranslationLanguage(code: "it", englishName: "Italian", nativeName: "Italiano"),
        TranslationLanguage(code: "pt", englishName: "Portuguese", nativeName: "Português"),
        TranslationLanguage(code: "zh-Hans", englishName: "Chinese (Simplified)", nativeName: "简体中文"),
        TranslationLanguage(code: "zh-Hant", englishName: "Chinese (Traditional)", nativeName: "繁體中文"),
        TranslationLanguage(code: "ja", englishName: "Japanese", nativeName: "日本語"),
        TranslationLanguage(code: "ko", englishName: "Korean", nativeName: "한국어"),
        TranslationLanguage(code: "ru", englishName: "Russian", nativeName: "Русский"),
        TranslationLanguage(code: "ar", englishName: "Arabic", nativeName: "العربية"),
        TranslationLanguage(code: "hi", englishName: "Hindi", nativeName: "हिन्दी"),
        TranslationLanguage(code: "nl", englishName: "Dutch", nativeName: "Nederlands"),
        TranslationLanguage(code: "pl", englishName: "Polish", nativeName: "Polski"),
        TranslationLanguage(code: "tr", englishName: "Turkish", nativeName: "Türkçe"),
        TranslationLanguage(code: "uk", englishName: "Ukrainian", nativeName: "Українська"),
        TranslationLanguage(code: "vi", englishName: "Vietnamese", nativeName: "Tiếng Việt"),
        TranslationLanguage(code: "sv", englishName: "Swedish", nativeName: "Svenska")
    ]

    /// Resolves the user's preferred target language code (defaults to system language or English).
    public static var defaultTargetLanguageCode: String {
        let systemCode = Locale.current.language.languageCode?.identifier.lowercased() ?? "en"
        if all.contains(where: { $0.code.lowercased() == systemCode || $0.code.starts(with: systemCode) }) {
            return systemCode
        }
        return "en"
    }

    /// Finds language by ISO code (handles prefixes like 'fr-FR' -> 'fr').
    public static func language(for code: String) -> TranslationLanguage? {
        let clean = code.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = all.first(where: { $0.code.lowercased() == clean }) {
            return exact
        }
        let prefix = clean.components(separatedBy: "-").first ?? clean
        return all.first { $0.code.lowercased() == prefix }
    }

    /// User-friendly name for a language code.
    public static func displayName(for code: String) -> String {
        if let lang = language(for: code) {
            return lang.displayTitle
        }
        if let name = Locale.current.localizedString(forLanguageCode: code) {
            return name
        }
        return code.uppercased()
    }
}
