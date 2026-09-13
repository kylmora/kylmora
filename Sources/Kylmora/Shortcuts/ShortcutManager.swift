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
            defaultModifiers: [.command, .shift]
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
            defaultModifiers: [.command, .option]
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
            id: "toggle-compact",
            title: "Compact Mode",
            category: .appearance,
            selector: #selector(BrowserWindowController.toggleCompactMode(_:)),
            defaultKey: "c",
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
        )
    ]

    init(store: ShortcutStore = .shared) {
        self.store = store
        store.onChange = { [weak self] in
            self?.apply(to: NSApp.mainMenu)
            self?.onChange?()
        }
    }

    func definition(for id: String) -> ShortcutDefinition? {
        definitions.first { $0.id == id }
    }

    func effectiveShortcut(for id: String) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
        guard let def = definition(for: id) else { return nil }
        if let custom = store.shortcut(for: id) {
            guard !custom.isCleared else { return nil }
            return (custom.key, custom.modifiers)
        }
        return (def.defaultKey, def.defaultModifiers)
    }

    func displayString(for id: String) -> String {
        guard let shortcut = effectiveShortcut(for: id) else { return "" }
        return ShortcutFormatter.format(key: shortcut.key, modifiers: shortcut.modifiers)
    }

    func isCustomized(id: String) -> Bool {
        store.shortcut(for: id) != nil
    }

    func setShortcut(id: String, key: String, modifiers: NSEvent.ModifierFlags) {
        let custom = CustomShortcut(key: key.lowercased(), modifiers: modifiers)
        store.set(custom, for: id)
        apply(to: NSApp.mainMenu)
        onChange?()
    }

    func resetShortcut(id: String) {
        store.remove(id: id)
        apply(to: NSApp.mainMenu)
        onChange?()
    }

    /// Unbinds an action entirely: no key combination triggers it until the
    /// user records a new one or resets to the factory default.
    func clearShortcut(id: String) {
        store.set(CustomShortcut(key: "", modifiers: [], isCleared: true), for: id)
        apply(to: NSApp.mainMenu)
        onChange?()
    }

    func resetAll() {
        store.removeAll()
        apply(to: NSApp.mainMenu)
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
            if let current = effectiveShortcut(for: def.id) {
                item.keyEquivalent = current.key
                item.keyEquivalentModifierMask = current.modifiers
            } else {
                item.keyEquivalent = ""
                item.keyEquivalentModifierMask = []
            }
        }
    }
}
