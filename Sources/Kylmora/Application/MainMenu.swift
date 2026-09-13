import AppKit

/// Builds the application menu bar in code.
///
/// Without an Xcode project there is no MainMenu.nib. Building it here also
/// keeps it honest: an item exists only when something is wired behind it.
@MainActor
enum MainMenu {
    /// The Bookmarks and History submenus are filled by their delegates when
    /// they open, so their contents are never stale.
    static func build(
        bookmarks: NSMenuDelegate,
        history: NSMenuDelegate,
        tabs: NSMenuDelegate,
        pinnedSites: NSMenuDelegate,
        spaces: NSMenuDelegate
    ) -> NSMenu {
        let root = NSMenu()
        root.addItem(appMenuItem())
        root.addItem(fileMenuItem())
        root.addItem(editMenuItem())
        root.addItem(viewMenuItem(tabs: tabs, pinnedSites: pinnedSites, spaces: spaces))
        root.addItem(dynamicMenuItem(titled: "Bookmarks", delegate: bookmarks))
        root.addItem(dynamicMenuItem(titled: "History", delegate: history))
        root.addItem(windowMenuItem())
        ShortcutManager.shared.apply(to: root)
        return root
    }

    private static func dynamicMenuItem(titled title: String, delegate: NSMenuDelegate) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        menu.delegate = delegate
        // A menu with no items is not shown at all, so seed one placeholder that
        // the delegate replaces the instant the menu is opened.
        menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
        item.submenu = menu
        return item
    }

    private static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Kylmora"
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        items.forEach { menu.addItem($0) }
        item.submenu = menu
        return item
    }

    private static func item(
        _ title: String,
        _ action: Selector?,
        _ key: String = "",
        modifiers: NSEvent.ModifierFlags = .command,
        hidden: Bool = false
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.isHidden = hidden
        return item
    }

    private static func appMenuItem() -> NSMenuItem {
        submenu(appName, [
            item("About \(appName)", #selector(AppDelegate.showAbout(_:))),
            .separator(),
            item("Settings\u{2026}", #selector(AppDelegate.showSettings(_:)), ","),
            .separator(),
            item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h",
                 modifiers: [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q")
        ])
    }

    private static func fileMenuItem() -> NSMenuItem {
        submenu("File", [
            item("New Tab", #selector(BrowserWindowController.newTab(_:)), "t"),
            item("New Little Arc Window\u{2026}", #selector(BrowserWindowController.openLittleArcWindow(_:)), "n",
                 modifiers: [.command, .option]),
            item("Pin / Unpin Tab", #selector(BrowserWindowController.togglePinActiveTab(_:)), "p",
                 modifiers: [.command, .shift]),
            item("Duplicate Tab", #selector(BrowserWindowController.duplicateActiveTab(_:)), "d",
                 modifiers: [.command, .shift]),
            item("Reopen Closed Tab", #selector(BrowserWindowController.reopenClosedTab(_:)), "t",
                 modifiers: [.command, .shift]),
            item("Close Tab", #selector(BrowserWindowController.closeTab(_:)), "w"),
            item("Close All Tabs in Current Space", #selector(BrowserWindowController.closeAllTabsInCurrentSpace(_:)), "w",
                 modifiers: [.command, .shift, .option]),
            .separator(),
            item("Install Site as Web App\u{2026}", #selector(BrowserWindowController.installCurrentSiteAsWebApp(_:))),
            item("Open in Standalone Window", #selector(BrowserWindowController.openCurrentSiteAsStandaloneWebApp(_:))),
            .separator(),
            item("Sync Now", #selector(AppDelegate.syncNow(_:)), "s", modifiers: [.command, .option]),
            item("Sync Settings\u{2026}", #selector(AppDelegate.showSyncSettings(_:))),
            item("Export Sidebar & Data\u{2026}", #selector(AppDelegate.exportBackup(_:))),
            item("Import Sidebar & Data\u{2026}", #selector(AppDelegate.importBackup(_:))),
            item("Import From Arc Sidebar\u{2026}", #selector(AppDelegate.importArcSidebar(_:))),
            item("Import From Browser\u{2026}", #selector(AppDelegate.importFromBrowser(_:))),
            .separator(),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w", modifiers: [.command, .shift])
        ])
    }

    private static func editMenuItem() -> NSMenuItem {
        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", modifiers: [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Copy URL", #selector(BrowserWindowController.copyCurrentURL(_:)), "c",
                 modifiers: [.command, .shift]),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            spellingMenuItem(),
            .separator(),
            item("Find\u{2026}", #selector(BrowserWindowController.performFind(_:)), "f"),
            item("Find Next", #selector(BrowserWindowController.findNext(_:)), "g"),
            item("Find Previous", #selector(BrowserWindowController.findPrevious(_:)), "g",
                 modifiers: [.command, .shift])
        ])
    }

    /// The standard Spelling and Grammar submenu. These selectors are the ones
    /// AppKit's text system and WKWebView already answer on the responder chain,
    /// and AppKit ticks the toggles itself from the spell checker's state -- so
    /// this is the real, working control for spell checking in editable web
    /// content (a Settings toggle cannot drive WKWebView's per-field checking).
    private static func spellingMenuItem() -> NSMenuItem {
        submenu("Spelling and Grammar", [
            item("Show Spelling and Grammar", Selector(("showGuessPanel:")), ":"),
            item("Check Document Now", Selector(("checkSpelling:")), ";"),
            .separator(),
            item("Check Spelling While Typing", Selector(("toggleContinuousSpellChecking:")), ""),
            item("Check Grammar With Spelling", Selector(("toggleGrammarChecking:")), ""),
            item("Correct Spelling Automatically", Selector(("toggleAutomaticSpellingCorrection:")), "")
        ])
    }

    /// Automatic, Light, Dark -- the standard three, in the same order.
    private static func appearanceMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Appearance")
        for preference in AppearancePreference.allCases {
            let entry = NSMenuItem(
                title: preference.title,
                action: #selector(AppDelegate.setAppearance(_:)),
                keyEquivalent: ""
            )
            entry.tag = preference.menuTag
            // Targeted explicitly rather than left to the responder chain.
            // Every other item here is handled by the window controller, which
            // is in the chain; the application delegate is not reached the same
            // way, and an item that silently does nothing is the worst failure
            // mode a menu has.
            entry.target = NSApp.delegate
            menu.addItem(entry)
        }
        item.submenu = menu
        return item
    }

    private static func viewMenuItem(
        tabs: NSMenuDelegate,
        pinnedSites: NSMenuDelegate,
        spaces: NSMenuDelegate
    ) -> NSMenuItem {
        var items: [NSMenuItem] = [
            appearanceMenuItem(),
            .separator(),
            item("Command Palette\u{2026}", #selector(BrowserWindowController.openCommandBar(_:)), "k"),
            item("Open Location\u{2026}", #selector(BrowserWindowController.openLocation(_:)), "l"),
            item("Reload Page", #selector(BrowserWindowController.reloadPage(_:)), "r"),
            item("Stop Loading", #selector(BrowserWindowController.stopLoading(_:)), "."),
            .separator(),
            item("Back", #selector(BrowserWindowController.goBack(_:)), "["),
            item("Forward", #selector(BrowserWindowController.goForward(_:)), "]"),
            .separator(),
            item("Open Glance as a Tab", #selector(BrowserWindowController.promoteGlance(_:)), "o"),
            item("Close Glance", #selector(BrowserWindowController.closeGlance(_:)), "w",
                 modifiers: [.command, .option]),
            .separator(),
            item("Next Tab", #selector(BrowserWindowController.selectNextTab(_:)), "\u{2192}",
                 modifiers: [.command, .option]),
            item("Previous Tab", #selector(BrowserWindowController.selectPreviousTab(_:)), "\u{2190}",
                 modifiers: [.command, .option]),
            item("Next Space", #selector(BrowserWindowController.selectNextSpace(_:)), "\u{2193}",
                 modifiers: [.command, .option]),
            item("Previous Space", #selector(BrowserWindowController.selectPreviousSpace(_:)), "\u{2191}",
                 modifiers: [.command, .option]),
            .separator()
        ]

        // Cmd-1 ... 9 select a tab, Option-Cmd-1 ... 9 open a pinned site and
        // Control-1 ... 9 switch space. Each lives in a submenu listing the
        // real entries, filled when it opens (`WindowListMenu`). They were
        // hidden items once, and a hidden item's key equivalent never fires.
        items += [
            dynamicMenuItem(titled: "Tabs", delegate: tabs),
            dynamicMenuItem(titled: "Pinned Sites", delegate: pinnedSites),
            dynamicMenuItem(titled: "Spaces", delegate: spaces)
        ]

        items += [
            .separator(),
            item("Split Side by Side", #selector(BrowserWindowController.splitSideBySide(_:)), "v",
                 modifiers: [.command, .option]),
            item("Split Stacked", #selector(BrowserWindowController.splitStacked(_:)), "h",
                 modifiers: [.command, .option]),
            item("Split Grid", #selector(BrowserWindowController.splitGrid(_:)), "g",
                 modifiers: [.command, .option]),
            item("Unsplit", #selector(BrowserWindowController.unsplit(_:)), "u",
                 modifiers: [.command, .option]),
            .separator(),
            item("Downloads", #selector(AppDelegate.showDownloads(_:)), "l",
                 modifiers: [.command, .option]),
            item("Archive", #selector(BrowserWindowController.toggleArchive(_:)), "a",
                 modifiers: [.command, .option, .shift]),
            item("Hide Sidebar", #selector(BrowserWindowController.toggleKylmoraSidebar(_:)), "s",
                 modifiers: [.command, .control]),
            item("Compact Mode", #selector(BrowserWindowController.toggleCompactMode(_:)), "c",
                 modifiers: [.command, .control]),
            item("Also Hide Toolbar", #selector(BrowserWindowController.toggleCompactToolbar(_:)), ""),
            item("Keep Sidebar Showing",
                 #selector(BrowserWindowController.toggleCompactSidebarPin(_:)), "s",
                 modifiers: [.command, .control, .option]),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f",
                 modifiers: [.command, .control]),
            .separator(),
            item("Block Element on Page\u{2026}",
                 #selector(BrowserWindowController.startElementPickerFromMenu(_:)), "b",
                 modifiers: [.command, .option]),
            item("Toggle Content Blocking on This Site",
                 #selector(BrowserWindowController.toggleContentBlockingFromMenu(_:)), ""),
            .separator(),
            item("Boost This Site\u{2026}",
                 #selector(BrowserWindowController.openBoostEditorFromMenu(_:)), "e",
                 modifiers: [.command, .option]),
            item("Toggle Universal Dark Mode",
                 #selector(BrowserWindowController.toggleDarkModeFromMenu(_:)), "d",
                 modifiers: [.command, .option])
        ]

        return submenu("View", items)
    }

    private static func windowMenuItem() -> NSMenuItem {
        let menuItem = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:)))
        ])
        NSApp.windowsMenu = menuItem.submenu
        return menuItem
    }
}
