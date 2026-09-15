import AppKit
import Foundation

/// Coordinates keyboard shortcut configuration, persistence, conflict detection,
/// and live application to the macOS application menu.
@MainActor
final class ShortcutManager {
    static let shared = ShortcutManager()

    let store: ShortcutStore
    var onChange: (() -> Void)?

    let definitions: [ShortcutDefinition] = [
        // Tabs
        ShortcutDefinition(
            id: "new-tab",
            title: "New Tab",
            category: .tabs,
            selector: #selector(BrowserWindowController.newTab(_:)),
            defaultKey: "t",
            defaultModifiers: [.command]
        ),
        ShortcutDefinition(
            id: "close-tab",
            title: "Close Tab",
            category: .tabs,
            selector: #selector(BrowserWindowController.closeTab(_:)),
            defaultKey: "w",
            defaultModifiers: [.command]
        ),
        ShortcutDefinition(
            id: "close-all-tabs-in-space",
            title: "Close All Tabs in Space",
            category: .tabs,
            selector: #selector(BrowserWindowController.closeAllTabsInCurrentSpace(_:)),
            defaultKey: "w",
            defaultModifiers: [.command, .shift, .option]
        ),
        ShortcutDefinition(
            id: "reopen-tab",
            title: "Reopen Closed Tab",
            category: .tabs,
            selector: #selector(BrowserWindowController.reopenClosedTab(_:)),
            defaultKey: "t",
            defaultModifiers: [.command, .shift]
        ),
        ShortcutDefinition(
            id: "pin-tab",
            title: "Pin / Unpin Tab",
            category: .tabs,
            selector: #selector(BrowserWindowController.togglePinActiveTab(_:)),
            defaultKey: "p",
            defaultModifiers: [.command, .shift]
        ),
        ShortcutDefinition(
            id: "duplicate-tab",
            title: "Duplicate Tab",
            category: .tabs,
            selector: #selector(BrowserWindowController.duplicateActiveTab(_:)),
            defaultKey: "d",
            defaultModifiers: [.command, .shift, .option]
        ),
        ShortcutDefinition(
            id: "new-little-arc",
            title: "New Little Arc Window",
            category: .tabs,
            selector: #selector(BrowserWindowController.openLittleArcWindow(_:)),
            defaultKey: "n",
            defaultModifiers: [.command, .option]
        ),
        ShortcutDefinition(
            id: "next-tab",
            title: "Next Tab",
            category: .tabs,
            selector: #selector(BrowserWindowController.selectNextTab(_:)),
            defaultKey: "\u{F703}",
            defaultModifiers: [.command, .option]
        ),
        ShortcutDefinition(
            id: "previous-tab",
            title: "Previous Tab",
            category: .tabs,
            selector: #selector(BrowserWindowController.selectPreviousTab(_:)),
            defaultKey: "\u{F702}",
            defaultModifiers: [.command, .option]
        ),
        ShortcutDefinition(
            id: "split-side-by-side",
            title: "Split Side by Side",
            category: .tabs,
            selector: #selector(BrowserWindowController.splitSideBySide(_:)),
            defaultKey: "v",
            defaultModifiers: [.command, .option]
        ),
        ShortcutDefinition(
            id: "split-stacked",
            title: "Split Stacked",
            category: .tabs,
            selector: #selector(BrowserWindowController.splitStacked(_:)),
            defaultKey: "h",
            defaultModifiers: [.command, .option, .shift]
        ),
        ShortcutDefinition(
            id: "split-grid",
            title: "Split Grid",
            category: .tabs,
            selector: #selector(BrowserWindowController.splitGrid(_:)),
            defaultKey: "g",
            defaultModifiers: [.command, .option]
        ),
        ShortcutDefinition(
            id: "unsplit",
            title: "Unsplit",
            category: .tabs,
            selector: #selector(BrowserWindowController.unsplit(_:)),
            defaultKey: "u",
            defaultModifiers: [.command, .option]
        ),

        // Navigation
        ShortcutDefinition(
            id: "copy-url",
            title: "Copy URL",
            category: .navigation,
            selector: #selector(BrowserWindowController.copyCurrentURL(_:)),
            defaultKey: "c",
            defaultModifiers: [.command, .shift]
        ),
        ShortcutDefinition(
            id: "open-location",
            title: "Open Location",
            category: .navigation,
            selector: #selector(BrowserWindowController.openLocation(_:)),
            defaultKey: "l",
            defaultModifiers: [.command]
        ),
        ShortcutDefinition(
            id: "reload-page",
            title: "Reload Page",
            category: .navigation,
            selector: #selector(BrowserWindowController.reloadPage(_:)),
            defaultKey: "r",
            defaultModifiers: [.command]
        ),
        ShortcutDefinition(
            id: "stop-loading",
            title: "Stop Loading",
            category: .navigation,
            selector: #selector(BrowserWindowController.stopLoading(_:)),
            defaultKey: ".",
            defaultModifiers: [.command]
        ),
        ShortcutDefinition(
            id: "go-back",
            title: "Back",
            category: .navigation,
            selector: #selector(BrowserWindowController.goBack(_:)),
            defaultKey: "[",
            defaultModifiers: [.command]
        ),
        ShortcutDefinition(
            id: "go-forward",
            title: "Forward",
            category: .navigation,
            selector: #selector(BrowserWindowController.goForward(_:)),
            defaultKey: "]",
            defaultModifiers: [.command]
        ),
        ShortcutDefinition(
            id: "link-hints",
            title: "Show Link Hints",
            category: .navigation,
            selector: #selector(BrowserWindowController.showLinkHints(_:)),
            defaultKey: "f",
            defaultModifiers: [.option]
        ),
        ShortcutDefinition(
            id: "link-hints-new-tab",
            title: "Show Link Hints (Open in New Tab)",
            category: .navigation,
            selector: #selector(BrowserWindowController.showLinkHintsNewTab(_:)),
            defaultKey: "f",
            defaultModifiers: [.option, .shift]
        ),

        // Spaces
        ShortcutDefinition(
            id: "next-space",
            title: "Next Space",
            category: .spaces,
            selector: #selector(BrowserWindowController.selectNextSpace(_:)),
            defaultKey: "\u{F701}",
            defaultModifiers: [.command, .option]
        ),
        ShortcutDefinition(
            id: "previous-space",
            title: "Previous Space",
            category: .spaces,
            selector: #selector(BrowserWindowController.selectPreviousSpace(_:)),
            defaultKey: "\u{F700}",
            defaultModifiers: [.command, .option]
        ),

        // Appearance
        ShortcutDefinition(
            id: "toggle-sidebar",
            title: "Toggle Sidebar",
            category: .appearance,
            selector: #selector(BrowserWindowController.toggleKylmoraSidebar(_:)),
            defaultKey: "s",
            defaultModifiers: [.command, .control]
        ),
        ShortcutDefinition(
            id: "toggle-icons-only",
            title: "Icons-Only Sidebar",
            category: .appearance,
            selector: #selector(BrowserWindowController.toggleIconsOnlySidebar(_:)),
            defaultKey: "i",
            defaultModifiers: [.command, .control]
        ),
        ShortcutDefinition(
            id: "toggle-sidebar-position",
            title: "Toggle Sidebar Position",
            category: .appearance,
            selector: #selector(BrowserWindowController.toggleSidebarPosition(_:)),
            defaultKey: "s",
            defaultModifiers: [.command, .shift, .control]
        ),
        ShortcutDefinition(
            id: "toggle-compact",
            title: "Compact Mode",
            category: .appearance,
            selector: #selector(BrowserWindowController.toggleCompactMode(_:)),
            defaultKey: "c",
            defaultModifiers: [.command, .control]
        ),
        ShortcutDefinition(
            id: "toggle-zen-mode",
            title: "Zen Mode (Hide All UI)",
            category: .appearance,
            selector: #selector(BrowserWindowController.toggleZenMode(_:)),
            defaultKey: "z",
            defaultModifiers: [.command, .control]
        ),
        ShortcutDefinition(
            id: "toggle-archive",
            title: "Toggle Archive",
            category: .appearance,
            selector: #selector(BrowserWindowController.toggleArchive(_:)),
            defaultKey: "a",
            defaultModifiers: [.command, .option, .shift]
        ),
        ShortcutDefinition(
            id: "full-screen",
            title: "Toggle Full Screen",
            category: .appearance,
            selector: #selector(NSWindow.toggleFullScreen(_:)),
            defaultKey: "f",
            defaultModifiers: [.command, .control]
        ),

        // Tools
        ShortcutDefinition(
            id: "command-palette",
            title: "Command Palette",
            category: .tools,
            selector: #selector(BrowserWindowController.openCommandBar(_:)),
            defaultKey: "k",
            defaultModifiers: [.command]
        ),
        ShortcutDefinition(
            id: "downloads",
            title: "Downloads",
            category: .tools,
            selector: #selector(AppDelegate.showDownloads(_:)),
            defaultKey: "l",
            defaultModifiers: [.command, .option]
        ),
        ShortcutDefinition(
            id: "boost-site",
            title: "Boost This Site",
            category: .tools,
            selector: #selector(BrowserWindowController.openBoostEditorFromMenu(_:)),
            defaultKey: "e",
            defaultModifiers: [.command, .option]
        ),
        ShortcutDefinition(
            id: "toggle-dark-mode",
            title: "Universal Dark Mode",
            category: .tools,
            selector: #selector(BrowserWindowController.toggleDarkModeFromMenu(_:)),
            defaultKey: "d",
            defaultModifiers: [.command, .option]
        ),
        ShortcutDefinition(
            id: "block-element",
            title: "Block Element on Page",
            category: .tools,
            selector: #selector(BrowserWindowController.startElementPickerFromMenu(_:)),
            defaultKey: "b",
            defaultModifiers: [.command, .option]
        ),
        ShortcutDefinition(
            id: "keyboard-shortcuts",
            title: "Keyboard Shortcuts",
            category: .tools,
            selector: #selector(BrowserWindowController.showShortcutCheatSheet(_:)),
            defaultKey: "/",
            defaultModifiers: [.command]
        ),
        ShortcutDefinition(
            id: "toggle-tab-bar",
            title: "Show / Hide Tab Bar",
            category: .appearance,
            selector: #selector(BrowserWindowController.toggleTabStrip(_:)),
            defaultKey: "b",
            defaultModifiers: [.command, .control]
        ),
        ShortcutDefinition(
            id: "print-page",
            title: "Print Page",
            category: .tools,
            selector: #selector(BrowserWindowController.printPage(_:)),
            defaultKey: "p",
            defaultModifiers: [.command]
        ),
        ShortcutDefinition(
            id: "export-pdf",
            title: "Export Page as PDF",
            category: .tools,
            selector: #selector(BrowserWindowController.exportPageAsPDF(_:)),
            defaultKey: "",
            defaultModifiers: []
        ),
        ShortcutDefinition(
            id: "view-source",
            title: "View Page Source",
            category: .tools,
            selector: #selector(BrowserWindowController.viewPageSource(_:)),
            defaultKey: "u",
            defaultModifiers: [.command, .option, .shift]
        ),
        ShortcutDefinition(
            id: "copy-markdown-link",
            title: "Copy as Markdown Link",
            category: .navigation,
            selector: #selector(BrowserWindowController.copyMarkdownLink(_:)),
            defaultKey: "",
            defaultModifiers: []
        ),
        ShortcutDefinition(
            id: "translate-page",
            title: "Translate Page",
            category: .tools,
            selector: #selector(BrowserWindowController.toggleTranslationPopover(_:)),
            defaultKey: "t",
            defaultModifiers: [.command, .option]
        ),
        ShortcutDefinition(
            id: "annotate-visible-area",
            title: "Capture and Annotate Visible Area",
            category: .tools,
            selector: #selector(BrowserWindowController.annotateVisibleArea(_:)),
            defaultKey: "3",
            defaultModifiers: [.command, .option, .control]
        ),
        ShortcutDefinition(
            id: "annotate-full-page",
            title: "Capture and Annotate Full Page",
            category: .tools,
            selector: #selector(BrowserWindowController.annotateFullPage(_:)),
            defaultKey: "4",
            defaultModifiers: [.command, .option, .control]
        ),
        ShortcutDefinition(
            id: "capture-visible-area",
            title: "Capture Visible Area",
            category: .tools,
            selector: #selector(BrowserWindowController.captureVisibleArea(_:)),
            defaultKey: "3",
            defaultModifiers: [.command, .shift, .option]
        ),
        ShortcutDefinition(
            id: "copy-visible-area",
            title: "Copy Visible Area to Clipboard",
            category: .tools,
            selector: #selector(BrowserWindowController.copyVisibleAreaToClipboard(_:)),
            defaultKey: "3",
            defaultModifiers: [.command, .shift, .control]
        ),
        ShortcutDefinition(
            id: "capture-full-page",
            title: "Capture Full Page Screenshot",
            category: .tools,
            selector: #selector(BrowserWindowController.captureFullPage(_:)),
            defaultKey: "4",
            defaultModifiers: [.command, .shift, .option]
        ),
        ShortcutDefinition(
            id: "copy-full-page",
            title: "Copy Full Page to Clipboard",
            category: .tools,
            selector: #selector(BrowserWindowController.copyFullPageToClipboard(_:)),
            defaultKey: "4",
            defaultModifiers: [.command, .shift, .control]
        ),
        ShortcutDefinition(
            id: "toggle-reader-mode",
            title: "Enter / Exit Reader Mode",
            category: .tools,
            selector: #selector(BrowserWindowController.toggleReaderMode(_:)),
            defaultKey: "r",
            defaultModifiers: [.command, .shift]
        ),
        ShortcutDefinition(
            id: "add-to-reading-list",
            title: "Add to Reading List",
            category: .tools,
            selector: #selector(BrowserWindowController.addToReadingList(_:)),
            defaultKey: "d",
            defaultModifiers: [.command, .shift]
        ),
        ShortcutDefinition(
            id: "show-reading-list",
            title: "Show Reading List",
            category: .tools,
            selector: #selector(BrowserWindowController.toggleReadingListPopover(_:)),
            defaultKey: "l",
            defaultModifiers: [.command, .shift, .option]
        ),
        ShortcutDefinition(
            id: "read-aloud",
            title: "Read Aloud (Speech)",
            category: .tools,
            selector: #selector(BrowserWindowController.readAloudCurrentPage(_:)),
            defaultKey: "s",
            defaultModifiers: [.command, .option, .shift]
        ),
        ShortcutDefinition(
            id: "search-bookmarks",
            title: "Bookmark Manager & Search",
            category: .tools,
            selector: #selector(BrowserWindowController.openBookmarkManager(_:)),
            defaultKey: "b",
            defaultModifiers: [.command, .shift]
        ),
        ShortcutDefinition(
            id: "search-history-full-text",
            title: "Search History Full-Text",
            category: .tools,
            selector: #selector(BrowserWindowController.openHistorySearch(_:)),
            defaultKey: "y",
            defaultModifiers: [.command, .option]
        ),
        ShortcutDefinition(
            id: "check-for-updates",
            title: "Check for Updates…",
            category: .tools,
            selector: #selector(AppDelegate.checkForUpdates(_:)),
            defaultKey: "",
            defaultModifiers: []
        ),
        ShortcutDefinition(
            id: "lock-browser",
            title: "Lock Browser",
            category: .tools,
            selector: #selector(AppDelegate.lockBrowser(_:)),
            defaultKey: "l",
            defaultModifiers: [.command, .control]
        ),
        ShortcutDefinition(
            id: "task-manager",
            title: "Task Manager",
            category: .tools,
            selector: #selector(BrowserWindowController.openTaskManager(_:)),
            defaultKey: "u",
            defaultModifiers: [.command, .shift]
        )
    ]

