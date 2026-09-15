import Foundation

/// Catalog of actions and commands executable from the Command Palette (Cmd-K).
@MainActor
enum CommandCatalog {
    static let all: [CommandCandidate] = [
        // Tabs
        CommandCandidate(
            id: "new-tab",
            title: "New Tab",
            subtitle: "Open a new tab in current space",
            symbolName: "plus",
            shortcut: "⌘T",
            keywords: ["new", "tab", "open", "create"]
        ),
        CommandCandidate(
            id: "close-tab",
            title: "Close Tab",
            subtitle: "Close current tab",
            symbolName: "xmark",
            shortcut: "⌘W",
            keywords: ["close", "tab", "remove", "dismiss"]
        ),
        CommandCandidate(
            id: "close-all-tabs-in-space",
            title: "Close All Tabs in Space",
            subtitle: "Close all unpinned tabs in current space",
            symbolName: "xmark.square",
            shortcut: "⇧⌥⌘W",
            keywords: ["close", "all", "tabs", "space", "clear", "purge"]
        ),
        CommandCandidate(
            id: "close-selected-tabs",
            title: "Close Selected Tabs",
            subtitle: "Close all currently selected tabs in sidebar",
            symbolName: "xmark.circle",
            shortcut: nil,
            keywords: ["close", "selected", "tabs", "bulk", "multi"]
        ),
        CommandCandidate(
            id: "reload-selected-tabs",
            title: "Reload Selected Tabs",
            subtitle: "Reload all currently selected tabs",
            symbolName: "arrow.clockwise",
            shortcut: nil,
            keywords: ["reload", "refresh", "selected", "tabs", "bulk"]
        ),
        CommandCandidate(
            id: "reopen-closed-tab",
            title: "Reopen Closed Tab",
            subtitle: "Restore last closed tab",
            symbolName: "arrow.uturn.backward",
            shortcut: "⇧⌘T",
            keywords: ["reopen", "closed", "restore", "undo", "last tab"]
        ),
        CommandCandidate(
            id: "reopen-all-closed-tabs",
            title: "Reopen All Closed Tabs",
            subtitle: "Restore all recently closed tabs and windows",
            symbolName: "arrow.uturn.backward.circle",
            shortcut: nil,
            keywords: ["reopen", "closed", "restore", "undo", "all tabs", "windows"]
        ),
        CommandCandidate(
            id: "clear-recently-closed",
            title: "Clear Recently Closed",
            subtitle: "Clear recently closed tabs and windows history",
            symbolName: "trash",
            shortcut: nil,
            keywords: ["clear", "recently", "closed", "history", "tabs", "windows", "purge"]
        ),
        CommandCandidate(
            id: "duplicate-tab",
            title: "Duplicate Tab",
            subtitle: "Clone current tab in current space",
            symbolName: "plus.square.on.square",
            shortcut: "⇧⌘D",
            keywords: ["duplicate", "copy", "tab", "clone"]
        ),
        CommandCandidate(
            id: "pin-tab",
            title: "Pin / Unpin Tab",
            subtitle: "Toggle pinned shortcut in sidebar",
            symbolName: "pin",
            shortcut: "⇧⌘P",
            keywords: ["pin", "unpin", "favorite", "favourite", "tile"]
        ),
        CommandCandidate(
            id: "next-tab",
            title: "Next Tab",
            subtitle: "Switch to next tab in space",
            symbolName: "arrow.right",
            shortcut: "⌥⌘→",
            keywords: ["next", "tab", "cycle"]
        ),
        CommandCandidate(
            id: "previous-tab",
            title: "Previous Tab",
            subtitle: "Switch to previous tab in space",
            symbolName: "arrow.left",
            shortcut: "⌥⌘←",
            keywords: ["previous", "tab", "prev", "cycle"]
        ),
        CommandCandidate(
            id: "show-tab-overview",
            title: "Show Tab Overview",
            subtitle: "View Safari-style visual grid of tabs in current space or all spaces",
            symbolName: "square.grid.2x2",
            shortcut: "⇧⌘\\",
            keywords: ["tab", "overview", "grid", "safari", "thumbnails", "cards", "expose", "all tabs"]
        ),
        CommandCandidate(
            id: "pip-video",
            title: "Picture in Picture",
            subtitle: "Float video on screen or PiP any video",
            symbolName: "pip.enter",
            shortcut: "⌥⌘P",
            keywords: ["pip", "picture in picture", "video", "float", "media", "player"]
        ),
        CommandCandidate(
            id: "toggle-mute-tab",
            title: "Mute / Unmute Tab",
            subtitle: "Toggle audio output for the active tab",
            symbolName: "speaker.wave.2.fill",
            shortcut: nil,
            keywords: ["mute", "unmute", "audio", "sound", "volume", "tab"]
        ),
        CommandCandidate(
            id: "toggle-native-video",
            title: "Toggle Native HTML5 Video Player",
            subtitle: "Toggle Vinegar-style native controls, PiP, and background playback for site",
            symbolName: "play.rectangle",
            shortcut: nil,
            keywords: ["native", "video", "youtube", "html5", "vinegar", "player", "pip", "background"]
        ),
        CommandCandidate(
            id: "toggle-anti-fingerprinting",
            title: "Toggle Anti-Fingerprinting Protection",
            subtitle: "Randomize Canvas, WebGL, and AudioContext signatures per Space",
            symbolName: "shield.lefthalf.filled",
            shortcut: nil,
            keywords: ["anti-fingerprinting", "fingerprint", "canvas", "privacy", "tracking", "noise", "webgl", "audio"]
        ),

        // Spaces
        CommandCandidate(
            id: "next-space",
            title: "Next Space",
            subtitle: "Switch to next space",
            symbolName: "arrow.down",
            shortcut: "⌥⌘↓",
            keywords: ["next", "space", "switch"]
        ),
        CommandCandidate(
            id: "previous-space",
            title: "Previous Space",
            subtitle: "Switch to previous space",
            symbolName: "arrow.up",
            shortcut: "⌥⌘↑",
            keywords: ["previous", "space", "prev", "switch"]
        ),
        CommandCandidate(
            id: "new-space",
            title: "New Space",
            subtitle: "Create a new space",
            symbolName: "plus.rectangle.on.rectangle",
            shortcut: nil,
            keywords: ["new", "space", "create", "workspace"]
        ),
        CommandCandidate(
            id: "clear-space-data",
            title: "Clear This Space's Data\u{2026}",
            subtitle: "Erase cookies, cache and website data for current space",
            symbolName: "trash",
            shortcut: nil,
            keywords: ["clear", "space", "data", "cookies", "cache", "erase", "delete", "reset", "clean"]
        ),

        // Split View
        CommandCandidate(
            id: "split-side-by-side",
            title: "Split Side by Side",
            subtitle: "Tile two tabs vertically side-by-side",
            symbolName: "rectangle.split.2x1",
            shortcut: "⌥⌘V",
            keywords: ["split", "side", "vertical", "tile", "dual"]
        ),
        CommandCandidate(
            id: "split-stacked",
            title: "Split Stacked",
            subtitle: "Tile two tabs horizontally top-and-bottom",
            symbolName: "rectangle.split.1x2",
            shortcut: "⌥⌘H",
            keywords: ["split", "stacked", "horizontal", "tile"]
        ),
        CommandCandidate(
            id: "split-grid",
            title: "Split Grid",
            subtitle: "Tile tabs in a 2x2 grid",
            symbolName: "rectangle.split.2x2",
            shortcut: "⌥⌘G",
            keywords: ["split", "grid", "quad", "tile"]
        ),
        CommandCandidate(
            id: "unsplit",
            title: "Unsplit",
            subtitle: "Exit split view and show single tab",
            symbolName: "rectangle",
            shortcut: "⌥⌘U",
            keywords: ["unsplit", "single", "exit", "close split", "merge"]
        ),
        CommandCandidate(
            id: "toggle-sticky-pane",
            title: "Stick / Unstick Split Pane",
            subtitle: "Keep active pane locked on screen while switching other tabs in sidebar",
            symbolName: "pin",
            shortcut: "⌥⌘S",
            keywords: ["stick", "pin", "lock", "split", "pane", "stay", "freeze", "side"]
        ),
        CommandCandidate(
            id: "undo-split",
            title: "Undo Split",
            subtitle: "Revert to previous split or single tab layout",
            symbolName: "arrow.uturn.backward",
            shortcut: "⌥⌘Z",
            keywords: ["undo", "split", "revert", "restore", "back"]
        ),
        CommandCandidate(
            id: "equalize-split",
            title: "Equalize Split Panes",
            subtitle: "Reset all split pane proportions to equal sizes",
            symbolName: "equal",
            shortcut: "⌥⌘=",
            keywords: ["equal", "balance", "reset", "50/50", "split", "resize", "shares"]
        ),

        // Navigation
        CommandCandidate(
            id: "copy-url",
            title: "Copy URL",
            subtitle: "Copy current page web address to clipboard",
            symbolName: "doc.on.doc",
            shortcut: "⇧⌘C",
            keywords: ["copy", "url", "link", "address", "share", "clipboard"]
        ),
        CommandCandidate(
            id: "reload-page",
            title: "Reload Page",
            subtitle: "Reload current page",
            symbolName: "arrow.clockwise",
            shortcut: "⌘R",
            keywords: ["reload", "refresh", "page"]
        ),
        CommandCandidate(
            id: "stop-loading",
            title: "Stop Loading",
            subtitle: "Stop loading page",
            symbolName: "xmark",
            shortcut: "⌘.",
            keywords: ["stop", "cancel", "halt"]
        ),
        CommandCandidate(
            id: "go-back",
            title: "Back",
            subtitle: "Navigate back in history",
            symbolName: "chevron.left",
            shortcut: "⌘[",
            keywords: ["back", "history", "previous page"]
        ),
        CommandCandidate(
            id: "go-forward",
            title: "Forward",
            subtitle: "Navigate forward in history",
            symbolName: "chevron.right",
            shortcut: "⌘]",
            keywords: ["forward", "history", "next page"]
        ),
        CommandCandidate(
            id: "find-in-page",
            title: "Find in Page",
            subtitle: "Search text on the current page",
            symbolName: "magnifyingglass",
            shortcut: "⌘F",
            keywords: ["find", "search", "page", "text"]
        ),

        // Reader Mode & Zoom
        CommandCandidate(
            id: "reader-mode",
            title: "Toggle Reader Mode",
            subtitle: "Clean distraction-free article view",
            symbolName: "doc.plaintext",
            shortcut: "⇧⌘R",
            keywords: ["reader", "reading", "clean", "article", "distraction"]
        ),
        CommandCandidate(
            id: "always-use-reader-on-domain",
            title: "Always Use Reader Mode on This Domain",
            subtitle: "Automatically open pages from this website in Reader",
            symbolName: "doc.badge.gearshape",
            shortcut: nil,
            keywords: ["reader", "domain", "automatic", "always", "site"]
        ),
        CommandCandidate(
            id: "add-to-reading-list",
            title: "Add to Reading List",
            subtitle: "Save article for offline reading later",
            symbolName: "eyeglasses",
            shortcut: "⇧⌘D",
            keywords: ["reading", "list", "later", "save", "offline"]
        ),
        CommandCandidate(
            id: "show-reading-list",
            title: "Show Reading List",
            subtitle: "Browse and search saved offline articles",
            symbolName: "eyeglasses",
            shortcut: "⌥⇧⌘L",
            keywords: ["reading", "list", "saved", "articles", "offline"]
        ),
        CommandCandidate(
            id: "read-aloud",
            title: "Read Aloud (Text to Speech)",
            subtitle: "Listen to the article using on-device speech",
            symbolName: "speaker.wave.2",
            shortcut: "⌥⌘S",
            keywords: ["speech", "listen", "tts", "read", "aloud", "audio", "voice"]
        ),
        CommandCandidate(
            id: "zoom-in",
            title: "Zoom In",
            subtitle: "Enlarge page contents",
            symbolName: "plus.magnifyingglass",
            shortcut: "⌘+",
            keywords: ["zoom", "in", "enlarge", "bigger", "scale"]
        ),
        CommandCandidate(
            id: "zoom-out",
            title: "Zoom Out",
            subtitle: "Shrink page contents",
            symbolName: "minus.magnifyingglass",
            shortcut: "⌘-",
            keywords: ["zoom", "out", "shrink", "smaller"]
        ),
        CommandCandidate(
            id: "zoom-reset",
            title: "Reset Zoom",
            subtitle: "Restore actual size (100%)",
            symbolName: "equal.square",
            shortcut: "⌘0",
            keywords: ["zoom", "reset", "actual", "100%", "normal"]
        ),

        // Sidebar & Appearance
        CommandCandidate(
            id: "toggle-sidebar",
            title: "Toggle Sidebar",
            subtitle: "Show or hide the Kylmora sidebar",
            symbolName: "sidebar.left",
            shortcut: "⌃⌘S",
            keywords: ["sidebar", "toggle", "hide", "show"]
        ),
        CommandCandidate(
            id: "toggle-icons-only",
            title: "Toggle Icons-Only Sidebar",
            subtitle: "Narrow sidebar strip that expands on hover",
            symbolName: "sidebar.squares.left",
            shortcut: "⌃⌘I",
            keywords: ["icons", "sidebar", "collapse", "expand", "hover", "zen"]
        ),
        CommandCandidate(
            id: "toggle-sidebar-position",
            title: "Toggle Sidebar Position",
            subtitle: "Switch sidebar between left and right window edge",
            symbolName: "arrow.left.arrow.right",
            shortcut: "⌥⌘S",
            keywords: ["sidebar", "position", "left", "right", "edge", "dock"]
        ),
        CommandCandidate(
            id: "sidebar-position-left",
            title: "Sidebar Position: Left",
            subtitle: "Dock sidebar to the left edge of the window",
            symbolName: "sidebar.left",
            shortcut: "",
            keywords: ["sidebar", "left", "leading", "dock"]
        ),
        CommandCandidate(
            id: "sidebar-position-right",
            title: "Sidebar Position: Right",
            subtitle: "Dock sidebar to the right edge of the window",
            symbolName: "sidebar.right",
            shortcut: "",
            keywords: ["sidebar", "right", "trailing", "dock"]
        ),
        CommandCandidate(
            id: "toggle-compact",
            title: "Toggle Compact Mode",
            subtitle: "Auto-hiding floating sidebar for zen browsing",
            symbolName: "arrow.left.and.right.square",
            shortcut: "⌃⌘C",
            keywords: ["compact", "zen", "minimal", "hide"]
        ),
        CommandCandidate(
            id: "toggle-zen-mode",
            title: "Toggle Zen Mode",
            subtitle: "Hide all UI for completely distraction-free browsing",
            symbolName: "sparkles",
            shortcut: "⌃⌘Z",
            keywords: ["zen", "distraction free", "hide all", "minimal", "fullscreen", "clean"]
        ),
        CommandCandidate(
            id: "sidebar-mode-expanded",
            title: "Sidebar Mode: Always Expanded",
            subtitle: "Full-width persistent sidebar",
            symbolName: "sidebar.left",
            shortcut: "",
            keywords: ["sidebar", "expanded", "standard", "full"]
        ),
        CommandCandidate(
            id: "sidebar-mode-icons-only",
            title: "Sidebar Mode: Icons Only",
            subtitle: "Narrow strip that expands to full width on hover",
            symbolName: "sidebar.squares.left",
            shortcut: "",
            keywords: ["sidebar", "icons", "strip", "hover"]
        ),
        CommandCandidate(
            id: "sidebar-mode-compact",
            title: "Sidebar Mode: Compact",
            subtitle: "Floating sidebar that auto-hides offscreen",
            symbolName: "arrow.left.and.right.square",
            shortcut: "",
            keywords: ["sidebar", "compact", "floating"]
        ),
        CommandCandidate(
            id: "toggle-archive",
            title: "Toggle Archive",
            subtitle: "View auto-archived closed tabs",
            symbolName: "archivebox",
            shortcut: "⌥⇧⌘A",
            keywords: ["archive", "library", "history", "closed tabs"]
        ),
        CommandCandidate(
            id: "full-screen",
            title: "Toggle Full Screen",
            subtitle: "Enter or exit macOS full screen",
            symbolName: "arrow.up.left.and.arrow.down.right",
            shortcut: "⌃⌘F",
            keywords: ["full", "screen", "maximize"]
        ),

        // Downloads & Tools
        CommandCandidate(
            id: "downloads",
            title: "Downloads",
            subtitle: "Show active and completed downloads",
            symbolName: "arrow.down.circle",
            shortcut: "⌥⌘L",
            keywords: ["downloads", "files", "downloaded"]
        ),
        CommandCandidate(
            id: "settings",
            title: "Settings",
            subtitle: "Open Kylmora preferences",
            symbolName: "gearshape",
            shortcut: "⌘,",
            keywords: ["settings", "preferences", "config", "options"]
        ),
        CommandCandidate(
            id: "sync-settings",
            title: "Sync Settings",
            subtitle: "Open iCloud and sync preferences",
            symbolName: "arrow.triangle.2.circlepath",
            shortcut: nil,
            keywords: ["sync", "icloud", "backup", "cloud", "account"]
        ),
        CommandCandidate(
            id: "sync-now",
            title: "Sync Now",
            subtitle: "Synchronize tabs and spaces with iCloud now",
            symbolName: "arrow.clockwise.icloud",
            shortcut: "⌥⌘S",
            keywords: ["sync", "now", "cloud", "refresh"]
        ),
        CommandCandidate(
            id: "export-backup",
            title: "Export Backup",
            subtitle: "Export all spaces and tabs to a JSON file",
            symbolName: "square.and.arrow.up",
            shortcut: nil,
            keywords: ["export", "backup", "save", "json"]
        ),
        CommandCandidate(
            id: "import-backup",
            title: "Import Backup",
            subtitle: "Import spaces and tabs from a JSON backup",
            symbolName: "square.and.arrow.down",
            shortcut: nil,
            keywords: ["import", "backup", "restore", "json"]
        ),
        CommandCandidate(
            id: "import-arc",
            title: "Import From Arc",
            subtitle: "Import spaces, folders, and tabs from Arc browser",
            symbolName: "arrow.right.circle",
            shortcut: nil,
            keywords: ["import", "arc", "sidebar", "migrate"]
        ),
        CommandCandidate(
            id: "clear-history",
            title: "Clear Browsing History",
            subtitle: "Erase history database and visit counts",
            symbolName: "trash",
            shortcut: nil,
            keywords: ["clear", "history", "erase", "delete", "privacy", "wipe"]
        ),
        CommandCandidate(
            id: "search-bookmarks",
            title: "Search Bookmarks & Tags",
            subtitle: "Find bookmarks by title, URL, folder, or #tags",
            symbolName: "bookmark",
            shortcut: "⇧⌘B",
            keywords: ["bookmark", "bookmarks", "tags", "tag", "manager", "favorite"]
        ),
        CommandCandidate(
            id: "cleanup-duplicate-bookmarks",
            title: "Clean Up Duplicate Bookmarks",
            subtitle: "Find and remove redundant bookmark duplicates",
            symbolName: "sparkles",
            shortcut: nil,
            keywords: ["duplicate", "cleanup", "bookmarks", "clean", "dedupe", "merge"]
        ),
        CommandCandidate(
            id: "search-history-full-text",
            title: "Search History Full-Text",
            subtitle: "Search contents of all visited web pages locally with FTS5",
            symbolName: "clock.arrow.circlepath",
            shortcut: "⌥⌘Y",
            keywords: ["history", "search", "full-text", "content", "fts", "find", "pages"]
        ),

        // Content Blocking
        CommandCandidate(
            id: "block-element",
            title: "Block Element on Page\u{2026}",
            subtitle: "Interactive element zapper to hide annoying page elements",
            symbolName: "target",
            shortcut: "⌥⌘B",
            keywords: ["block", "element", "zap", "hide", "ad", "picker", "ublock"]
        ),
        CommandCandidate(
            id: "toggle-content-blocking",
            title: "Toggle Content Blocking on This Site",
            subtitle: "Turn ad and tracker blocking on or off for the active site",
            symbolName: "checkmark.shield",
            shortcut: nil,
            keywords: ["shield", "block", "content", "whitelist", "adblock", "tracker"]
        ),
        CommandCandidate(
            id: "blocking-settings",
            title: "Content Blocking & My Rules\u{2026}",
            subtitle: "Manage filter lists, custom subscriptions, and user rules",
            symbolName: "shield.lefthalf.filled",
            shortcut: nil,
            keywords: ["filter", "rules", "custom", "blocker", "easylist", "ublock"]
        ),
        CommandCandidate(
            id: "toggle-block-hostile-behaviour",
            title: "Toggle Block Hostile Page Behaviour",
            subtitle: "Force selectable text, unblock right-click, and shield clipboard",
            symbolName: "hand.raised.slash",
            shortcut: nil,
            keywords: ["hostile", "copy", "select", "right click", "context menu", "clipboard", "unblock"]
        ),

        // Boosts & Site Customization
        CommandCandidate(
            id: "boost-site",
            title: "Boost This Site\u{2026}",
            subtitle: "Inject custom CSS, JavaScript, or styling tweaks into active site",
            symbolName: "wand.and.stars",
            shortcut: "⌥⌘E",
            keywords: ["boost", "css", "javascript", "js", "style", "inject", "custom", "userscript"]
        ),
        CommandCandidate(
            id: "toggle-dark-mode",
            title: "Toggle Universal Dark Mode",
            subtitle: "Invert site colors with smart image and media preservation",
            symbolName: "moon.fill",
            shortcut: "⌥⌘D",
            keywords: ["dark", "mode", "theme", "night", "invert", "black"]
        ),

        // Little Arc
        CommandCandidate(
            id: "open-little-arc",
            title: "New Little Arc Window\u{2026}",
            subtitle: "Open active tab, link, or search in a floating Little Arc window",
            symbolName: "macwindow.on.rectangle",
            shortcut: "⌥⌘N",
            keywords: ["little", "arc", "floating", "window", "preview", "quick", "standalone"]
        ),

        // Web Applications (SSBs)
        CommandCandidate(
            id: "install-site-as-app",
            title: "Install Site as Web App\u{2026}",
            subtitle: "Create a standalone macOS application for this site in Applications / Dock",
            symbolName: "arrow.down.app",
            shortcut: nil,
            keywords: ["install", "app", "pwa", "ssb", "dock", "standalone", "web app"]
        ),
        CommandCandidate(
            id: "open-standalone-app",
            title: "Open in Standalone Window",
            subtitle: "Focus mode: open current page in an independent chromeless window",
            symbolName: "macwindow",
            shortcut: nil,
            keywords: ["standalone", "focus", "window", "chromeless", "web app", "ssb"]
        ),
        CommandCandidate(
            id: "translate-page",
            title: "Translate Page",
            subtitle: "Translate active web page on-device (Private & Local)",
            symbolName: "translate",
            shortcut: "⌥⌘T",
            keywords: ["translate", "language", "translation", "local", "offline", "english", "french", "spanish"]
        ),
        CommandCandidate(
            id: "show-original-page",
            title: "Show Original Page",
            subtitle: "Restore original language of translated web page",
            symbolName: "arrow.uturn.backward",
            shortcut: nil,
            keywords: ["original", "untranslate", "restore", "source", "language"]
        ),

        // Developer Tools
        CommandCandidate(
            id: "show-web-inspector",
            title: "Show Web Inspector",
            subtitle: "Open developer tools and DOM inspector for active page",
            symbolName: "wrench.and.screwdriver",
            shortcut: "⌥⌘I",
            keywords: ["inspector", "develop", "dev", "devtools", "web inspector", "elements", "debug"]
        ),
        CommandCandidate(
            id: "show-js-console",
            title: "Show JavaScript Console",
            subtitle: "Open the JavaScript console for debugging scripts and errors",
            symbolName: "terminal",
            shortcut: "⌥⌘C",
            keywords: ["console", "javascript", "js", "log", "errors", "terminal", "debug"]
        ),
        CommandCandidate(
            id: "inspect-element",
            title: "Inspect Element",
            subtitle: "Inspect DOM elements and styles on the active page",
            symbolName: "cursorarrow.rays",
            shortcut: nil,
            keywords: ["inspect", "element", "dom", "html", "css", "picker"]
        ),
        CommandCandidate(
            id: "empty-caches",
            title: "Empty Caches",
            subtitle: "Clear web browser cache and reload resources freshly",
            symbolName: "trash",
            shortcut: "⌥⇧⌘E",
            keywords: ["cache", "empty", "clear", "flush", "reload"]
        ),

        // Screenshots & Page Capture
        CommandCandidate(
            id: "capture-visible-area",
            title: "Capture Visible Area",
            subtitle: "Save screenshot of visible page to Downloads",
            symbolName: "camera",
            shortcut: "⌥⇧⌘3",
            keywords: ["screenshot", "capture", "screen", "snapshot", "image", "save", "downloads"]
        ),
        CommandCandidate(
            id: "copy-visible-area",
            title: "Copy Visible Area to Clipboard",
            subtitle: "Copy screenshot of visible page directly to clipboard",
            symbolName: "doc.on.clipboard",
            shortcut: "⌃⇧⌘3",
            keywords: ["screenshot", "capture", "copy", "clipboard", "snapshot", "visible"]
        ),
        CommandCandidate(
            id: "capture-full-page",
            title: "Capture Full Page Screenshot",
            subtitle: "Save entire scrollable webpage as an image to Downloads",
            symbolName: "camera.viewfinder",
            shortcut: "⌥⇧⌘4",
            keywords: ["screenshot", "full page", "scroll", "capture", "whole page", "save", "downloads"]
        ),
        CommandCandidate(
            id: "copy-full-page",
            title: "Copy Full Page to Clipboard",
            subtitle: "Copy entire scrollable webpage image directly to clipboard",
            symbolName: "doc.on.clipboard.fill",
            shortcut: "⌃⇧⌘4",
            keywords: ["screenshot", "full page", "copy", "clipboard", "snapshot", "scroll"]
        ),

        // Mouse Gestures
        CommandCandidate(
            id: "toggle-mouse-gestures",
            title: "Toggle Mouse Gestures",
            subtitle: "Turn hold-right-click gestures and rocker navigation on or off",
            symbolName: "hand.draw",
            shortcut: nil,
            keywords: ["mouse", "gesture", "rocker", "swipe", "trail", "navigation"]
        ),

        // Keyboard Navigation & Vim Bindings
        CommandCandidate(
            id: "show-link-hints",
            title: "Show Link Hints",
            subtitle: "Jump to any link or clickable element using keyboard letters",
            symbolName: "link",
            shortcut: "⌥F",
            keywords: ["link", "hints", "keyboard", "vim", "vimium", "click", "jump", "letter", "surfingkeys"]
        ),
        CommandCandidate(
            id: "show-link-hints-new-tab",
            title: "Show Link Hints (Open in New Tab)",
            subtitle: "Activate link hints and open target in a new background tab",
            symbolName: "link.badge.plus",
            shortcut: "⌥⇧F",
            keywords: ["link", "hints", "new tab", "keyboard", "vim", "vimium", "background tab"]
        ),
        CommandCandidate(
            id: "toggle-vim-bindings",
            title: "Toggle Vim Navigation Bindings",
            subtitle: "Turn modal Vim-style keys (j/k scrolling, gg/G, H/L history, x close tab) on or off",
            symbolName: "keyboard",
            shortcut: nil,
            keywords: ["vim", "modal", "keyboard", "navigation", "vimium", "bindings", "jk", "scroll"]
        ),

        // Updates
        CommandCandidate(
            id: "check-for-updates",
            title: "Check for Updates…",
            subtitle: "Check for new versions of Kylmora",
            symbolName: "arrow.triangle.2.circlepath.circle",
            shortcut: nil,
            keywords: ["update", "version", "upgrade", "sparkle", "new", "check"]
        ),

        // Security / Lock
        CommandCandidate(
            id: "lock-browser",
            title: "Lock Browser",
            subtitle: "Lock Kylmora and require authentication",
            symbolName: "lock.shield.fill",
            shortcut: "⌥⌘L",
            keywords: ["lock", "protect", "master", "password", "touch id", "security", "privacy"]
        ),

        // Performance / Diagnostics
        CommandCandidate(
            id: "task-manager",
            title: "Task Manager",
            subtitle: "View per-tab CPU, RAM, and resource usage",
            symbolName: "cpu",
            shortcut: "⌥⌘U",
            keywords: ["task", "manager", "cpu", "ram", "memory", "usage", "resource", "process", "kill", "suspend", "hog"]
        ),

        // iPhone Companion (F-35)
        CommandCandidate(
            id: "open-icloud-inbox",
            title: "Open iCloud Inbox in Finder",
            subtitle: "Reveal the folder where links sent from iPhone & iPad arrive",
            symbolName: "folder.badge.gearshape",
            shortcut: nil,
            keywords: ["iphone", "ipad", "companion", "inbox", "icloud", "drive", "share", "shortcut", "folder", "reveal"]
        ),
        CommandCandidate(
            id: "export-iphone-shortcut",
            title: "Export iPhone Share Sheet Shortcut…",
            subtitle: "Save the 'Send to Kylmora' Apple Shortcut for iPhone and iPad",
            symbolName: "iphone.and.arrow.forward",
            shortcut: nil,
            keywords: ["iphone", "ipad", "shortcut", "share sheet", "send", "companion", "export", "apple"]
        ),
        CommandCandidate(
            id: "process-icloud-inbox",
            title: "Check iCloud Inbox for Links",
            subtitle: "Scan iCloud Inbox and immediately open any pending links from iPhone",
            symbolName: "arrow.clockwise.icloud",
            shortcut: nil,
            keywords: ["iphone", "inbox", "check", "scan", "poll", "refresh", "icloud"]
        ),

        // Web Panels & Floating Windows (F-36)
        CommandCandidate(
            id: "toggle-web-panel",
            title: "Toggle Web Panel",
            subtitle: "Open or collapse pinned side web apps (notes, chat, translate)",
            symbolName: "sidebar.right",
            shortcut: "⌃⌘P",
            keywords: ["web", "panel", "side", "notes", "chat", "chatgpt", "translate", "drawer", "dock"]
        ),
        CommandCandidate(
            id: "pop-out-web-panel",
            title: "Pop Out Web Panel into Floating Window",
            subtitle: "Detach active web panel into an always-on-top floating window",
            symbolName: "macwindow.on.rectangle",
            shortcut: nil,
            keywords: ["pop", "out", "float", "detach", "window", "panel", "always on top", "pip"]
        ),
        CommandCandidate(
            id: "add-web-panel",
            title: "Add Web Panel…",
            subtitle: "Pin a new web app or page to the side panel",
            symbolName: "plus.rectangle.on.rectangle",
            shortcut: nil,
            keywords: ["add", "panel", "new", "web", "pin", "custom", "app"]
        ),
        CommandCandidate(
            id: "toggle-always-on-top",
            title: "Toggle Window Always on Top",
            subtitle: "Keep browser window floating above all other windows",
            symbolName: "pin.fill",
            shortcut: "⌃⌘T",
            keywords: ["always", "on", "top", "float", "pin", "level", "sticky"]
        ),
        CommandCandidate(
            id: "open-floating-window",
            title: "New Floating Web Window…",
            subtitle: "Open an always-on-top floating browser window",
            symbolName: "pip.enter",
            shortcut: "⌥⌘F",
            keywords: ["floating", "window", "pip", "always on top", "small", "auxiliary"]
        ),
        CommandCandidate(
            id: "open-scratchpad",
            title: "Open Quick Notes Scratchpad",
            subtitle: "Open the built-in offline quick notes panel",
            symbolName: "square.and.pencil",
            shortcut: nil,
            keywords: ["notes", "scratchpad", "quick", "memo", "write", "offline"]
        ),
        CommandCandidate(
            id: "show-enterprise-policies",
            title: "Enterprise Policies\u{2026}",
            subtitle: "View corporate management and MDM policies enforced on this device",
            symbolName: "building.2.crop.circle",
            shortcut: nil,
            keywords: ["enterprise", "mdm", "policy", "corporate", "manage", "managed", "admin", "jamf", "intune"]
        )
    ]
}
