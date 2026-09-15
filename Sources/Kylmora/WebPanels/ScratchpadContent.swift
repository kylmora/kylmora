import Foundation

/// Generates a distraction-free, offline HTML5 scratchpad for quick notes and thoughts in the web panel.
/// Persists note content instantly to `localStorage`.
public enum ScratchpadContent {
    public static let html: String = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
        <title>Quick Notes</title>
        <style>
            :root {
                --bg: #ffffff;
                --text: #1d1d1f;
                --subtext: #86868b;
                --border: #e5e5ea;
                --btn-bg: #f2f2f7;
                --btn-hover: #e5e5ea;
                --accent: #0071e3;
            }
            @media (prefers-color-scheme: dark) {
                :root {
                    --bg: #1c1c1e;
                    --text: #f5f5f7;
                    --subtext: #98989d;
                    --border: #2c2c2e;
                    --btn-bg: #2c2c2e;
                    --btn-hover: #3a3a3c;
                    --accent: #2997ff;
                }
            }
            * {
                box-sizing: border-box;
                margin: 0;
                padding: 0;
            }
            body {
                background: var(--bg);
                color: var(--text);
                font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
                height: 100vh;
                display: flex;
                flex-direction: column;
                overflow: hidden;
            }
            header {
                padding: 10px 14px;
                display: flex;
                align-items: center;
                justify-content: space-between;
                border-bottom: 1px solid var(--border);
                user-select: none;
                -webkit-user-select: none;
            }
            .header-title {
                font-size: 13px;
                font-weight: 600;
                display: flex;
                align-items: center;
                gap: 6px;
                color: var(--text);
            }
            .header-actions {
                display: flex;
                gap: 6px;
            }
            button {
                background: var(--btn-bg);
                color: var(--text);
                border: none;
                border-radius: 6px;
                padding: 4px 8px;
                font-size: 11px;
                font-weight: 500;
                cursor: pointer;
                transition: background 0.15s ease;
                display: inline-flex;
                align-items: center;
                gap: 4px;
            }
            button:hover {
                background: var(--btn-hover);
            }
            button:active {
                opacity: 0.8;
            }
            main {
                flex: 1;
                display: flex;
                flex-direction: column;
                padding: 12px;
                overflow: hidden;
            }
            textarea {
                flex: 1;
                width: 100%;
                background: transparent;
                color: var(--text);
                border: none;
                outline: none;
                resize: none;
                font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Menlo", sans-serif;
                font-size: 13.5px;
                line-height: 1.55;
            }
            textarea::placeholder {
                color: var(--subtext);
                opacity: 0.7;
            }
            footer {
                padding: 6px 14px;
                font-size: 11px;
                color: var(--subtext);
                border-top: 1px solid var(--border);
                display: flex;
                justify-content: space-between;
                align-items: center;
                user-select: none;
                -webkit-user-select: none;
            }
            .status-indicator {
                font-size: 10px;
                color: var(--subtext);
            }
        </style>
    </head>
    <body>
        <header>
            <div class="header-title">
                <span>📝</span>
                <span>Quick Notes</span>
            </div>
            <div class="header-actions">
                <button id="copyBtn" title="Copy to clipboard">Copy</button>
                <button id="clearBtn" title="Clear notes">Clear</button>
            </div>
        </header>
        <main>
            <textarea id="editor" placeholder="Write thoughts, quick notes, to-dos, or snippets here...&#10;Saved automatically on your Mac." spellcheck="true" autofocus></textarea>
        </main>
        <footer>
            <span id="stats">0 words · 0 characters</span>
            <span id="status" class="status-indicator">Saved</span>
        </footer>

        <script>
            const editor = document.getElementById('editor');
            const stats = document.getElementById('stats');
            const status = document.getElementById('status');
            const copyBtn = document.getElementById('copyBtn');
            const clearBtn = document.getElementById('clearBtn');
            const STORAGE_KEY = 'kylmora_scratchpad_notes';

            // Load saved notes
            const saved = localStorage.getItem(STORAGE_KEY);
            if (saved !== null) {
                editor.value = saved;
            }
            updateStats();

            function updateStats() {
                const text = editor.value;
                const chars = text.length;
                const words = text.trim() === '' ? 0 : text.trim().split(/\\s+/).length;
                stats.textContent = `${words} word${words === 1 ? '' : 's'} · ${chars} char${chars === 1 ? '' : 's'}`;
            }

            let saveTimeout;
            editor.addEventListener('input', () => {
                updateStats();
                status.textContent = 'Saving...';
                clearTimeout(saveTimeout);
                saveTimeout = setTimeout(() => {
                    localStorage.setItem(STORAGE_KEY, editor.value);
                    status.textContent = 'Saved';
                }, 200);
            });

            copyBtn.addEventListener('click', async () => {
                try {
                    await navigator.clipboard.writeText(editor.value);
                    const original = copyBtn.textContent;
                    copyBtn.textContent = 'Copied!';
                    setTimeout(() => copyBtn.textContent = original, 1500);
                } catch (e) {
                    console.error('Failed to copy', e);
                }
            });

            clearBtn.addEventListener('click', () => {
                if (editor.value.trim().length === 0) return;
                if (confirm('Clear all scratchpad notes?')) {
                    editor.value = '';
                    localStorage.setItem(STORAGE_KEY, '');
                    updateStats();
                    status.textContent = 'Cleared';
                    setTimeout(() => status.textContent = 'Saved', 1500);
                }
            });
        </script>
    </body>
    </html>
    """
}
