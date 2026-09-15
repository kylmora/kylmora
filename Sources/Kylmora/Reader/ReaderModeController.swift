import AppKit
import Foundation
import WebKit

/// Coordinates Reader Mode extraction, Speech synthesis, and Reading List caching.
@MainActor
public final class ReaderModeController: NSObject {
    public static let shared = ReaderModeController()

    public static let readerHandlerName = "kylmoraReader"
    public static let speechHandlerName = "kylmoraReaderSpeech"

    public var onStateChange: ((Bool) -> Void)?

    override public init() {
        super.init()
    }

    /// Attaches the reader script message handlers to the configuration.
    public func attach(_ controller: WKUserContentController) {
        controller.removeScriptMessageHandler(forName: Self.readerHandlerName, contentWorld: .defaultClient)
        controller.add(self, contentWorld: .defaultClient, name: Self.readerHandlerName)

        controller.removeScriptMessageHandler(forName: Self.speechHandlerName, contentWorld: .defaultClient)
        controller.add(self, contentWorld: .defaultClient, name: Self.speechHandlerName)
    }

    /// Toggles Reader Mode in the provided web view.
    public func toggleReader(in webView: WKWebView?, force: Bool = true) {
        guard let webView else { return }
        let js = ReaderScript.toggleScript(force: force)
        webView.evaluateJavaScript(js, in: nil, in: .defaultClient) { _ in }
    }

    /// Checks whether Reader Mode is currently active in the web view.
    public func checkActive(in webView: WKWebView?, completion: @escaping (Bool) -> Void) {
        guard let webView else {
            completion(false)
            return
        }
        webView.evaluateJavaScript("!!window.__kylmoraReaderActive") { res, _ in
            completion((res as? Bool) ?? false)
        }
    }

    /// Reads aloud the article or page content using offline TTS, or stops if already speaking.
    public func speakOrToggle(in webView: WKWebView?) {
        if ReaderSpeechService.shared.isSpeaking {
            ReaderSpeechService.shared.stop()
        } else {
            let js = """
            (function() {
                var article = document.querySelector('.kylmora-reader-body') || document.querySelector('article') || document.body;
                if (!article) return;
                var text = article.innerText || article.textContent || '';
                var title = document.title || '';
                window.webkit.messageHandlers.kylmoraReaderSpeech.postMessage({ action: 'speak', text: text, title: title });
            })();
            """
            webView?.evaluateJavaScript(js, in: nil, in: .defaultClient) { _ in }
        }
    }
}

extension ReaderModeController: WKScriptMessageHandler {
    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        if message.name == Self.speechHandlerName {
            guard let dict = message.body as? [String: Any],
                  let action = dict["action"] as? String else { return }

            switch action {
            case "speak":
                let text = dict["text"] as? String ?? ""
                let title = dict["title"] as? String
                ReaderSpeechService.shared.speak(text: text, title: title)
            case "stop":
                ReaderSpeechService.shared.stop()
            default:
                break
            }
            return
        }

        if message.name == Self.readerHandlerName {
            guard let dict = message.body as? [String: Any],
                  let action = dict["action"] as? String else { return }

            switch action {
            case "stateChanged":
                let active = dict["active"] as? Bool ?? false
                onStateChange?(active)

                if active, let webView = message.webView, let url = webView.url {
                    let title = dict["title"] as? String ?? webView.title ?? ""
                    let preview = dict["plainText"] as? String ?? ""
                    let html = dict["html"] as? String

                    // If article was already in Reading List, update its cached offline HTML
                    if ReadingListStore.shared.contains(url: url) {
                        ReadingListStore.shared.add(url: url, title: title, previewText: preview, offlineHTML: html)
                    }
                }

            default:
                break
            }
        }
    }
}
