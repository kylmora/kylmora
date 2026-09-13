import AppKit
import Foundation
import WebKit

/// Coordinates per-site Boosts (custom CSS, JavaScript, and Universal Dark Mode)
/// inside WebKit web views.
@MainActor
final class BoostCoordinator {
    static let shared = BoostCoordinator()

    static let marker = "/* kylmora.boost */"
    static let styleElementID = "kylmora-boost-style"
    static let darkModeElementID = "kylmora-boost-dark-mode"

    private let store: BoostStore
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()

    init(store: BoostStore = .shared) {
        self.store = store
        store.onChange = { [weak self] in
            self?.boostsChanged()
        }
    }

    /// Smart universal dark mode stylesheet with media preservation.
    static let darkModeCSS = """
    html {
        filter: invert(90%) hue-rotate(180deg) !important;
        background-color: #141414 !important;
    }
    img, video, canvas, svg, picture, [style*="background-image"] {
        filter: invert(100%) hue-rotate(180deg) !important;
    }
    img img, video video {
        filter: none !important;
    }
    """

    func attach(_ controller: WKUserContentController) {
        guard !controllers.contains(controller) else { return }
        controllers.add(controller)
        updateScript(in: controller)
    }

    func updateScript(in controller: WKUserContentController) {
        let others = controller.userScripts.filter { !$0.source.hasPrefix(Self.marker) }
        controller.removeAllUserScripts()
        for script in others { controller.addUserScript(script) }

        controller.addUserScript(
            WKUserScript(
                source: Self.bootstrapSource(boosts: store.boosts),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
    }

    func apply(for url: URL?, to controller: WKUserContentController) {
        attach(controller)
    }

    func apply(to webView: WKWebView) {
        guard let host = webView.url?.host?.lowercased() else { return }
        if let boost = store.boost(for: host) {
            applyLive(boost: boost, to: webView)
        }
    }

    private func boostsChanged() {
        for controller in controllers.allObjects {
            updateScript(in: controller)
        }
    }

    /// Generates script source that applies matching boosts at document start.
    static func bootstrapSource(boosts: [Boost]) -> String {
        let activeBoosts = boosts.filter(\.isEnabled)
        guard !activeBoosts.isEmpty,
              let data = try? JSONEncoder().encode(activeBoosts),
              let json = String(data: data, encoding: .utf8)
        else {
            return "\(marker)\n"
        }

        return """
        \(marker)
        (function () {
            var boosts = \(json);
            var host = (window.location.hostname || "").toLowerCase().replace(/^www\\./, '');
            if (!host) return;

            var match = null;
            for (var i = 0; i < boosts.length; i++) {
                var b = boosts[i];
                var bHost = (b.host || "").toLowerCase().replace(/^www\\./, '');
                if (bHost === host || host.endsWith('.' + bHost) || bHost === '*') {
                    match = b;
                    break;
                }
            }
            if (!match) return;

            function applyStyles() {
                var head = document.head || document.documentElement;
                if (!head) return;

                // Dark mode
                if (match.isDarkModeEnabled) {
                    var darkEl = document.getElementById("\(darkModeElementID)");
                    if (!darkEl) {
                        darkEl = document.createElement('style');
                        darkEl.id = "\(darkModeElementID)";
                        darkEl.textContent = `\(darkModeCSS)`;
                        head.appendChild(darkEl);
                    }
                }

                // Custom CSS
                if (match.customCSS && match.customCSS.trim()) {
                    var cssEl = document.getElementById("\(styleElementID)");
                    if (!cssEl) {
                        cssEl = document.createElement('style');
                        cssEl.id = "\(styleElementID)";
                        cssEl.textContent = match.customCSS;
                        head.appendChild(cssEl);
                    }
                }
            }

            applyStyles();
            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', applyStyles);
            }

            // Custom JS
            if (match.customJS && match.customJS.trim()) {
                function runJS() {
                    try {
                        var fn = new Function(match.customJS);
                        fn();
                    } catch (err) {
                        console.warn("Kylmora Boost script error:", err);
                    }
                }
                if (document.readyState === 'loading') {
                    document.addEventListener('DOMContentLoaded', runJS);
                } else {
                    runJS();
                }
            }
        })();
        """
    }

    /// Applies or updates a boost immediately in a live web view.
    func applyLive(boost: Boost, to webView: WKWebView) {
        let cssLiteral = (try? JSONSerialization.data(withJSONObject: [boost.customCSS]))
            .flatMap { String(data: $0, encoding: .utf8) }
            .map { String($0.dropFirst().dropLast()) } ?? "\"\""

        let jsCode = """
        (function() {
            var head = document.head || document.documentElement;
            if (!head) return;

            // Dark mode
            var darkEl = document.getElementById("\(Self.darkModeElementID)");
            if (\(boost.isDarkModeEnabled && boost.isEnabled)) {
                if (!darkEl) {
                    darkEl = document.createElement('style');
                    darkEl.id = "\(Self.darkModeElementID)";
                    darkEl.textContent = `\(Self.darkModeCSS)`;
                    head.appendChild(darkEl);
                }
            } else if (darkEl) {
                darkEl.remove();
            }

            // Custom CSS
            var cssEl = document.getElementById("\(Self.styleElementID)");
            var newCSS = \(cssLiteral);
            if (\(boost.isEnabled) && newCSS.trim()) {
                if (!cssEl) {
                    cssEl = document.createElement('style');
                    cssEl.id = "\(Self.styleElementID)";
                    head.appendChild(cssEl);
                }
                cssEl.textContent = newCSS;
            } else if (cssEl) {
                cssEl.remove();
            }

            // Custom JS
            if (\(boost.isEnabled) && \(boost.customJS.isEmpty ? "false" : "true")) {
                try {
                    \(boost.customJS)
                } catch(e) {
                    console.warn("Kylmora Boost JS error:", e);
                }
            }
        })();
        """
        webView.evaluateJavaScript(jsCode) { _, _ in }
    }
}
