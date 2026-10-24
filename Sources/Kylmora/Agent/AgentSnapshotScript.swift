import Foundation
import WebKit

/// The agent's in-page helper, and the snapshot it reads pages through.
///
/// Everything runs in its own `WKContentWorld`, the way ego lite reaches pages
/// through an isolated world: the DOM is shared, but the page's scripts can't see
/// the agent's globals, and the agent's can't be patched by the page.
///
/// Refs are stable for the life of a document. An element keeps the same `@n`
/// across snapshots, and a ref used after a navigation, or after its element left
/// the page, fails as stale instead of hitting whatever now sits at old coordinates.
@MainActor
public enum AgentSnapshotScript {
    static let world = WKContentWorld.world(name: "KylmoraAgent")

    /// Defines `globalThis.__kylmoraAgent` once per document in the agent's world.
    static let library = """
    if (!globalThis.__kylmoraAgent) {
      const refs = new Map();          // "@n" -> element
      const ids = new WeakMap();       // element -> "@n"
      let next = 1;
      const doc = Math.random().toString(36).slice(2, 10);

      const implicitRole = (el) => {
        const tag = el.tagName.toLowerCase();
        const type = (el.getAttribute('type') || '').toLowerCase();
        if (tag === 'a') return el.hasAttribute('href') ? 'link' : 'generic';
        if (tag === 'button' || tag === 'summary') return 'button';
        if (tag === 'select') return el.multiple ? 'listbox' : 'combobox';
        if (tag === 'textarea') return 'textbox';
        if (tag === 'input') {
          if (['button', 'submit', 'reset', 'image'].includes(type)) return 'button';
          if (type === 'checkbox') return 'checkbox';
          if (type === 'radio') return 'radio';
          if (type === 'range') return 'slider';
          if (type === 'search') return 'searchbox';
          if (type === 'file') return 'file';
          return 'textbox';
        }
        if (/^h[1-6]$/.test(tag)) return 'heading';
        if (tag === 'img') return 'img';
        if (el.isContentEditable) return 'textbox';
        return tag;
      };
      const role = (el) => el.getAttribute('role') || implicitRole(el);

      const clean = (s) => (s || '').replace(/\\s+/g, ' ').trim();
      const name = (el) => {
        const labelled = el.getAttribute('aria-labelledby');
        if (labelled) {
          const text = labelled.split(/\\s+/).map(id => document.getElementById(id)?.innerText || '').join(' ');
          if (clean(text)) return clean(text);
        }
        const direct = el.getAttribute('aria-label') || el.getAttribute('alt');
        if (clean(direct)) return clean(direct);
        if (el.labels && el.labels.length) return clean([...el.labels].map(l => l.innerText).join(' '));
        if (['INPUT', 'TEXTAREA', 'SELECT'].includes(el.tagName)) {
          return clean(el.getAttribute('placeholder') || el.getAttribute('title') || el.getAttribute('name') || '');
        }
        // What the user sees first; a tooltip only when there is no text.
        return clean(el.innerText || el.textContent) || clean(el.getAttribute('title'));
      };

      const visible = (el) => {
        const rect = el.getBoundingClientRect();
        if (rect.width < 2 || rect.height < 2) return false;
        const style = getComputedStyle(el);
        return style.visibility !== 'hidden' && style.display !== 'none' && Number(style.opacity) > 0.02;
      };
      const inViewport = (rect) => rect.bottom > 0 && rect.right > 0 && rect.top < innerHeight && rect.left < innerWidth;

      const interactive = [
        'a[href]', 'button', 'input:not([type=hidden])', 'select', 'textarea', 'summary', 'label[for]',
        '[role=button]', '[role=link]', '[role=checkbox]', '[role=radio]', '[role=tab]', '[role=menuitem]',
        '[role=switch]', '[role=combobox]', '[role=option]', '[role=textbox]', '[role=searchbox]',
        '[role=slider]', '[contenteditable=""]', '[contenteditable=true]', '[onclick]', '[tabindex]:not([tabindex="-1"])'
      ].join(',');
      const context = 'h1,h2,h3,h4,h5,h6,[role=heading],[role=dialog],[role=alert],dialog[open]';

      const refFor = (el) => {
        let ref = ids.get(el);
        if (!ref) { ref = '@' + (next++); ids.set(el, ref); }
        refs.set(ref, el);
        return ref;
      };

      const snapshot = (scope) => {
        const full = scope === 'full_page';
        const seen = new Set();
        const out = [];
        const consider = (el, isContext) => {
          if (seen.has(el) || out.length >= 500) return;
          seen.add(el);
          if (!visible(el)) return;
          const rect = el.getBoundingClientRect();
          if (!full && !inViewport(rect)) return;
          const entry = {
            ref: isContext ? '' : refFor(el),
            role: role(el),
            text: name(el).slice(0, 100),
            x: Math.round(rect.left + rect.width / 2),
            y: Math.round(rect.top + rect.height / 2),
            width: Math.round(rect.width),
            height: Math.round(rect.height),
            disabled: el.disabled === true || el.getAttribute('aria-disabled') === 'true',
            focused: document.activeElement === el
          };
          if (el.tagName === 'A' && el.href) entry.url = el.href;
          if (['INPUT', 'TEXTAREA', 'SELECT'].includes(el.tagName) && !['checkbox', 'radio'].includes(el.type)) {
            entry.value = el.type === 'password' ? (el.value ? '••••' : '') : String(el.value || '').slice(0, 80);
          }
          if (el.type === 'checkbox' || el.type === 'radio' || el.hasAttribute('aria-checked')) {
            entry.checked = el.checked === true || el.getAttribute('aria-checked') === 'true';
          }
          if (el.hasAttribute('aria-expanded')) entry.expanded = el.getAttribute('aria-expanded') === 'true';
          if (/^H[1-6]$/.test(el.tagName)) entry.level = Number(el.tagName[1]);
          out.push(entry);
        };
        const all = document.querySelectorAll(interactive + ',' + context);
        for (const el of all) consider(el, el.matches(context) && !el.matches(interactive));
        // Clickable leaves that only announce themselves with a pointer cursor.
        if (out.length < 500) {
          for (const el of document.querySelectorAll('div,span,li,td,p,img,svg')) {
            if (out.length >= 500) break;
            if (seen.has(el) || el.children.length > 2) continue;
            if (getComputedStyle(el).cursor === 'pointer' && !el.closest(interactive)) consider(el, false);
          }
        }
        out.sort((a, b) => (a.y - b.y) || (a.x - b.x));
        return {
          doc, title: document.title, url: location.href,
          viewport: { width: innerWidth, height: innerHeight },
          scroll: { x: Math.round(scrollX), y: Math.round(scrollY), height: document.documentElement.scrollHeight },
          elements: out
        };
      };

      const describe = (el) => {
        const id = el.id ? '#' + el.id : '';
        const cls = typeof el.className === 'string' && el.className ? '.' + el.className.split(/\\s+/)[0] : '';
        return '<' + el.tagName.toLowerCase() + id + cls + '>';
      };

      // Where a click on this element should land, after ego lite's checks:
      // in view, enabled, and not covered by another element.
      const target = (ref, expectedDoc) => {
        if (expectedDoc && expectedDoc !== doc) return { error: 'stale', message: 'Stale ref ' + ref + ': the page navigated; take a new snapshot' };
        const el = refs.get(ref);
        if (!el) return { error: 'unknown', message: 'Unknown ref ' + ref + '; take a new snapshot' };
        if (!el.isConnected) return { error: 'stale', message: 'Stale ref ' + ref + ': the element left the page; take a new snapshot' };
        if (!visible(el)) return { error: 'hidden', message: ref + ' is not visible' };
        const rect = el.getBoundingClientRect();
        const cx = rect.left + rect.width / 2, cy = rect.top + rect.height / 2;
        // Not in view: say how far to scroll so it lands mid-viewport.
        if (cy < 0 || cy > innerHeight || cx < 0 || cx > innerWidth) {
          return { scroll: { dx: Math.round(cx - innerWidth / 2), dy: Math.round(cy - innerHeight / 2) } };
        }
        const disabled = el.disabled === true || el.getAttribute('aria-disabled') === 'true';
        const left = Math.max(0, rect.left), right = Math.min(innerWidth, rect.right);
        const top = Math.max(0, rect.top), bottom = Math.min(innerHeight, rect.bottom);
        const candidates = [[0.5, 0.5], [0.3, 0.5], [0.7, 0.5], [0.5, 0.3], [0.5, 0.7], [0.2, 0.2], [0.8, 0.8]];
        let blocker = null;
        for (const [fx, fy] of candidates) {
          const x = left + (right - left) * fx, y = top + (bottom - top) * fy;
          const hit = document.elementFromPoint(x, y);
          if (hit && (hit === el || el.contains(hit) || hit.contains(el) && hit.tagName === 'LABEL')) {
            return { x: Math.round(x), y: Math.round(y), disabled, tag: el.tagName.toLowerCase(), role: role(el), text: name(el).slice(0, 60) };
          }
          blocker = blocker || hit;
        }
        return { error: 'covered', message: ref + ' is covered: ' + (blocker ? describe(blocker) : 'another element') + ' intercepts pointer events' };
      };

      globalThis.__kylmoraAgent = { snapshot, target, doc: () => doc, viewport: () => ({ width: innerWidth, height: innerHeight }) };
    }
    """

