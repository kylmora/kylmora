import AppKit
import Foundation
import NaturalLanguage
import WebKit

/// State of in-page translation for a tab or active page.
public struct PageTranslationState: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case untranslated
        case detecting
        case available(sourceLanguage: String, targetLanguage: String)
        case translating(sourceLanguage: String, targetLanguage: String)
        case translated(sourceLanguage: String, targetLanguage: String, nodeCount: Int)
        case restored(sourceLanguage: String, targetLanguage: String)
        case failed(error: String)
    }

    public var status: Status = .untranslated
    public var detectedLanguage: String?
    public var targetLanguage: String = TranslationLanguages.defaultTargetLanguageCode
    public var isTranslated: Bool {
        if case .translated = status { return true }
        return false
    }

    public init(status: Status = .untranslated, detectedLanguage: String? = nil, targetLanguage: String = TranslationLanguages.defaultTargetLanguageCode) {
        self.status = status
        self.detectedLanguage = detectedLanguage
        self.targetLanguage = targetLanguage
    }
}

/// Item extracted from the DOM for translation.
private struct TranslatableItem: Codable {
    let id: String
    let text: String
}

private struct DetectionPayload: Codable {
    let declaredLang: String
    let sampleText: String
}

/// Coordinates on-device translation of web pages in WKWebView.
@MainActor
public final class PageTranslator {
    public static let shared = PageTranslator()

    private var states: [UUID: PageTranslationState] = [:]
    public var onChange: ((UUID, PageTranslationState) -> Void)?

    public init() {}

    public func state(for tabID: UUID) -> PageTranslationState {
        states[tabID] ?? PageTranslationState()
    }

    public func setState(_ state: PageTranslationState, for tabID: UUID) {
        states[tabID] = state
        onChange?(tabID, state)
    }

    /// Automatically detects language of the page in `webView` for `tabID`.
    @discardableResult
    public func detectLanguage(in webView: WKWebView, for tabID: UUID) async -> String? {
        var current = state(for: tabID)
        current.status = .detecting
        setState(current, for: tabID)

        // Inject bootstrap script
        _ = try? await webView.evaluateJavaScript(TranslationScript.bootstrap)

        guard let jsonString = try? await webView.evaluateJavaScript("__kylmoraTranslation.extractDetectionSample();") as? String,
              let data = jsonString.data(using: .utf8),
              let payload = try? JSONDecoder().decode(DetectionPayload.self, from: data) else {
            current.status = .untranslated
            setState(current, for: tabID)
            return nil
        }

        var detectedCode: String?

        // 1. NaturalLanguage detection on real page text
        if !payload.sampleText.isEmpty {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(payload.sampleText)
            if let dominant = recognizer.dominantLanguage?.rawValue {
                detectedCode = dominant
            }
        }

        // 2. Fall back to declared html lang if recognizer was uncertain
        if detectedCode == nil || detectedCode == "und" {
            let declared = payload.declaredLang.components(separatedBy: "-").first?.lowercased() ?? ""
            if !declared.isEmpty {
                detectedCode = declared
            }
        }

        guard let detected = detectedCode, !detected.isEmpty, detected != "und" else {
            current.status = .untranslated
            setState(current, for: tabID)
            return nil
        }

        current.detectedLanguage = detected
        let target = current.targetLanguage

        let detectedPrefix = detected.components(separatedBy: "-").first?.lowercased() ?? detected.lowercased()
        let targetPrefix = target.components(separatedBy: "-").first?.lowercased() ?? target.lowercased()

        if detectedPrefix != targetPrefix {
            current.status = .available(sourceLanguage: detected, targetLanguage: target)
        } else {
            current.status = .untranslated
        }

        setState(current, for: tabID)
        return detected
    }

    /// Translates the page in `webView` to `targetLanguage`.
    @discardableResult
    public func translatePage(in webView: WKWebView, for tabID: UUID, targetLanguage: String? = nil) async throws -> Int {
        var current = state(for: tabID)
        let target = targetLanguage ?? current.targetLanguage
        current.targetLanguage = target
        let source = current.detectedLanguage ?? "auto"

        current.status = .translating(sourceLanguage: source, targetLanguage: target)
        setState(current, for: tabID)

        // Ensure bootstrap script is present
        _ = try? await webView.evaluateJavaScript(TranslationScript.bootstrap)

        // Extract text nodes
        guard let jsonNodes = try? await webView.evaluateJavaScript("__kylmoraTranslation.extractTranslatableNodes();") as? String,
              let data = jsonNodes.data(using: .utf8),
              let items = try? JSONDecoder().decode([TranslatableItem].self, from: data),
              !items.isEmpty else {
            current.status = .failed(error: "No translatable text found on this page")
            setState(current, for: tabID)
            return 0
        }

        // Batch translation
        let texts = items.map(\.text)
        let translatedTexts = try await LocalPageTranslationEngine.shared.translate(
            texts: texts,
            from: source,
            to: target
        )

        var resultMap: [String: String] = [:]
        for (index, item) in items.enumerated() {
            if index < translatedTexts.count {
                resultMap[item.id] = translatedTexts[index]
            }
        }

        // Apply translations back to DOM
        let applyCall = TranslationScript.applyTranslationsCall(map: resultMap)
        let appliedCount = (try? await webView.evaluateJavaScript(applyCall) as? Int) ?? 0

        current.status = .translated(sourceLanguage: source, targetLanguage: target, nodeCount: appliedCount)
        setState(current, for: tabID)
        return appliedCount
    }

    /// Restores the original page content instantaneously.
    @discardableResult
    public func restoreOriginal(in webView: WKWebView, for tabID: UUID) async -> Int {
        var current = state(for: tabID)
        let source = current.detectedLanguage ?? "auto"
        let target = current.targetLanguage

        let restoredCount = (try? await webView.evaluateJavaScript("__kylmoraTranslation.restoreOriginal();") as? Int) ?? 0
        current.status = .restored(sourceLanguage: source, targetLanguage: target)
        setState(current, for: tabID)
        return restoredCount
    }
}
