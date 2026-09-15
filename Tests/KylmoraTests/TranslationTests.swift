import AppKit
import Foundation
import NaturalLanguage
import Testing
@testable import Kylmora

@Suite("On-Device Page Translation")
@MainActor
struct TranslationTests {

    @Test("TranslationLanguages correctly resolves codes and display names")
    func languageResolution() {
        let fr = TranslationLanguages.language(for: "fr")
        #expect(fr != nil)
        #expect(fr?.englishName == "French")
        #expect(fr?.nativeName == "Français")

        let esRegional = TranslationLanguages.language(for: "es-MX")
        #expect(esRegional != nil)
        #expect(esRegional?.englishName == "Spanish")

        let displayName = TranslationLanguages.displayName(for: "de")
        #expect(displayName.contains("German"))
        #expect(displayName.contains("Deutsch"))

        let fallbackName = TranslationLanguages.displayName(for: "xyz")
        #expect(!fallbackName.isEmpty)
    }

    @Test("NaturalLanguage recognizer detects languages on-device")
    func languageDetection() {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString("Bonjour à tous nos lecteurs francophones. Ceci est un test de langue.")
        #expect(recognizer.dominantLanguage?.rawValue == "fr")

        let recognizerSpanish = NLLanguageRecognizer()
        recognizerSpanish.processString("Hola a todos nuestros lectores en español. Bienvenidos a Kylmora.")
        #expect(recognizerSpanish.dominantLanguage?.rawValue == "es")
    }

    @Test("TranslationScript provides valid extraction and translation code")
    func scriptGeneration() {
        let bootstrap = TranslationScript.bootstrap
        #expect(bootstrap.contains("__kylmoraTranslation"))
        #expect(bootstrap.contains("extractDetectionSample"))
        #expect(bootstrap.contains("extractTranslatableNodes"))
        #expect(bootstrap.contains("applyTranslations"))
        #expect(bootstrap.contains("restoreOriginal"))

        let map: [String: String] = ["ktrans-1": "Hello", "ktrans-2": "World"]
        let call = TranslationScript.applyTranslationsCall(map: map)
        #expect(call.contains("__kylmoraTranslation.applyTranslations"))
        #expect(call.contains("Hello"))
        #expect(call.contains("World"))
    }

    @Test("Local translation engine processes snippets locally without networking")
    func engineTranslation() async throws {
        let engine = LocalPageTranslationEngine.shared
        let supported = await engine.isSupported(from: "fr", to: "en")
        #expect(supported)

        let frenchSnippets = ["Accueil", "Articles", "Lire la suite", "Commentaires"]
        let translated = try await engine.translate(texts: frenchSnippets, from: "fr", to: "en")

        #expect(translated.count == 4)
        #expect(translated[0] == "Home")
        #expect(translated[1] == "Articles")
        #expect(translated[2] == "Read more")
        #expect(translated[3] == "Comments")
    }

    @Test("PageTranslator tracks per-tab state transitions")
    func translatorStateTransitions() {
        let translator = PageTranslator.shared
        let tabID = UUID()

        let initial = translator.state(for: tabID)
        #expect(initial.status == .untranslated)
        #expect(!initial.isTranslated)

        var detected = initial
        detected.detectedLanguage = "fr"
        detected.status = .available(sourceLanguage: "fr", targetLanguage: "en")
        translator.setState(detected, for: tabID)

        #expect(translator.state(for: tabID).status == .available(sourceLanguage: "fr", targetLanguage: "en"))
        #expect(!translator.state(for: tabID).isTranslated)

        var translated = detected
        translated.status = .translated(sourceLanguage: "fr", targetLanguage: "en", nodeCount: 15)
        translator.setState(translated, for: tabID)

        #expect(translator.state(for: tabID).isTranslated)
        if case .translated(let src, let dst, let count) = translator.state(for: tabID).status {
            #expect(src == "fr")
            #expect(dst == "en")
            #expect(count == 15)
        } else {
            Issue.record("Expected status to be translated")
        }

        var restored = translated
        restored.status = .restored(sourceLanguage: "fr", targetLanguage: "en")
        translator.setState(restored, for: tabID)

        #expect(!translator.state(for: tabID).isTranslated)
    }
}
