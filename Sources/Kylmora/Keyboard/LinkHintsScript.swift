import Foundation

/// Generates the injected JavaScript to display interactive link hints overlay
/// in the active web view, match typed key sequences, and activate elements.
public enum LinkHintsScript {
    /// Default keyboard characters used for link hint combinations (home row prioritized).
    public static let defaultHintCharacters = "sadfjklewcmpgh"

    /// Generates prefix-free hint character sequences for `count` targets.
    public static func generateHints(count: Int, characters: String = defaultHintCharacters) -> [String] {
        guard count > 0 else { return [] }
        let chars = Array(characters.lowercased())
        guard !chars.isEmpty else { return [] }

        if count <= chars.count {
            return (0..<count).map { String(chars[$0]) }
        }

        // Two-character combinations: chars[i] + chars[j]
        var result: [String] = []
        result.reserveCapacity(count)
        for c1 in chars {
            for c2 in chars {
                result.append("\(c1)\(c2)")
                if result.count == count {
                    return result
                }
            }
        }
        return result
    }

    /// Builds the JavaScript string to inject into the web view.
    public static func script(openInNewTab: Bool = false, characters: String = defaultHintCharacters) -> String {
        let cleanChars = characters.filter { $0.isLetter }.lowercased()
        let charsArray = cleanChars.isEmpty ? defaultHintCharacters : cleanChars

        return """
        (function() {
          var existing = document.getElementById('kylmora-link-hints-root');
          if (existing) {
            existing.remove();
            if (window.__kylmoraHintsCleanup) { window.__kylmoraHintsCleanup(); }
            return;
          }

          var openInNewTab = \(openInNewTab ? "true" : "false");
          var HINT_CHARS = "\(charsArray)".split("");

          var selectors = [
            'a[href]',
            'button',
            'input:not([type="hidden"])',
            'select',
            'textarea',
            'summary',
            '[role="button"]',
            '[role="link"]',
            '[role="checkbox"]',
            '[role="radio"]',
            '[role="tab"]',
            '[role="menuitem"]',
            '[role="switch"]',
            '[role="combobox"]',
            '[role="option"]',
            '[contenteditable="true"]',
            '[onclick]'
          ];

          var candidateElements = Array.from(document.querySelectorAll(selectors.join(',')));

          var allElements = document.querySelectorAll('p, span, div, li, td, th');
          for (var i = 0; i < allElements.length && candidateElements.length < 300; i++) {
            var el = allElements[i];
            if (candidateElements.indexOf(el) !== -1) continue;
            try {
              var style = window.getComputedStyle(el);
              if (style && style.cursor === 'pointer' && el.children.length === 0) {
                candidateElements.push(el);
              }
            } catch (e) {}
          }

          var vw = window.innerWidth || document.documentElement.clientWidth;
          var vh = window.innerHeight || document.documentElement.clientHeight;

          var visibleTargets = [];
          for (var i = 0; i < candidateElements.length; i++) {
            var el = candidateElements[i];
            var rect = el.getBoundingClientRect();
            if (rect.width < 4 || rect.height < 4) continue;
            if (rect.bottom < 0 || rect.right < 0 || rect.top > vh || rect.left > vw) continue;
            var style = window.getComputedStyle(el);
            if (!style || style.visibility === 'hidden' || style.display === 'none' || style.opacity === '0') continue;
            visibleTargets.push({ element: el, rect: rect });
            if (visibleTargets.length >= 200) break;
          }

          if (visibleTargets.length === 0) {
            return;
          }

          var hints = [];
          var N = visibleTargets.length;
          if (N <= HINT_CHARS.length) {
            for (var i = 0; i < N; i++) {
              hints.push(HINT_CHARS[i]);
            }
          } else {
            var count = 0;
            outer: for (var i = 0; i < HINT_CHARS.length; i++) {
              for (var j = 0; j < HINT_CHARS.length; j++) {
                hints.push(HINT_CHARS[i] + HINT_CHARS[j]);
                count++;
                if (count >= N) break outer;
              }
            }
          }

          var root = document.createElement('div');
          root.id = 'kylmora-link-hints-root';
          root.style.cssText = 'position:fixed;top:0;left:0;width:100%;height:100%;pointer-events:none;z-index:2147483647;';

          var hintEntries = [];

          for (var i = 0; i < visibleTargets.length; i++) {
            var item = visibleTargets[i];
            var hintText = hints[i];
            var badge = document.createElement('div');
            badge.className = 'kylmora-hint-badge';
            badge.dataset.hint = hintText;
            badge.textContent = hintText.toUpperCase();

            var left = Math.max(2, Math.min(vw - 28, item.rect.left));
            var top = Math.max(2, Math.min(vh - 20, item.rect.top));

            var bg = openInNewTab ? '#fed7aa' : '#fef08a';
            var border = openInNewTab ? '#ea580c' : '#ca8a04';

            badge.style.cssText = 'position:fixed;' +
              'left:' + left + 'px;' +
              'top:' + top + 'px;' +
              'background:' + bg + ';' +
              'color:#0f172a;' +
              'border:1px solid ' + border + ';' +
              'border-radius:3px;' +
              'font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,monospace;' +
              'font-size:11px;' +
              'font-weight:700;' +
              'line-height:14px;' +
              'padding:1px 4px;' +
              'box-shadow:0 2px 5px rgba(0,0,0,0.35);' +
              'z-index:2147483647;' +
              'pointer-events:none;' +
              'user-select:none;' +
              'text-transform:uppercase;' +
              'letter-spacing:0.5px;';

            root.appendChild(badge);
            hintEntries.push({
              hint: hintText,
              element: item.element,
              badge: badge
            });
          }

          document.documentElement.appendChild(root);

          var typed = "";

          function cleanup() {
            window.removeEventListener('keydown', onKeyDown, true);
            window.removeEventListener('scroll', onScrollOrResize, true);
            window.removeEventListener('resize', onScrollOrResize, true);
            if (root.parentNode) {
              root.parentNode.removeChild(root);
            }
            delete window.__kylmoraHintsCleanup;
          }

          window.__kylmoraHintsCleanup = cleanup;

          function onScrollOrResize() {
            cleanup();
          }

          function activateTarget(entry) {
            cleanup();
            var el = entry.element;
            if (openInNewTab) {
              var href = el.href || el.getAttribute('href');
              if (!href && el.closest('a')) {
                href = el.closest('a').href;
              }
              if (href) {
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.kylmoraLinkHints) {
                  window.webkit.messageHandlers.kylmoraLinkHints.postMessage({ action: 'openNewTab', url: href });
                  return;
                }
              }
              var evt = new MouseEvent('click', { bubbles: true, cancelable: true, view: window, metaKey: true });
              el.dispatchEvent(evt);
            } else {
              el.focus();
              el.click();
              if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.kylmoraLinkHints) {
                window.webkit.messageHandlers.kylmoraLinkHints.postMessage({ action: 'clicked' });
              }
            }
          }

          function updateDisplay() {
            var exactMatch = null;
            var matchingCount = 0;

            for (var i = 0; i < hintEntries.length; i++) {
              var entry = hintEntries[i];
              if (entry.hint.indexOf(typed) === 0) {
                entry.badge.style.display = 'block';
                matchingCount++;
                if (entry.hint === typed) {
                  exactMatch = entry;
                }
                var matched = entry.hint.slice(0, typed.length).toUpperCase();
                var remainder = entry.hint.slice(typed.length).toUpperCase();
                entry.badge.innerHTML = '<span style="color:#2563eb;text-decoration:underline;">' + matched + '</span>' + remainder;
              } else {
                entry.badge.style.display = 'none';
              }
            }

            if (exactMatch && matchingCount === 1) {
              activateTarget(exactMatch);
            } else if (matchingCount === 0) {
              cleanup();
            }
          }

          function onKeyDown(e) {
            if (e.key === 'Escape') {
              e.preventDefault();
              e.stopPropagation();
              cleanup();
              return;
            }
            if (e.key === 'Backspace') {
              e.preventDefault();
              e.stopPropagation();
              if (typed.length > 0) {
                typed = typed.slice(0, -1);
                updateDisplay();
              } else {
                cleanup();
              }
              return;
            }
            if (e.ctrlKey || e.metaKey || e.altKey) {
              cleanup();
              return;
            }

            var key = e.key.toLowerCase();
            if (key.length === 1 && HINT_CHARS.indexOf(key) !== -1) {
              e.preventDefault();
              e.stopPropagation();
              typed += key;
              updateDisplay();
            } else {
              cleanup();
            }
          }

          window.addEventListener('keydown', onKeyDown, true);
          window.addEventListener('scroll', onScrollOrResize, true);
          window.addEventListener('resize', onScrollOrResize, true);
        })();
        """
    }
}
