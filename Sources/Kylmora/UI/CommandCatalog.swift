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
            id: "toggle-compact",
            title: "Toggle Compact Mode",
            subtitle: "Auto-hiding floating sidebar for zen browsing",
            symbolName: "arrow.left.and.right.square",
            shortcut: "⌃⌘C",
            keywords: ["compact", "zen", "minimal", "hide"]
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
        )
    ]
}
