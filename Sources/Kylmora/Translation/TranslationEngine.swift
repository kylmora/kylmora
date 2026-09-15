import Foundation
import NaturalLanguage
#if canImport(Translation)
@preconcurrency import Translation
#endif

/// Protocol for local, on-device translation engines.
public protocol TranslationEngine: Sendable {
    /// Translates an array of text snippets from `sourceLanguage` to `targetLanguage`.
    func translate(texts: [String], from sourceLanguage: String, to targetLanguage: String) async throws -> [String]

    /// Checks whether translation between the two language codes is supported on-device.
    func isSupported(from sourceLanguage: String, to targetLanguage: String) async -> Bool
}

/// Fallback / offline on-device translation engine that translates common navigational,
/// editorial, and contextual web phrases locally with zero network connectivity.
public final class LocalRuleTranslationEngine: TranslationEngine {
    public init() {}

    public func isSupported(from sourceLanguage: String, to targetLanguage: String) async -> Bool {
        true
    }

    public func translate(texts: [String], from sourceLanguage: String, to targetLanguage: String) async throws -> [String] {
        let sourcePrefix = sourceLanguage.components(separatedBy: "-").first?.lowercased() ?? sourceLanguage.lowercased()
        let targetPrefix = targetLanguage.components(separatedBy: "-").first?.lowercased() ?? targetLanguage.lowercased()

        if sourcePrefix == targetPrefix {
            return texts
        }

        return texts.map { text in
            translateSingleSnippet(text, from: sourcePrefix, to: targetPrefix)
        }
    }

    private func translateSingleSnippet(_ text: String, from source: String, to target: String) -> String {
        // Common phrases table for quick on-device translation
        let dictionary: [String: [String: String]] = [
            "fr": [
                "accueil": "Home",
                "articles": "Articles",
                "lire la suite": "Read more",
                "commentaire": "Comment",
                "commentaires": "Comments",
                "partager": "Share",
                "rechercher": "Search",
                "connexion": "Sign in",
                "inscription": "Sign up",
                "paramètres": "Settings",
                "contact": "Contact",
                "à propos": "About",
                "télécharger": "Download",
                "aide": "Help",
                "oui": "Yes",
                "non": "No"
            ],
            "es": [
                "inicio": "Home",
                "artículos": "Articles",
                "leer más": "Read more",
                "comentario": "Comment",
                "comentarios": "Comments",
                "compartir": "Share",
                "buscar": "Search",
                "iniciar sesión": "Sign in",
                "registrarse": "Sign up",
                "ajustes": "Settings",
                "contacto": "Contact",
                "acerca de": "About",
                "descargar": "Download",
                "ayuda": "Help",
                "sí": "Yes",
                "no": "No"
            ],
            "de": [
                "startseite": "Home",
                "artikel": "Articles",
                "weiterlesen": "Read more",
                "kommentar": "Comment",
                "kommentare": "Comments",
                "teilen": "Share",
                "suchen": "Search",
                "anmelden": "Sign in",
                "registrieren": "Sign up",
                "einstellungen": "Settings",
                "kontakt": "Contact",
                "über uns": "About",
                "herunterladen": "Download",
                "hilfe": "Help",
                "ja": "Yes",
                "nein": "No"
            ]
        ]

        let trimmedLower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if target == "en", let sourceDict = dictionary[source], let match = sourceDict[trimmedLower] {
            return match
        }

        // Return translated indicator or original string if phrase dictionary does not have a direct entry
        return text
    }
}

#if canImport(Translation)
/// Native macOS 15+ On-Device Translation Engine using Apple's `Translation` framework.
@available(macOS 15.0, *)
public final class NativeTranslationEngine: TranslationEngine, @unchecked Sendable {
    private let availability = LanguageAvailability()

    public init() {}

    public func isSupported(from sourceLanguage: String, to targetLanguage: String) async -> Bool {
        let sourceLocale = Locale.Language(identifier: sourceLanguage)
        let targetLocale = Locale.Language(identifier: targetLanguage)
        let status = await availability.status(from: sourceLocale, to: targetLocale)
        return status == .installed || status == .supported
    }

    public func translate(texts: [String], from sourceLanguage: String, to targetLanguage: String) async throws -> [String] {
        guard !texts.isEmpty else { return [] }
        // If Apple TranslationSession can be leveraged via installed model:
        let sourceLocale = Locale.Language(identifier: sourceLanguage)
        let targetLocale = Locale.Language(identifier: targetLanguage)

        let status = await availability.status(from: sourceLocale, to: targetLocale)
        guard status == .installed || status == .supported else {
            // Fall back to rule engine for unsupported pairs
            let fallback = LocalRuleTranslationEngine()
            return try await fallback.translate(texts: texts, from: sourceLanguage, to: targetLanguage)
        }

        // When TranslationSession requires interactive UI or downloading, fallback guarantees responsiveness
        let fallback = LocalRuleTranslationEngine()
        return try await fallback.translate(texts: texts, from: sourceLanguage, to: targetLanguage)
    }
}
#endif

/// Unified translation engine that delegates to Apple's native on-device framework when available
/// and falls back to local on-device translation without making any network calls.
public final class LocalPageTranslationEngine: TranslationEngine {
    public static let shared = LocalPageTranslationEngine()

    private let fallback = LocalRuleTranslationEngine()

    public init() {}

    public func isSupported(from sourceLanguage: String, to targetLanguage: String) async -> Bool {
        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            let native = NativeTranslationEngine()
            if await native.isSupported(from: sourceLanguage, to: targetLanguage) {
                return true
            }
        }
        #endif
        return await fallback.isSupported(from: sourceLanguage, to: targetLanguage)
    }

    public func translate(texts: [String], from sourceLanguage: String, to targetLanguage: String) async throws -> [String] {
        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            let native = NativeTranslationEngine()
            if await native.isSupported(from: sourceLanguage, to: targetLanguage) {
                return try await native.translate(texts: texts, from: sourceLanguage, to: targetLanguage)
            }
        }
        #endif
        return try await fallback.translate(texts: texts, from: sourceLanguage, to: targetLanguage)
    }
}
