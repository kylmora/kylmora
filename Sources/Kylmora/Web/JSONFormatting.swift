import Foundation
import WebKit

/// Pretty-prints JSON documents in the page.
///
/// WebKit shows an `application/json` response as one long line of text. A
/// user script, run at document end in the main frame only, checks the
/// document's content type, parses the text, and rewrites the page as an
/// indented, coloured tree. It is a script rather than a native view because
/// the document is already the page: the script only changes how it reads.
///
/// Controllers register here as web views are made, so the switch in
/// Settings reaches every open page on its next load.
@MainActor
final class JSONFormatting {
    static let shared = JSONFormatting()

    private let settings: Settings
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()

    init(settings: Settings = .shared) {
        self.settings = settings
    }

    func attach(_ controller: WKUserContentController) {
        controllers.add(controller)
        apply(to: controller)
    }

    func preferencesChanged() {
        for controller in controllers.allObjects { apply(to: controller) }
    }

    /// Other scripts on the controller -- Glance's link monitor -- are put
    /// back after the clear, so this switch cannot take them away.
    private func apply(to controller: WKUserContentController) {
        let others = controller.userScripts.filter { $0.source != Self.source }
        controller.removeAllUserScripts()
        for script in others { controller.addUserScript(script) }
        if settings.formatsJSON {
            controller.addUserScript(WKUserScript(source: Self.source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
    }

    static let source = """
    (function () {
      var type = (document.contentType || "").toLowerCase();
      if (!(type === "application/json" || type === "text/json" || /\\+json$/.test(type))) { return; }
      if (document.querySelector(".kylmora-json")) { return; }
      var raw = document.body ? document.body.textContent : "";
      var value;
      try { value = JSON.parse(raw); } catch (e) { return; }
      function esc(s) { return s.replace(/[&<>]/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]; }); }
      function render(v, depth) {
        var pad = "  ".repeat(depth), inner = "  ".repeat(depth + 1);
        if (v === null) { return '<span class="b">null</span>'; }
        if (typeof v === "boolean") { return '<span class="b">' + v + "</span>"; }
        if (typeof v === "number") { return '<span class="n">' + v + "</span>"; }
        if (typeof v === "string") { return '<span class="s">' + esc(JSON.stringify(v)) + "</span>"; }
        if (Array.isArray(v)) {
          if (v.length === 0) { return "[]"; }
          return "[\\n" + v.map(function (x) { return inner + render(x, depth + 1); }).join(",\\n") + "\\n" + pad + "]";
        }
        var keys = Object.keys(v);
        if (keys.length === 0) { return "{}"; }
        return "{\\n" + keys.map(function (k) {
          return inner + '<span class="k">' + esc(JSON.stringify(k)) + "</span>: " + render(v[k], depth + 1);
        }).join(",\\n") + "\\n" + pad + "}";
      }
      var html = render(value, 0);
      var title = document.title || location.pathname.split("/").pop() || "JSON";
      document.documentElement.innerHTML =
        '<head><meta charset="utf-8"><meta name="color-scheme" content="light dark"><title>' + esc(title) + "</title><style>" +
        "body{margin:0;background:#fff;color:#1d1d1f;font:12px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace}" +
        "pre{margin:0;padding:16px 20px;white-space:pre-wrap;word-break:break-word}" +
        ".k{color:#8a3b8f}.s{color:#1c5fa5}.n{color:#b3550e}.b{color:#6c6c70}" +
        "@media(prefers-color-scheme:dark){body{background:#1e1e1e;color:#e6e6e6}.k{color:#d7a3ff}.s{color:#8ec6ff}.n{color:#ffb27a}.b{color:#a0a0a5}}" +
        '</style></head><body><pre class="kylmora-json">' + html + "</pre></body>";
    })();
    """
}
