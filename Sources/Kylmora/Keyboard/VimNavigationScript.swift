import Foundation
import WebKit

/// Generates the injected JavaScript providing Vimium-style modal navigation bindings.
public enum VimNavigationScript {
    @MainActor
    public static var userScript: WKUserScript {
        WKUserScript(
            source: script,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
    }

    public static let script = """
    (function() {
      if (window.__kylmoraVimInstalled) return;
      window.__kylmoraVimInstalled = true;

      var lastGTime = 0;
      var lastYTime = 0;

      function isEditable(el) {
        if (!el) return false;
        var tag = el.tagName ? el.tagName.toUpperCase() : '';
        if (tag === 'INPUT') {
          var type = (el.type || '').toLowerCase();
          var nonText = ['button', 'checkbox', 'radio', 'submit', 'reset', 'file', 'image', 'range', 'color'];
          return nonText.indexOf(type) === -1;
        }
        if (tag === 'TEXTAREA' || tag === 'SELECT') return true;
        if (el.isContentEditable) return true;
        if (document.designMode && document.designMode.toLowerCase() === 'on') return true;
        return false;
      }

      function post(action, payload) {
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.kylmoraVimNav) {
          var msg = Object.assign({ action: action }, payload || {});
          window.webkit.messageHandlers.kylmoraVimNav.postMessage(msg);
        }
      }

      window.addEventListener('keydown', function(e) {
        // If typing inside an input or form field, let typing proceed untouched
        if (isEditable(e.target) || isEditable(document.activeElement)) {
          if (e.key === 'Escape') {
            if (document.activeElement && document.activeElement.blur) {
              document.activeElement.blur();
            }
          }
          return;
        }

        // Never intercept browser accelerator keys (Cmd, Option, Ctrl)
        if (e.metaKey || e.ctrlKey || e.altKey) {
          return;
        }

        var now = Date.now();
        var key = e.key;

        switch (key) {
          case 'j':
            e.preventDefault();
            window.scrollBy({ top: 60, behavior: 'smooth' });
            break;
          case 'k':
            e.preventDefault();
            window.scrollBy({ top: -60, behavior: 'smooth' });
            break;
          case 'h':
            e.preventDefault();
            window.scrollBy({ left: -60, behavior: 'smooth' });
            break;
          case 'l':
            e.preventDefault();
            window.scrollBy({ left: 60, behavior: 'smooth' });
            break;
          case 'd':
            e.preventDefault();
            window.scrollBy({ top: window.innerHeight * 0.45, behavior: 'smooth' });
            break;
          case 'u':
            e.preventDefault();
            window.scrollBy({ top: -window.innerHeight * 0.45, behavior: 'smooth' });
            break;
          case 'g':
            e.preventDefault();
            if (now - lastGTime < 450) {
              window.scrollTo({ top: 0, behavior: 'smooth' });
              lastGTime = 0;
            } else {
              lastGTime = now;
            }
            break;
          case 'G':
            e.preventDefault();
            var maxScroll = Math.max(
              document.body ? document.body.scrollHeight : 0,
              document.documentElement ? document.documentElement.scrollHeight : 0
            );
            window.scrollTo({ top: maxScroll, behavior: 'smooth' });
            break;
          case 'r':
            e.preventDefault();
            window.location.reload();
            break;
          case 'H':
            e.preventDefault();
            post('back');
            break;
          case 'L':
            e.preventDefault();
            post('forward');
            break;
          case 'x':
            e.preventDefault();
            post('closeTab');
            break;
          case 'X':
            e.preventDefault();
            post('reopenTab');
            break;
          case 'J':
            e.preventDefault();
            post('nextTab');
            break;
          case 'K':
            e.preventDefault();
            post('prevTab');
            break;
          case 'y':
            e.preventDefault();
            if (now - lastYTime < 450) {
              post('copyUrl');
              lastYTime = 0;
            } else {
              lastYTime = now;
            }
            break;
          case 'f':
            e.preventDefault();
            post('linkHints', { newTab: false });
            break;
          case 'F':
            e.preventDefault();
            post('linkHints', { newTab: true });
            break;
          case '/':
            e.preventDefault();
            post('find');
            break;
          case 'i':
            e.preventDefault();
            var input = document.querySelector('input:not([type="hidden"]), textarea, [contenteditable="true"]');
            if (input && input.focus) {
              input.focus();
            }
            break;
          default:
            break;
        }
      }, true);
    })();
    """
}
