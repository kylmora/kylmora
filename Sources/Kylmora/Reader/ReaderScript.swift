import Foundation

/// Provides the Safari-grade article extraction, formatting, and interactive
/// Reader view JavaScript injected into web pages.
public enum ReaderScript {
    /// Generates the extraction and interactive reader toggle script.
    public static func toggleScript(force: Bool = true) -> String {
        return """
        (function() {
          // If reader is already active, restore the original page
          if (window.__kylmoraReaderActive && window.__kylmoraOriginalContent) {
            document.documentElement.innerHTML = window.__kylmoraOriginalContent;
            window.__kylmoraReaderActive = false;
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.kylmoraReader) {
              window.webkit.messageHandlers.kylmoraReader.postMessage({ action: 'stateChanged', active: false });
            }
            return;
          }

          var force = \(force ? "true" : "false");
          var textOf = function(el) { return (el.innerText || el.textContent || "").trim(); };

          // 1. Try to find the primary article container
          var selectors = [
            'article',
            '[itemprop="articleBody"]',
            '[itemprop="reviewBody"]',
            '.article-body',
            '.article__body',
            '.article-content',
            '.post-content',
            '.entry-content',
            '.story-body',
            '.story-content',
            'main',
            '[role="main"]',
            '#content',
            '.content'
          ];

          var candidate = null;
          for (var i = 0; i < selectors.length; i++) {
            var el = document.querySelector(selectors[i]);
            if (el && textOf(el).length > 300) {
              candidate = el;
              break;
            }
          }

          // 2. Fallback heuristic: score elements by paragraph density
          var paragraphs = Array.prototype.slice.call(document.querySelectorAll("p"));
          var scores = new Map();
          var totalParaText = 0;

          paragraphs.forEach(function(p) {
            var len = textOf(p).length;
            if (len < 30) return;
            totalParaText += len;
            var parent = p.parentElement;
            if (parent) {
              scores.set(parent, (scores.get(parent) || 0) + len);
            }
          });

          if (!candidate && scores.size > 0) {
            var bestScore = 0;
            scores.forEach(function(score, el) {
              if (score > bestScore) {
                candidate = el;
                bestScore = score;
              }
            });

            // Walk up while parent still contains main body
            if (candidate) {
              while (candidate.parentElement && candidate.parentElement !== document.body) {
                var pEl = candidate.parentElement;
                var pLen = 0;
                paragraphs.forEach(function(p) {
                  if (pEl.contains(p)) { pLen += textOf(p).length; }
                });
                if (pLen < totalParaText * 0.7) break;
                candidate = pEl;
              }
            }
          }

          if (!candidate) {
            candidate = document.body;
          }

          var candidateText = textOf(candidate);
          if (!force && candidateText.length < 500) {
            return;
          }

          // Save original content for clean restoration
          if (!window.__kylmoraOriginalContent) {
            window.__kylmoraOriginalContent = document.documentElement.innerHTML;
          }

          // Clone candidate node and strip extraneous elements
          var clone = candidate.cloneNode(true);
          var discardSelectors = [
            'script', 'style', 'nav', 'aside', 'footer', 'header', 'iframe',
            'form', 'button', 'input', 'select', 'textarea', 'noscript', 'svg',
            '[role="navigation"]', '[role="banner"]', '[role="complementary"]',
            '[aria-hidden="true"]', '.ad', '.ads', '.advertisement', '.social-share',
            '.share-buttons', '.comments', '#comments', '.disqus', '.newsletter'
          ];
          clone.querySelectorAll(discardSelectors.join(',')).forEach(function(n) { n.remove(); });

          // Retain clean content attributes
          clone.querySelectorAll('*').forEach(function(n) {
            Array.prototype.slice.call(n.attributes).forEach(function(a) {
              if (!/^(href|src|alt|title|colspan|rowspan|target)$/i.test(a.name)) {
                n.removeAttribute(a.name);
              }
            });
          });

          // Meta extraction
          var heading = document.querySelector('h1') || candidate.querySelector('h1');
          var title = (heading && textOf(heading)) || document.title || 'Untitled Article';
          var byline = document.querySelector('[rel="author"], .byline, .author, [itemprop="author"]');
          var bylineText = byline ? textOf(byline) : '';

          var esc = function(s) {
            return (s || '').replace(/[&<>]/g, function(c) {
              return { '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c];
            });
          };

          // Estimate reading time (approx 200 wpm)
          var wordCount = candidateText.split(/\\s+/).filter(Boolean).length;
          var readMinutes = Math.max(1, Math.ceil(wordCount / 200));

          // Full plain text for text-to-speech
          var fullText = title + '. ' + (bylineText ? 'By ' + bylineText + '. ' : '') + candidateText;

          var articleHTML = clone.innerHTML;

          var readerHTML = `
            <!DOCTYPE html>
            <html data-theme="light" data-font="serif">
            <head>
              <meta charset="utf-8">
              <meta name="viewport" content="width=device-width, initial-scale=1">
              <title>${esc(title)}</title>
              <style>
                :root {
                  --bg: #fdfbf7;
                  --text: #1a1a1a;
                  --text-muted: #737373;
                  --border: #e5e5e5;
                  --accent: #2563eb;
                  --code-bg: #f1f1ef;
                  --font-family: Charter, Georgia, Cambria, serif;
                  --font-size: 19px;
                  --line-height: 1.7;
                }
                html[data-theme="sepia"] {
                  --bg: #f6ecd9;
                  --text: #3c2c1d;
                  --text-muted: #7d6b5c;
                  --border: #dfd2be;
                  --accent: #b45309;
                  --code-bg: #ede2cd;
                }
                html[data-theme="dark"] {
                  --bg: #1c1c1e;
                  --text: #e5e5e7;
                  --text-muted: #8e8e93;
                  --border: #2c2c2e;
                  --accent: #60a5fa;
                  --code-bg: #2c2c2e;
                }
                html[data-theme="black"] {
                  --bg: #000000;
                  --text: #d4d4d8;
                  --text-muted: #71717a;
                  --border: #18181b;
                  --accent: #93c5fd;
                  --code-bg: #18181b;
                }
                html[data-font="sans"] {
                  --font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
                }
                html[data-font="mono"] {
                  --font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
                  --font-size: 17px;
                }

                * { box-sizing: border-box; }
                body {
                  margin: 0;
                  padding: 0;
                  background: var(--bg);
                  color: var(--text);
                  font-family: var(--font-family);
                  font-size: var(--font-size);
                  line-height: var(--line-height);
                  transition: background 0.2s ease, color 0.2s ease;
                  -webkit-font-smoothing: antialiased;
                }

                /* Floating Reader HUD */
                .kylmora-hud {
                  position: fixed;
                  top: 16px;
                  right: 20px;
                  display: flex;
                  align-items: center;
                  gap: 6px;
                  background: var(--bg);
                  border: 1px solid var(--border);
                  border-radius: 20px;
                  padding: 4px 10px;
                  box-shadow: 0 4px 12px rgba(0,0,0,0.08);
                  z-index: 10000;
                  backdrop-filter: blur(8px);
                  user-select: none;
                }
                .kylmora-btn {
                  background: none;
                  border: none;
                  cursor: pointer;
                  padding: 4px 8px;
                  border-radius: 12px;
                  font-size: 13px;
                  font-weight: 500;
                  color: var(--text-muted);
                  display: flex;
                  align-items: center;
                  gap: 4px;
                  transition: background 0.1s, color 0.1s;
                }
                .kylmora-btn:hover {
                  color: var(--text);
                  background: var(--code-bg);
                }
                .kylmora-btn.active {
                  color: var(--accent);
                  font-weight: 600;
                }

                .kylmora-article {
                  max-width: 700px;
                  margin: 0 auto;
                  padding: 64px 24px 120px;
                }

                h1 {
                  font-size: 2em;
                  line-height: 1.25;
                  margin: 0 0 16px;
                  letter-spacing: -0.02em;
                }
                h2 { font-size: 1.5em; margin: 36px 0 14px; line-height: 1.3; }
                h3 { font-size: 1.25em; margin: 28px 0 12px; line-height: 1.4; }

                .kylmora-meta {
                  display: flex;
                  flex-wrap: wrap;
                  align-items: center;
                  gap: 12px;
                  color: var(--text-muted);
                  font-size: 0.88em;
                  margin-bottom: 40px;
                  padding-bottom: 20px;
                  border-bottom: 1px solid var(--border);
                }

                p { margin: 0 0 24px; }
                a { color: var(--accent); text-decoration: underline; text-underline-offset: 3px; }
                img, video, figure { max-width: 100%; height: auto; border-radius: 6px; margin: 28px 0; }
                figcaption { font-size: 0.85em; color: var(--text-muted); text-align: center; margin-top: 6px; }
                blockquote {
                  margin: 28px 0;
                  padding: 8px 0 8px 20px;
                  border-left: 3px solid var(--accent);
                  color: var(--text-muted);
                  font-style: italic;
                }
                pre {
                  background: var(--code-bg);
                  padding: 16px;
                  border-radius: 8px;
                  overflow-x: auto;
                  font-family: ui-monospace, Menlo, monospace;
                  font-size: 0.88em;
                  line-height: 1.5;
                  margin: 24px 0;
                }
                code {
                  font-family: ui-monospace, Menlo, monospace;
                  background: var(--code-bg);
                  padding: 2px 5px;
                  border-radius: 4px;
                  font-size: 0.9em;
                }
                pre code { background: none; padding: 0; }
                ul, ol { margin: 0 0 24px; padding-left: 28px; }
                li { margin-bottom: 8px; }
                table {
                  width: 100%;
                  border-collapse: collapse;
                  margin: 28px 0;
                  font-size: 0.9em;
                }
                th, td {
                  border: 1px solid var(--border);
                  padding: 10px 14px;
                  text-align: left;
                }
                th { background: var(--code-bg); }
              </style>
            </head>
            <body>
              <aside class="kylmora-hud">
                <button class="kylmora-btn" id="btn-font-toggle" title="Toggle Font">Aa</button>
                <button class="kylmora-btn" id="btn-size-down" title="Smaller Font">A-</button>
                <button class="kylmora-btn" id="btn-size-up" title="Larger Font">A+</button>
                <button class="kylmora-btn" id="btn-theme-toggle" title="Theme">🎨</button>
                <button class="kylmora-btn" id="btn-listen" title="Read Aloud">🔊 Listen</button>
                <button class="kylmora-btn" id="btn-close" title="Exit Reader">✕</button>
              </aside>

              <main class="kylmora-article">
                <h1>${esc(title)}</h1>
                <div class="kylmora-meta">
                  ${bylineText ? `<span>By ${esc(bylineText)}</span>` : ''}
                  <span>📖 ${readMinutes} min read</span>
                </div>
                <div class="kylmora-body">${articleHTML}</div>
              </main>

              <script>
                (function() {
                  var html = document.documentElement;
                  var themes = ['light', 'sepia', 'dark', 'black'];
                  var currentThemeIdx = 0;
                  var fonts = ['serif', 'sans', 'mono'];
                  var currentFontIdx = 0;
                  var currentFontSize = 19;

                  document.getElementById('btn-theme-toggle').onclick = function() {
                    currentThemeIdx = (currentThemeIdx + 1) % themes.length;
                    html.setAttribute('data-theme', themes[currentThemeIdx]);
                  };

                  document.getElementById('btn-font-toggle').onclick = function() {
                    currentFontIdx = (currentFontIdx + 1) % fonts.length;
                    html.setAttribute('data-font', fonts[currentFontIdx]);
                  };

                  document.getElementById('btn-size-up').onclick = function() {
                    if (currentFontSize < 28) {
                      currentFontSize += 2;
                      document.body.style.setProperty('--font-size', currentFontSize + 'px');
                    }
                  };

                  document.getElementById('btn-size-down').onclick = function() {
                    if (currentFontSize > 14) {
                      currentFontSize -= 2;
                      document.body.style.setProperty('--font-size', currentFontSize + 'px');
                    }
                  };

                  var isSpeaking = false;
                  var listenBtn = document.getElementById('btn-listen');
                  listenBtn.onclick = function() {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.kylmoraReaderSpeech) {
                      if (!isSpeaking) {
                        isSpeaking = true;
                        listenBtn.textContent = '⏹ Stop';
                        listenBtn.classList.add('active');
                        window.webkit.messageHandlers.kylmoraReaderSpeech.postMessage({
                          action: 'speak',
                          text: ${JSON.stringify(fullText)},
                          title: ${JSON.stringify(title)}
                        });
                      } else {
                        isSpeaking = false;
                        listenBtn.textContent = '🔊 Listen';
                        listenBtn.classList.remove('active');
                        window.webkit.messageHandlers.kylmoraReaderSpeech.postMessage({ action: 'stop' });
                      }
                    }
                  };

                  document.getElementById('btn-close').onclick = function() {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.kylmoraReaderSpeech) {
                      window.webkit.messageHandlers.kylmoraReaderSpeech.postMessage({ action: 'stop' });
                    }
                    if (window.__kylmoraOriginalContent) {
                      document.documentElement.innerHTML = window.__kylmoraOriginalContent;
                      window.__kylmoraReaderActive = false;
                      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.kylmoraReader) {
                        window.webkit.messageHandlers.kylmoraReader.postMessage({ action: 'stateChanged', active: false });
                      }
                    }
                  };
                })();
              <\\/script>
            </body>
            </html>
          `;

          document.documentElement.innerHTML = readerHTML;
          window.__kylmoraReaderActive = true;

          // Notify Kylmora of active state and article payload for reading list caching
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.kylmoraReader) {
            window.webkit.messageHandlers.kylmoraReader.postMessage({
              action: 'stateChanged',
              active: true,
              title: title,
              byline: bylineText,
              readMinutes: readMinutes,
              plainText: fullText.slice(0, 5000),
              html: readerHTML
            });
          }
        })();
        """
    }
}