    init(store: ShortcutStore = .shared) {
        self.store = store
        store.onChange = { [weak self] in
            self?.apply(to: NSApplication.shared.mainMenu)
            self?.onChange?()
        }
    }

    func definition(for id: String) -> ShortcutDefinition? {
        definitions.first { $0.id == id }
    }

    func effectiveShortcut(for id: String) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
        if let custom = store.shortcut(for: id) {
            guard !custom.isCleared else { return nil }
            return (custom.key, custom.modifiers)
        }
        guard let def = definition(for: id) else { return nil }
        return (def.defaultKey, def.defaultModifiers)
    }

    /// The chord's second stroke, when the shortcut is one.
    func secondKey(for id: String) -> String? {
        store.shortcut(for: id)?.secondKey
    }

    func displayString(for id: String) -> String {
        guard let shortcut = effectiveShortcut(for: id) else { return "" }
        return ShortcutFormatter.format(key: shortcut.key, modifiers: shortcut.modifiers, secondKey: secondKey(for: id))
    }

    /// Every shortcut the menus cannot carry, for the dispatcher: chords on
    /// built-in actions, and anything bound to a custom command.
    struct Binding: Equatable {
        let id: String
        let key: String
        let modifiers: NSEvent.ModifierFlags
        let secondKey: String?
        let selector: Selector?
    }

    var dispatcherBindings: [Binding] {
        store.customShortcuts.compactMap { id, custom in
            guard !custom.isCleared, !custom.key.isEmpty else { return nil }
            let selector = definition(for: id)?.selector
            let isCommand = id.hasPrefix(AutomationService.commandPrefix)
            guard custom.isChord || isCommand else { return nil }
            guard selector != nil || isCommand else { return nil }
            return Binding(id: id, key: custom.key, modifiers: custom.modifiers, secondKey: custom.secondKey, selector: selector)
        }
    }

    /// Binds a chord: the leader stroke, then `secondKey` on its own.
    func setChord(id: String, key: String, modifiers: NSEvent.ModifierFlags, secondKey: String) {
        store.set(CustomShortcut(key: key.lowercased(), modifiers: modifiers, secondKey: secondKey), for: id)
        apply(to: NSApplication.shared.mainMenu)
        onChange?()
    }

    func isCustomized(id: String) -> Bool {
        store.shortcut(for: id) != nil
    }

    func setShortcut(id: String, key: String, modifiers: NSEvent.ModifierFlags) {
        let custom = CustomShortcut(key: key.lowercased(), modifiers: modifiers)
        store.set(custom, for: id)
        apply(to: NSApplication.shared.mainMenu)
        onChange?()
    }

    func resetShortcut(id: String) {
        store.remove(id: id)
        apply(to: NSApplication.shared.mainMenu)
        onChange?()
    }

    /// Unbinds an action entirely: no key combination triggers it until the
    /// user records a new one or resets to the factory default.
    func clearShortcut(id: String) {
        store.set(CustomShortcut(key: "", modifiers: [], isCleared: true), for: id)
        apply(to: NSApplication.shared.mainMenu)
        onChange?()
    }

    func resetAll() {
        store.removeAll()
        apply(to: NSApplication.shared.mainMenu)
        onChange?()
    }

    /// Checks if a key combination conflicts with an existing action.
    func findConflict(key: String, modifiers: NSEvent.ModifierFlags, excluding: String? = nil) -> ShortcutDefinition? {
        let normalizedKey = key.lowercased()
        let cleanMods = modifiers.intersection(.deviceIndependentFlagsMask)

        for def in definitions where def.id != excluding {
            guard let shortcut = effectiveShortcut(for: def.id) else { continue }
            if shortcut.key.lowercased() == normalizedKey &&
               shortcut.modifiers.intersection(.deviceIndependentFlagsMask) == cleanMods {
                return def
            }
        }
        return nil
    }

    /// The custom command, if any, bound to this combination.
    func conflictingCommand(key: String, modifiers: NSEvent.ModifierFlags, excluding: String? = nil) -> String? {
        let cleanMods = modifiers.intersection(.deviceIndependentFlagsMask)
        return store.customShortcuts.first { id, custom in
            id != excluding && id.hasPrefix(AutomationService.commandPrefix) && !custom.isCleared
                && custom.key == key.lowercased() && custom.modifiers.intersection(.deviceIndependentFlagsMask) == cleanMods
        }?.key
    }

    /// Recursively updates all matching menu items in the main menu to reflect custom shortcuts.
    func apply(to menu: NSMenu?) {
        guard let menu else { return }
        updateMenuItems(in: menu)
    }

    private func updateMenuItems(in menu: NSMenu) {
        for item in menu.items {
            if let submenu = item.submenu {
                updateMenuItems(in: submenu)
            }

            guard let action = item.action else { continue }
            guard let def = definitions.first(where: { $0.selector == action }) else { continue }
            // A chord's leader must not fire the menu item on its own; the
            // dispatcher waits for the second stroke.
            if let current = effectiveShortcut(for: def.id), secondKey(for: def.id) == nil {
                item.keyEquivalent = current.key
                item.keyEquivalentModifierMask = current.modifiers
            } else {
                item.keyEquivalent = ""
                item.keyEquivalentModifierMask = []
            }
        }
    }
}
