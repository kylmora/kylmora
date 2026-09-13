import Foundation

/// Injected into a web view to provide an interactive visual element picker / zapper.
///
/// Highlights elements under the pointer, lets the user click to lock an element,
/// adjust selection with parent/child traversal, preview removing it (live hide),
/// and generates an Adblock Plus cosmetic rule (`domain.com##selector`).
enum ElementPickerScript {
    static let script = #"""
    (function () {
      if (window.__kylmora_picker_active) return;
      window.__kylmora_picker_active = true;

      var hoveredEl = null;
      var selectedEl = null;
      var previewHidden = false;
      var originalDisplay = '';

      var host = document.createElement('div');
      host.id = 'kylmora-element-picker-root';
      host.style.cssText = 'all: initial !important; position: fixed !important; top: 0 !important; left: 0 !important; width: 0 !important; height: 0 !important; z-index: 2147483647 !important; pointer-events: none !important;';

      var shadow = host.attachShadow ? host.attachShadow({ mode: 'open' }) : host;

      var style = document.createElement('style');
      style.textContent = `
        .highlighter {
          position: fixed;
          pointer-events: none;
          background: rgba(255, 59, 48, 0.24);
          border: 2px dashed #ff3b30;
          border-radius: 4px;
          z-index: 2147483645;
          transition: all 0.08s ease-out;
          box-sizing: border-box;
          display: none;
        }
        .tag-badge {
          position: absolute;
          top: -26px;
          left: 0;
          background: #ff3b30;
          color: #ffffff;
          font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
          font-size: 11px;
          font-weight: 600;
          padding: 2px 7px;
          border-radius: 4px;
          white-space: nowrap;
          pointer-events: none;
          box-shadow: 0 2px 6px rgba(0,0,0,0.3);
        }
        .hud-bar {
          position: fixed;
          bottom: 24px;
          left: 50%;
          transform: translateX(-50%);
          background: rgba(28, 28, 30, 0.96);
          backdrop-filter: blur(24px);
          -webkit-backdrop-filter: blur(24px);
          border: 1px solid rgba(255, 255, 255, 0.2);
          box-shadow: 0 16px 40px rgba(0, 0, 0, 0.55);
          border-radius: 12px;
          padding: 12px 18px;
          color: #f5f5f7;
          font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
          z-index: 2147483646;
          pointer-events: auto;
          display: flex;
          flex-direction: column;
          gap: 10px;
          min-width: 480px;
          max-width: 90vw;
        }
        .hud-header {
          display: flex;
          align-items: center;
          justify-content: space-between;
          font-size: 13px;
          font-weight: 600;
        }
        .hud-title {
          display: flex;
          align-items: center;
          gap: 6px;
        }
        .hud-selector-row {
          display: flex;
          align-items: center;
          gap: 8px;
        }
        .hud-input {
          flex: 1;
          background: rgba(0, 0, 0, 0.5);
          border: 1px solid rgba(255, 255, 255, 0.25);
          border-radius: 6px;
          padding: 6px 10px;
          color: #30d158;
          font-family: ui-monospace, Menlo, Monaco, monospace;
          font-size: 12px;
          outline: none;
        }
        .hud-input:focus {
          border-color: #0a84ff;
        }
        .hud-buttons {
          display: flex;
          align-items: center;
          justify-content: flex-end;
          gap: 8px;
        }
        .hud-btn {
          background: rgba(255, 255, 255, 0.14);
          border: none;
          border-radius: 6px;
          color: #f5f5f7;
          font-size: 12px;
          font-weight: 500;
          padding: 6px 12px;
          cursor: pointer;
          transition: background 0.12s ease;
        }
        .hud-btn:hover {
          background: rgba(255, 255, 255, 0.22);
        }
        .hud-btn-primary {
          background: #ff3b30;
          color: white;
          font-weight: 600;
        }
        .hud-btn-primary:hover {
          background: #e02d23;
        }
        .hud-hint {
          font-size: 11px;
          color: rgba(255, 255, 255, 0.65);
        }
      `;
      shadow.appendChild(style);

      var highlighter = document.createElement('div');
      highlighter.className = 'highlighter';
      var badge = document.createElement('div');
      badge.className = 'tag-badge';
      highlighter.appendChild(badge);
      shadow.appendChild(highlighter);

      var hud = document.createElement('div');
      hud.className = 'hud-bar';
      hud.innerHTML = `
        <div class="hud-header">
          <div class="hud-title">
            <span>🎯 Element Picker</span>
            <span class="hud-hint">(Click element to target, Esc to exit)</span>
          </div>
          <button class="hud-btn" id="kylmora-close-btn">✕ Esc</button>
        </div>
        <div class="hud-selector-row">
          <input type="text" class="hud-input" id="kylmora-selector-input" placeholder="Hover or click an element..." />
          <button class="hud-btn" id="kylmora-parent-btn" title="Select parent element">◀ Parent</button>
          <button class="hud-btn" id="kylmora-child-btn" title="Select child element">Child ▶</button>
        </div>
        <div class="hud-buttons">
          <button class="hud-btn" id="kylmora-preview-btn">Preview Hide</button>
          <button class="hud-btn hud-btn-primary" id="kylmora-create-btn">Block Element</button>
          <button class="hud-btn" id="kylmora-cancel-btn">Cancel</button>
        </div>
      `;
      shadow.appendChild(hud);
      document.documentElement.appendChild(host);

      var selectorInput = shadow.getElementById('kylmora-selector-input');
      var parentBtn = shadow.getElementById('kylmora-parent-btn');
      var childBtn = shadow.getElementById('kylmora-child-btn');
      var previewBtn = shadow.getElementById('kylmora-preview-btn');
      var createBtn = shadow.getElementById('kylmora-create-btn');
      var cancelBtn = shadow.getElementById('kylmora-cancel-btn');
      var closeBtn = shadow.getElementById('kylmora-close-btn');

      function getSelector(el) {
        if (!el || el === document.body || el === document.documentElement) return '';
        if (el.id && /^[A-Za-z][A-Za-z0-9_-]*$/.test(el.id)) {
          if (document.querySelectorAll('#' + el.id).length === 1) {
            return '#' + el.id;
          }
        }
        var tag = el.tagName.toLowerCase();
        var classes = Array.from(el.classList).filter(function (c) {
          return /^[A-Za-z0-9_-]+$/.test(c) && !c.includes('hover') && !c.includes('focus');
        });
        if (classes.length > 0) {
          var classSelector = tag + '.' + classes.slice(0, 3).join('.');
          if (document.querySelectorAll(classSelector).length === 1) {
            return classSelector;
          }
        }
        var parent = el.parentElement;
        if (parent && parent !== document.body && parent.id) {
          var parentSel = '#' + parent.id + ' > ' + tag;
          if (classes.length > 0) parentSel += '.' + classes[0];
          return parentSel;
        }
        if (classes.length > 0) {
          return tag + '.' + classes[0];
        }
        return tag;
      }

      function updateHighlighter(el) {
        if (!el || el === host || host.contains(el)) {
          highlighter.style.display = 'none';
          return;
        }
        var rect = el.getBoundingClientRect();
        if (rect.width === 0 && rect.height === 0) {
          highlighter.style.display = 'none';
          return;
        }
        highlighter.style.display = 'block';
        highlighter.style.top = rect.top + 'px';
        highlighter.style.left = rect.left + 'px';
        highlighter.style.width = rect.width + 'px';
        highlighter.style.height = rect.height + 'px';
        var text = el.tagName.toLowerCase();
        if (el.id) text += '#' + el.id;
        else if (el.classList.length > 0) text += '.' + Array.from(el.classList).slice(0, 2).join('.');
        text += ' (' + Math.round(rect.width) + '×' + Math.round(rect.height) + ')';
        badge.textContent = text;
      }

      function onMouseMove(e) {
        if (selectedEl) return;
        var el = document.elementFromPoint(e.clientX, e.clientY);
        if (!el || el === host || host.contains(el)) return;
        hoveredEl = el;
        updateHighlighter(el);
        selectorInput.value = getSelector(el);
      }

      function onClick(e) {
        if (host.contains(e.target)) return;
        e.preventDefault();
        e.stopPropagation();
        var el = document.elementFromPoint(e.clientX, e.clientY);
        if (!el || el === host || host.contains(el)) return;
        selectedEl = el;
        updateHighlighter(el);
        selectorInput.value = getSelector(el);
        selectorInput.focus();
      }

      function cleanUp() {
        window.__kylmora_picker_active = false;
        if (previewHidden && (selectedEl || hoveredEl)) {
          var target = selectedEl || hoveredEl;
          if (target) target.style.display = originalDisplay;
        }
        window.removeEventListener('mousemove', onMouseMove, true);
        window.removeEventListener('click', onClick, true);
        window.removeEventListener('keydown', onKeyDown, true);
        if (host.parentNode) host.parentNode.removeChild(host);
      }

      function onKeyDown(e) {
        if (e.key === 'Escape') {
          cleanUp();
          post({ action: 'cancel' });
        } else if (e.key === 'Enter' && selectedEl) {
          confirmBlock();
        } else if (e.key === 'ArrowUp' && selectedEl && selectedEl.parentElement && selectedEl.parentElement !== document.body) {
          e.preventDefault();
          selectedEl = selectedEl.parentElement;
          updateHighlighter(selectedEl);
          selectorInput.value = getSelector(selectedEl);
        } else if (e.key === 'ArrowDown' && selectedEl && selectedEl.firstElementChild) {
          e.preventDefault();
          selectedEl = selectedEl.firstElementChild;
          updateHighlighter(selectedEl);
          selectorInput.value = getSelector(selectedEl);
        }
      }

      function post(msg) {
        try {
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.elementPicker) {
            window.webkit.messageHandlers.elementPicker.postMessage(msg);
          }
        } catch (err) {
          console.warn("Kylmora picker post error:", err);
        }
      }

      parentBtn.onclick = function () {
        var target = selectedEl || hoveredEl;
        if (target && target.parentElement && target.parentElement !== document.body && target.parentElement !== document.documentElement) {
          selectedEl = target.parentElement;
          updateHighlighter(selectedEl);
          selectorInput.value = getSelector(selectedEl);
        }
      };

      childBtn.onclick = function () {
        var target = selectedEl || hoveredEl;
        if (target && target.firstElementChild) {
          selectedEl = target.firstElementChild;
          updateHighlighter(selectedEl);
          selectorInput.value = getSelector(selectedEl);
        }
      };

      previewBtn.onclick = function () {
        var target = selectedEl || hoveredEl;
        if (!target) return;
        if (!previewHidden) {
          originalDisplay = target.style.display;
          target.style.display = 'none';
          highlighter.style.display = 'none';
          previewHidden = true;
          previewBtn.textContent = 'Restore Preview';
        } else {
          target.style.display = originalDisplay;
          previewHidden = false;
          updateHighlighter(target);
          previewBtn.textContent = 'Preview Hide';
        }
      };

      function confirmBlock() {
        var selector = selectorInput.value.trim();
        if (!selector) return;
        var domain = window.location.hostname;
        var rule = domain ? (domain + '##' + selector) : ('##' + selector);

        var styleEl = document.createElement('style');
        styleEl.setAttribute('data-kylmora-user-rule', rule);
        styleEl.textContent = selector + ' { display: none !important; }';
        document.head.appendChild(styleEl);

        cleanUp();
        post({ action: 'createRule', domain: domain, selector: selector, rule: rule });
      }

      createBtn.onclick = confirmBlock;
      cancelBtn.onclick = function () { cleanUp(); post({ action: 'cancel' }); };
      closeBtn.onclick = function () { cleanUp(); post({ action: 'cancel' }); };

      window.addEventListener('mousemove', onMouseMove, true);
      window.addEventListener('click', onClick, true);
      window.addEventListener('keydown', onKeyDown, true);
    })();
    """#
}
