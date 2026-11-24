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
        'a[href]', 'button', 'input:not([type=hidden])', 'select', 'textarea', 'summary', 'label[for]', 'iframe',
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

      const frameOffset = (el) => {
        let ox = 0, oy = 0;
        let win = el && el.ownerDocument ? el.ownerDocument.defaultView : null;
        while (win && win !== window) {
          try {
            const fe = win.frameElement;
            if (!fe) break;
            const r = fe.getBoundingClientRect();
            const cs = fe.ownerDocument.defaultView.getComputedStyle(fe);
            ox += r.left + (parseFloat(cs.borderLeftWidth) || 0) + (parseFloat(cs.paddingLeft) || 0);
            oy += r.top + (parseFloat(cs.borderTopWidth) || 0) + (parseFloat(cs.paddingTop) || 0);
            win = fe.ownerDocument.defaultView;
          } catch (_) { break; }
        }
        return { x: ox, y: oy };
      };

      const topRect = (el) => {
        const r = el.getBoundingClientRect();
        const off = frameOffset(el);
        return {
          left: r.left + off.x, top: r.top + off.y,
          right: r.right + off.x, bottom: r.bottom + off.y,
          width: r.width, height: r.height
        };
      };

      // Walk document + nested open shadow roots + accessible same-origin iframes.
      const walkRoots = (root, out = [], visited = new Set()) => {
        if (!root || visited.has(root)) return out;
        visited.add(root);
        out.push(root);
        const all = root.querySelectorAll ? root.querySelectorAll('*') : [];
        for (const el of all) {
          if (el.shadowRoot) walkRoots(el.shadowRoot, out, visited);
          if (el.tagName === 'IFRAME') {
            try {
              if (el.contentDocument) walkRoots(el.contentDocument, out, visited);
            } catch (_) {}
          }
        }
        return out;
      };
      const queryAllDeep = (selector, startRoot = document) => {
        const results = [];
        const seen = new Set();
        for (const r of walkRoots(startRoot)) {
          let matched = [];
          try { matched = r.querySelectorAll(selector); } catch (_) { continue; }
          for (const el of matched) {
            if (!seen.has(el)) { seen.add(el); results.push(el); }
          }
        }
        return results;
      };
      const deepElementFromPoint = (x, y) => {
        let curDoc = document;
        let cx = x, cy = y;
        let el = curDoc.elementFromPoint(cx, cy);
        for (let depth = 0; depth < 8 && el; depth++) {
          if (el.shadowRoot) {
            const inner = el.shadowRoot.elementFromPoint(cx, cy);
            if (!inner || inner === el) break;
            el = inner;
          } else if (el.tagName === 'IFRAME') {
            try {
              const idoc = el.contentDocument;
              if (!idoc) break;
              const r = el.getBoundingClientRect();
              cx -= r.left;
              cy -= r.top;
              const inner = idoc.elementFromPoint(cx, cy);
              if (!inner) break;
              el = inner;
            } catch (_) { break; }
          } else {
            break;
          }
        }
        return el;
      };
      const deepContains = (container, node) => {
        let cur = node;
        while (cur) {
          if (cur === container) return true;
          cur = cur.parentNode || cur.host || null;
        }
        return false;
      };

      const findBySelector = (rawSelector, expectedDoc) => {
        let sel = String(rawSelector || '').trim();
        if (!sel) return { error: 'invalid', message: 'Empty selector' };

        // Optional >> nth=N suffix
        let nth = null;
        const nthMatch = sel.match(/^(.*?)\\s*>>\\s*nth=(-?\\d+)\\s*$/);
        if (nthMatch) {
          sel = nthMatch[1].trim();
          nth = parseInt(nthMatch[2], 10);
        }

        // Snapshot @ref or ref=N
        if (/^@\\d+$/.test(sel) || /^ref=\\d+$/.test(sel)) {
          const refKey = sel.startsWith('@') ? sel : '@' + sel.slice(4);
          if (expectedDoc && expectedDoc !== doc) {
            return { error: 'stale', message: 'Stale ref ' + refKey + ': the page navigated; take a new snapshot' };
          }
          const el = refs.get(refKey);
          if (!el) return { error: 'unknown', message: 'Unknown ref ' + refKey + '; take a new snapshot' };
          if (!el.isConnected) {
            return { error: 'stale', message: 'Stale ref ' + refKey + ': the element left the page; take a new snapshot' };
          }
          return { elements: [el] };
        }

        let matches = [];
        if (sel.startsWith('text=')) {
          const rawText = sel.slice(5);
          const exact = (rawText.startsWith('"') && rawText.endsWith('"')) || (rawText.startsWith("'") && rawText.endsWith("'"));
          const needle = exact ? rawText.slice(1, -1) : clean(rawText).toLowerCase();
          const pool = queryAllDeep(interactive + ',' + context + ',p,span,div,li,td,th,label');
          matches = pool.filter(el => {
            if (!visible(el)) return false;
            const txt = clean(el.innerText || el.textContent || name(el));
            return exact ? txt === needle : txt.toLowerCase().includes(needle);
          });
          matches = matches.filter(el => !matches.some(other => other !== el && deepContains(el, other)));
        } else if (sel.startsWith('loc=role:')) {
          const spec = sel.slice(9).trim();
          const m = spec.match(/^([a-zA-Z0-9_-]+)(?:\\[name(\\*?)=(['"])(.*?)\\3\\])?$/);
          if (!m) return { error: 'invalid', message: 'Invalid role selector: ' + sel };
          const wantRole = m[1].toLowerCase();
          const isSub = m[2] === '*';
          const wantName = m[4];
          matches = queryAllDeep(interactive + ',' + context).filter(el => {
            if (!visible(el)) return false;
            if (role(el).toLowerCase() !== wantRole) return false;
            if (wantName !== undefined) {
              const n = name(el);
              return isSub ? n.toLowerCase().includes(wantName.toLowerCase()) : n === wantName;
            }
            return true;
          });
        } else if (sel.startsWith('loc=href:')) {
          const wantHref = sel.slice(9).trim();
          matches = queryAllDeep('a[href]').filter(el => visible(el) && (el.href === wantHref || (el.getAttribute('href') || '').includes(wantHref)));
        } else if (sel.startsWith('xpath=')) {
          const expr = sel.slice(6);
          try {
            const snap = document.evaluate(expr, document, null, XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null);
            for (let i = 0; i < snap.snapshotLength; i++) {
              const node = snap.snapshotItem(i);
              if (node && node.nodeType === 1) matches.push(node);
            }
          } catch (e) {
            return { error: 'invalid', message: 'Invalid XPath: ' + e.message };
          }
        } else {
          let css = sel.startsWith('loc=css:') ? sel.slice(8) : (sel.startsWith('css=') ? sel.slice(4) : sel);
          let hasText = null;
          let textIs = null;
          const ht = css.match(/^(.*?):has-text\\((['"])(.*?)\\2\\)$/);
          const ti = !ht && css.match(/^(.*?):text-is\\((['"])(.*?)\\2\\)$/);
          if (ht) { css = ht[1].trim() || '*'; hasText = clean(ht[3]).toLowerCase(); }
          else if (ti) { css = ti[1].trim() || '*'; textIs = clean(ti[3]); }
          try { document.querySelector(css); } catch (e) {
            return { error: 'invalid', message: 'Invalid CSS selector: ' + rawSelector };
          }
          matches = queryAllDeep(css);
          if (hasText !== null) {
            matches = matches.filter(el => clean(el.innerText || el.textContent || name(el)).toLowerCase().includes(hasText));
          } else if (textIs !== null) {
            matches = matches.filter(el => clean(el.innerText || el.textContent || name(el)) === textIs);
          }
        }

        if (nth !== null) {
          const idx = nth < 0 ? matches.length + nth : nth;
          matches = (idx >= 0 && idx < matches.length) ? [matches[idx]] : [];
        }
        if (matches.length === 0) {
          return { error: 'not_found', message: 'No element matched ' + rawSelector };
        }
        return { elements: matches };
      };

      const snapshot = (scope, rootRef) => {
        const full = scope === 'full_page' || scope === 'subtree';
        let startRoot = document;
        if (scope === 'subtree' && rootRef) {
          const found = findBySelector(rootRef, null);
          if (found.error) return found;
          const rootEl = found.elements[0];
          if (rootEl.tagName === 'IFRAME') {
            try {
              if (!rootEl.contentDocument) return { error: 'invalid', message: 'Iframe is cross-origin or empty' };
              startRoot = rootEl.contentDocument;
            } catch (_) {
              return { error: 'invalid', message: 'Iframe is cross-origin and cannot be inspected directly' };
            }
          } else {
            startRoot = rootEl;
          }
        }
        const seen = new Set();
        const out = [];
        let belowCount = 0;
        const consider = (el, isContext) => {
          if (seen.has(el)) return;
          seen.add(el);
          if (!visible(el)) return;
          const rect = topRect(el);
          if (!full && !inViewport(rect)) {
            if (rect.top >= innerHeight && !isContext) belowCount++;
            return;
          }
          if (out.length >= 500) return;
          const entry = {
            ref: isContext ? '' : refFor(el),
            role: el.tagName === 'IFRAME' ? 'iframe' : role(el),
            text: (el.tagName === 'IFRAME' ? clean(el.title || el.name || el.getAttribute('src') || 'frame') : name(el)).slice(0, 100),
            x: Math.round(rect.left + rect.width / 2),
            y: Math.round(rect.top + rect.height / 2),
            width: Math.round(rect.width),
            height: Math.round(rect.height),
            disabled: el.disabled === true || el.getAttribute('aria-disabled') === 'true',
            focused: (el.ownerDocument && el.ownerDocument.activeElement === el)
          };
          if (el.tagName === 'IFRAME') {
            try { if (!el.contentDocument) entry.crossOrigin = true; } catch (_) { entry.crossOrigin = true; }
          }
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
        const all = queryAllDeep(interactive + ',' + context, startRoot);
        for (const el of all) consider(el, el.matches(context) && !el.matches(interactive));
        if (out.length < 500) {
          for (const el of queryAllDeep('div,span,li,td,p,img,svg', startRoot)) {
            if (out.length >= 500) break;
            if (seen.has(el) || el.children.length > 2) continue;
            if (getComputedStyle(el).cursor === 'pointer' && !el.closest(interactive)) consider(el, false);
          }
        }
        out.sort((a, b) => (a.y - b.y) || (a.x - b.x));
        const belowPx = Math.max(0, document.documentElement.scrollHeight - (Math.round(scrollY) + innerHeight));
        return {
          doc, title: document.title, url: location.href,
          scope: scope || 'viewport',
          viewport: { width: innerWidth, height: innerHeight },
          scroll: { x: Math.round(scrollX), y: Math.round(scrollY), height: document.documentElement.scrollHeight, belowPx, belowCount },
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
      const target = (refOrSelector, expectedDoc) => {
        const found = findBySelector(refOrSelector, expectedDoc);
        if (found.error) return found;
        const visibleMatches = found.elements.filter(visible);
        if (visibleMatches.length > 1) {
          const sample = visibleMatches.slice(0, 3).map(e => describe(e) + ' "' + name(e).slice(0, 30) + '"').join(', ');
          return { error: 'ambiguous', count: visibleMatches.length, message: 'Selector "' + refOrSelector + '" matched ' + visibleMatches.length + ' visible elements (' + sample + '); refine selector or append >> nth=0' };
        }
        const el = visibleMatches.length === 1 ? visibleMatches[0] : found.elements[0];
        if (!visible(el)) return { error: 'hidden', message: refOrSelector + ' is not visible' };
        const rect = topRect(el);
        const cx = rect.left + rect.width / 2, cy = rect.top + rect.height / 2;
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
          const hit = deepElementFromPoint(x, y);
          if (hit && (hit === el || deepContains(el, hit) || (deepContains(hit, el) && hit.tagName === 'LABEL'))) {
            return { x: Math.round(x), y: Math.round(y), disabled, tag: el.tagName.toLowerCase(), role: role(el), text: name(el).slice(0, 60) };
          }
          blocker = blocker || hit;
        }
        return { error: 'covered', message: refOrSelector + ' is covered: ' + (blocker ? describe(blocker) : 'another element') + ' intercepts pointer events' };
      };

      const checkSelector = (selector, expectedDoc, state = 'visible') => {
        const found = findBySelector(selector, expectedDoc);
        if (found.error === 'invalid') return { error: 'invalid', message: found.message, matched: false };
        if (state === 'detached') {
          return { matched: Boolean(found.error) || found.elements.length === 0 };
        }
        if (state === 'hidden') {
          if (found.error) return { matched: true };
          return { matched: found.elements.every(el => !visible(el)) };
        }
        if (found.error) return { matched: false };
        if (state === 'attached') return { matched: found.elements.length > 0 };
        return { matched: found.elements.some(visible) };
      };

      const selectOption = (refOrSelector, expectedDoc, opt) => {
        const found = findBySelector(refOrSelector, expectedDoc);
        if (found.error) return found;
        const selects = found.elements.filter(e => e.tagName === 'SELECT');
        if (selects.length > 1) {
          return { error: 'ambiguous', message: 'Selector matched ' + selects.length + ' <select> elements; refine or append >> nth=0' };
        }
        const el = selects[0] || found.elements[0];
        if (!el || el.tagName !== 'SELECT') {
          return { error: 'invalid', message: refOrSelector + ' is not a <select> element' };
        }
        const options = [...el.options];
        if (opt && opt.clear === true) {
          for (const o of options) o.selected = false;
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          return { success: true, values: [], cleared: true };
        }
        if (opt && Array.isArray(opt.values)) {
          const wanted = opt.values.map(String);
          const matched = [];
          for (const o of options) {
            const hit = wanted.includes(o.value) || wanted.includes(clean(o.label || o.textContent));
            o.selected = hit;
            if (hit) matched.push(o.value);
          }
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          return { success: true, values: matched };
        }
        let chosen = null;
        if (opt && typeof opt.index === 'number') {
          chosen = options[opt.index] || null;
        } else if (opt && typeof opt.value === 'string') {
          chosen = options.find(o => o.value === opt.value)
            || options.find(o => clean(o.label || o.textContent) === clean(opt.value))
            || null;
        } else if (opt && typeof opt.label === 'string') {
          chosen = options.find(o => clean(o.label || o.textContent) === clean(opt.label)) || null;
        }
        if (!chosen) return { error: 'not_found', message: 'No matching option in ' + refOrSelector };
        el.value = chosen.value;
        chosen.selected = true;
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return { success: true, value: chosen.value, label: clean(chosen.label || chosen.textContent) };
      };

      const scrollIntoView = (refOrSelector, expectedDoc) => {
        const found = findBySelector(refOrSelector, expectedDoc);
        if (found.error) return found;
        const el = found.elements.find(visible) || found.elements[0];
        el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
        return { success: true };
      };

      const focusElement = (refOrSelector, expectedDoc) => {
        const found = findBySelector(refOrSelector, expectedDoc);
        if (found.error) return found;
        const visibleMatches = found.elements.filter(visible);
        if (visibleMatches.length > 1) {
          return { error: 'ambiguous', message: 'Selector matched ' + visibleMatches.length + ' visible elements; refine or append >> nth=0' };
        }
        let el = visibleMatches[0] || found.elements[0];
        if (!el.matches('input,textarea,select,button,a[href],[tabindex],[contenteditable=true],[contenteditable=""]')) {
          const inner = el.querySelectorAll('input:not([type=hidden]),textarea,[contenteditable=true],[contenteditable=""]');
          if (inner.length === 1) el = inner[0];
        }
        el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
        if (typeof el.focus === 'function') el.focus();
        return { success: true, tag: el.tagName.toLowerCase() };
      };

      globalThis.__kylmoraAgent = { snapshot, target, checkSelector, selectOption, scrollIntoView, focusElement, doc: () => doc, viewport: () => ({ width: innerWidth, height: innerHeight }) };
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
            if (el["crossOrigin"] as? Bool) == true { line += " [cross-origin]" }
            if (el["disabled"] as? Bool) == true { line += " [disabled]" }
            if let url = el["url"] as? String, !url.isEmpty { line += " → \(url)" }
            lines.append(line)
        }

        if (raw["scope"] as? String ?? "viewport") == "viewport",
           let scroll = raw["scroll"] as? [String: Any],
           let belowPx = scroll["belowPx"] as? Int, belowPx > 20 {
            let belowCount = (scroll["belowCount"] as? Int) ?? 0
            lines.append("")
            lines.append("[more content below the viewport: \(belowPx)px, ~\(belowCount) interactive elements — scroll or use scope=\"full_page\"]")
        }

        return lines.joined(separator: "\n")
    }
}