    /// Runs `body` (a function body that may use `agent`) in the agent's world.
    static func call(_ body: String, arguments: [String: Any] = [:], in webView: WKWebView) async throws -> Any? {
        let source = library + "\nconst agent = globalThis.__kylmoraAgent;\n" + body
        return try await webView.callAsyncJavaScript(source, arguments: arguments, in: nil, contentWorld: world)
    }

    /// Formats a snapshot as the compact list an agent reads.
    public static func formatSemanticSnapshot(raw: [String: Any]) -> String {
        let title = (raw["title"] as? String) ?? "Untitled"
        let url = (raw["url"] as? String) ?? ""
        let viewport = raw["viewport"] as? [String: Any]
        let width = (viewport?["width"] as? Int) ?? 0
        let height = (viewport?["height"] as? Int) ?? 0

        var lines: [String] = []
        lines.append("[Page: \"\(title)\"]")
        lines.append("[URL: \(url)]")
        lines.append("[Viewport: \(width)x\(height)]")
        if let scroll = raw["scroll"] as? [String: Any],
           let y = scroll["y"] as? Int, let total = scroll["height"] as? Int, total > height {
            lines.append("[Scrolled: \(y) of \(total - height)]")
        }
        lines.append("")

        guard let elements = raw["elements"] as? [[String: Any]], !elements.isEmpty else {
            lines.append("(No interactive elements visible in current viewport)")
            return lines.joined(separator: "\n")
        }

        for el in elements {
            let ref = (el["ref"] as? String) ?? ""
            let role = (el["role"] as? String) ?? "element"
            let text = (el["text"] as? String) ?? ""
            let x = (el["x"] as? Int) ?? 0
            let y = (el["y"] as? Int) ?? 0

            // Headings and dialogs carry no ref: they are context, not targets.
            var line = ref.isEmpty ? "  - \(role)" : "  - [\(ref)] \(role)"
            if let level = el["level"] as? Int { line += " h\(level)" }
            if !text.isEmpty { line += " \"\(text)\"" }
            if !ref.isEmpty { line += " (x: \(x), y: \(y))" }
            if let value = el["value"] as? String, !value.isEmpty { line += " value=\"\(value)\"" }
            if let checked = el["checked"] as? Bool { line += checked ? " [checked]" : " [unchecked]" }
            if let expanded = el["expanded"] as? Bool { line += expanded ? " [expanded]" : " [collapsed]" }
            if (el["focused"] as? Bool) == true { line += " [focused]" }
            if (el["disabled"] as? Bool) == true { line += " [disabled]" }
            if let url = el["url"] as? String, !url.isEmpty { line += " → \(url)" }
            lines.append(line)
        }

        return lines.joined(separator: "\n")
    }
}
