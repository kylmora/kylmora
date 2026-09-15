import Foundation

/// Injected JavaScript routines that inspect, extract, translate, and restore DOM text nodes in a WKWebView.
public enum TranslationScript {
    /// Injected script that defines the `__kylmoraTranslation` namespace on `window`.
    public static let bootstrap: String = """
    (function() {
        if (window.__kylmoraTranslation) return;

        const EXCLUDED_TAGS = new Set([
            'SCRIPT', 'STYLE', 'NOSCRIPT', 'CODE', 'PRE', 'TEXTAREA', 'INPUT',
            'SELECT', 'SVG', 'CANVAS', 'AUDIO', 'VIDEO', 'OBJECT', 'EMBED'
        ]);

        let nodeCounter = 0;

        window.__kylmoraTranslation = {
            extractDetectionSample: function() {
                const htmlLang = document.documentElement.lang ||
                    document.querySelector('meta[http-equiv="content-language"]')?.content || '';
                
                const sampleNodes = document.querySelectorAll('h1, h2, h3, p, article, main');
                let sample = '';
                for (let i = 0; i < sampleNodes.length; i++) {
                    const text = (sampleNodes[i].innerText || '').trim();
                    if (text.length > 20) {
                        sample += text + ' ';
                        if (sample.length > 600) break;
                    }
                }
                if (!sample && document.body) {
                    sample = (document.body.innerText || '').slice(0, 600);
                }
                return JSON.stringify({
                    declaredLang: htmlLang.trim(),
                    sampleText: sample.slice(0, 600).trim()
                });
            },

            extractTranslatableNodes: function() {
                const items = [];
                if (!document.body) return JSON.stringify(items);

                const walker = document.createTreeWalker(
                    document.body,
                    NodeFilter.SHOW_TEXT,
                    {
                        acceptNode: function(node) {
                            const val = node.nodeValue;
                            if (!val || val.trim().length < 2) return NodeFilter.FILTER_REJECT;
                            const parent = node.parentElement;
                            if (!parent) return NodeFilter.FILTER_REJECT;
                            if (EXCLUDED_TAGS.has(parent.tagName)) return NodeFilter.FILTER_REJECT;
                            if (parent.closest('code, pre, [contenteditable="true"], .notranslate, [translate="no"]')) {
                                return NodeFilter.FILTER_REJECT;
                            }
                            return NodeFilter.FILTER_ACCEPT;
                        }
                    }
                );

                let textNode;
                while ((textNode = walker.nextNode())) {
                    const trimmed = textNode.nodeValue.trim();
                    if (trimmed.length > 0) {
                        nodeCounter++;
                        const id = 'ktrans-' + nodeCounter;
                        textNode.__kylmoraTransId = id;
                        if (textNode.__kylmoraOriginalText === undefined) {
                            textNode.__kylmoraOriginalText = textNode.nodeValue;
                        }
                        items.push({ id: id, text: trimmed });
                    }
                }
                return JSON.stringify(items);
            },

            applyTranslations: function(jsonMap) {
                let map = {};
                try {
                    map = typeof jsonMap === 'string' ? JSON.parse(jsonMap) : jsonMap;
                } catch (e) {
                    return 0;
                }

                if (!document.body) return 0;
                const walker = document.createTreeWalker(
                    document.body,
                    NodeFilter.SHOW_TEXT,
                    null
                );

                let applied = 0;
                let textNode;
                while ((textNode = walker.nextNode())) {
                    const id = textNode.__kylmoraTransId;
                    if (id && map[id] !== undefined) {
                        const translated = map[id];
                        const orig = textNode.__kylmoraOriginalText || textNode.nodeValue;
                        const leadMatch = orig.match(/^\\s*/);
                        const trailMatch = orig.match(/\\s*$/);
                        const lead = leadMatch ? leadMatch[0] : '';
                        const trail = trailMatch ? trailMatch[0] : '';
                        textNode.nodeValue = lead + translated + trail;
                        applied++;
                    }
                }
                return applied;
            },

            restoreOriginal: function() {
                if (!document.body) return 0;
                const walker = document.createTreeWalker(
                    document.body,
                    NodeFilter.SHOW_TEXT,
                    null
                );

                let restored = 0;
                let textNode;
                while ((textNode = walker.nextNode())) {
                    if (textNode.__kylmoraOriginalText !== undefined) {
                        textNode.nodeValue = textNode.__kylmoraOriginalText;
                        delete textNode.__kylmoraTransId;
                        delete textNode.__kylmoraOriginalText;
                        restored++;
                    }
                }
                return restored;
            }
        };
    })();
    """

    /// Generates JS call to apply a dictionary of translations.
    public static func applyTranslationsCall(map: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: map),
              let json = String(data: data, encoding: .utf8) else {
            return "0;"
        }
        return "__kylmoraTranslation.applyTranslations(\(json));"
    }
}
