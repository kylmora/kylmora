import AppKit
import Foundation
import NaturalLanguage
import Testing
import WebKit
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

    @Test("Pages are translated in batches that cover every node once, in order")
    func batching() {
        #expect(TranslationBatch.ranges(count: 0).isEmpty)
        #expect(TranslationBatch.ranges(count: 5, size: 10) == [0..<5])
        #expect(TranslationBatch.ranges(count: 25, size: 10) == [0..<10, 10..<20, 20..<25])
        let ranges = TranslationBatch.ranges(count: 1000)
        #expect(ranges.first?.lowerBound == 0)
        #expect(ranges.last?.upperBound == 1000)
        #expect(ranges.reduce(0) { $0 + $1.count } == 1000)
        #expect(ranges.allSatisfy { $0.count <= TranslationBatch.size })
    }

    @Test("The language codes the popover offers are ones Apple's framework can name")
    func languageCodesMapToLocaleLanguages() {
        for language in TranslationLanguages.all {
            let locale = TranslationBatch.language(for: language.code)
            #expect(locale.languageCode != nil, "\(language.code) has no language code")
        }
        #expect(TranslationBatch.language(for: "zh-Hans").script?.identifier == "Hans")
    }

    @Test("Availability answers without a window and never pretends to translate")
    func availabilityIsHonest() async {
        let status = await NativeTranslation.availability(from: "fr", to: "en")
        if #available(macOS 15.0, *) {
            #expect(status != .needsNewerMacOS)
        } else {
            #expect(status == .needsNewerMacOS)
        }
        // A pair no model handles is reported as such, not "translated".
        let bogus = await NativeTranslation.availability(from: "xx", to: "en")
        #expect(bogus == .unsupported || bogus == .needsNewerMacOS)
    }

    @Test("Translating a page that is not on screen fails with a reason, not a fake result")
    func translatingOffscreenPageFails() async {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let translator = PageTranslator.shared
        let tabID = UUID()
        var state = translator.state(for: tabID)
        state.detectedLanguage = "fr"
        translator.setState(state, for: tabID)

        await #expect(throws: TranslationFailure.noWindow) {
            try await translator.translatePage(in: webView, for: tabID, targetLanguage: "en")
        }
        if case .failed(let message) = translator.state(for: tabID).status {
            #expect(message == TranslationFailure.noWindow.localizedDescription)
        } else {
            Issue.record("Expected a failed state with the reason")
        }
    }

    @Test("Every failure has a sentence the popover can show")
    func failureMessages() {
        let cases: [TranslationFailure] = [
            .needsNewerMacOS, .unsupportedPair(source: "fr", target: "en"),
            .unsupportedPair(source: nil, target: "de"), .noWindow, .nothingToTranslate
        ]
        for failure in cases {
            #expect(!(failure.errorDescription ?? "").isEmpty)
        }
        #expect(TranslationFailure.unsupportedPair(source: "fr", target: "en").localizedDescription.contains("French"))
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
