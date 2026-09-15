import WebKit

/// Puts a space's default fonts into its pages.
///
/// Two routes to the same style sheet: a user script at document start, so
/// every page a space's web views load from now on begins with it, and a
/// direct edit of the pages already open, so a change in Settings shows at
/// once rather than on the next navigation. The sheet is the first author
/// style in the document, so anything the page says afterwards overrides it;
/// that is what makes these defaults rather than overrides.
@MainActor
enum WebFontStyling {
    /// Marks the script so it can be found and replaced among the others.
    private static let marker = "/* kylmora.fonts */"
    static let styleID = "kylmora-fonts"

    /// The script that installs the sheet, or nil when the fonts are WebKit's
    /// own and there is nothing to install.
    static func script(for fonts: WebFonts) -> WKUserScript? {
        guard let sheet = fonts.styleSheet else { return nil }
        return WKUserScript(source: source(for: sheet), injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    /// Replaces whatever font script the controller has with this one.
    ///
    /// `WKUserContentController` can only remove all scripts at once, so the
    /// others are read back and re-added around the change.
    static func install(_ fonts: WebFonts, in controller: WKUserContentController) {
        let others = controller.userScripts.filter { !$0.source.hasPrefix(marker) }
        controller.removeAllUserScripts()
        for script in others { controller.addUserScript(script) }
        if let script = script(for: fonts) { controller.addUserScript(script) }
    }

    /// Restyles a live page, and lines up the new sheet for its next load.
    static func apply(_ fonts: WebFonts, to webView: WKWebView) {
        install(fonts, in: webView.configuration.userContentController)
        webView.evaluateJavaScript(source(for: fonts.styleSheet ?? "")) { _, _ in }
    }

    /// Upserts a `<style>` as the first child of `<head>`, or removes it for
    /// an empty sheet. Runs at document start, when `<head>` may not exist
    /// yet, so it waits for it when it must.
    static func source(for sheet: String) -> String {
        let literal = (try? JSONSerialization.data(withJSONObject: [sheet]))
            .flatMap { String(data: $0, encoding: .utf8) }
            .map { String($0.dropFirst().dropLast()) } ?? "\"\""
        return """
        \(marker)
        (function () {
          var css = \(literal);
          function place() {
            var head = document.head || document.documentElement;
            if (!head) { return false; }
            var style = document.getElementById("\(styleID)");
            if (!css) { if (style) { style.remove(); } return true; }
            if (!style) {
              style = document.createElement("style");
              style.id = "\(styleID)";
              head.insertBefore(style, head.firstChild);
            }
            if (style.textContent !== css) { style.textContent = css; }
            return true;
          }
          if (!place()) {
            new MutationObserver(function (_, observer) { if (place()) { observer.disconnect(); } })
              .observe(document, { childList: true, subtree: true });
          }
        })();
        """
    }
}
