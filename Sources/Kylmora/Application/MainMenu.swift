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
        if Settings.shared.showDevelopMenu {
            root.addItem(developMenuItem())
        }
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

    private static func representedItem(
        _ title: String,
        _ action: Selector?,
        _ representedObject: Any?,
        _ key: String = "",
        modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let it = item(title, action, key, modifiers: modifiers)
        it.representedObject = representedObject
        return it
    }

    private static func appMenuItem() -> NSMenuItem {
        submenu(appName, [
            item("About \(appName)", #selector(AppDelegate.showAbout(_:))),
            item("Check for Updates\u{2026}", #selector(AppDelegate.checkForUpdates(_:))),
            item("Enterprise Policies\u{2026}", #selector(BrowserWindowController.showEnterprisePolicies(_:))),
            .separator(),
            item("Settings\u{2026}", #selector(AppDelegate.showSettings(_:)), ","),
            .separator(),
            item("Lock \(appName)", #selector(AppDelegate.lockBrowser(_:)), "l",
                 modifiers: [.command, .option]),
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
            item("Page Setup\u{2026}", #selector(BrowserWindowController.runPageSetup(_:))),
            item("Print\u{2026}", #selector(BrowserWindowController.printPage(_:)), "p"),
            item("Export as PDF\u{2026}", #selector(BrowserWindowController.exportPageAsPDF(_:))),
            .separator(),
            item("Install Site as Web App\u{2026}", #selector(BrowserWindowController.installCurrentSiteAsWebApp(_:))),
            item("Open in Standalone Window", #selector(BrowserWindowController.openCurrentSiteAsStandaloneWebApp(_:))),
            .separator(),
            submenu("Capture Screenshot", [
                item("Capture Visible Area", #selector(BrowserWindowController.captureVisibleArea(_:)), "3",
                     modifiers: [.command, .shift, .option]),
                item("Copy Visible Area to Clipboard", #selector(BrowserWindowController.copyVisibleAreaToClipboard(_:)), "3",
                     modifiers: [.command, .shift, .control]),
                .separator(),
                item("Capture Full Page", #selector(BrowserWindowController.captureFullPage(_:)), "4",
                     modifiers: [.command, .shift, .option]),
                item("Copy Full Page to Clipboard", #selector(BrowserWindowController.copyFullPageToClipboard(_:)), "4",
                     modifiers: [.command, .shift, .control])
            ]),
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
            item("Copy as Markdown Link", #selector(BrowserWindowController.copyMarkdownLink(_:))),
            item("Copy Title and URL", #selector(BrowserWindowController.copyTitleAndURL(_:))),
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
            item("Show Link Hints", #selector(BrowserWindowController.showLinkHints(_:)), "f",
                 modifiers: [.option]),
            item("Show Link Hints in New Tab", #selector(BrowserWindowController.showLinkHintsNewTab(_:)), "f",
                 modifiers: [.option, .shift]),
            item("Vim Navigation Bindings", #selector(BrowserWindowController.toggleVimBindings(_:)), ""),
            .separator(),
            item("Open Glance as a Tab", #selector(BrowserWindowController.promoteGlance(_:)), "o"),
            item("Close Glance", #selector(BrowserWindowController.closeGlance(_:)), "w",
                 modifiers: [.command, .option]),
            .separator(),
            item("Next Tab", #selector(BrowserWindowController.selectNextTab(_:)), "\u{F703}",
                 modifiers: [.command, .option]),
            item("Previous Tab", #selector(BrowserWindowController.selectPreviousTab(_:)), "\u{F702}",
                 modifiers: [.command, .option]),
            item("Next Space", #selector(BrowserWindowController.selectNextSpace(_:)), "\u{F701}",
                 modifiers: [.command, .option]),
            item("Previous Space", #selector(BrowserWindowController.selectPreviousSpace(_:)), "\u{F700}",
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
            item("Stick Pane", #selector(BrowserWindowController.toggleStickyPane(_:)), "s",
                 modifiers: [.command, .option]),
            item("Undo Split", #selector(BrowserWindowController.undoSplit(_:)), "z",
                 modifiers: [.command, .option]),
            item("Equalize Split Panes", #selector(BrowserWindowController.equalizeSplitPanes(_:)), "=",
                 modifiers: [.command, .option]),
            .separator(),
            item("Show Tab Overview", #selector(BrowserWindowController.toggleTabOverview(_:)), "\\",
                 modifiers: [.command, .shift]),
            item("Downloads", #selector(AppDelegate.showDownloads(_:)), "l",
                 modifiers: [.command, .option]),
            item("Archive", #selector(BrowserWindowController.toggleArchive(_:)), "a",
                 modifiers: [.command, .option, .shift]),
            item("Hide Sidebar", #selector(BrowserWindowController.toggleKylmoraSidebar(_:)), "s",
                 modifiers: [.command, .control]),
            item("Icons-Only Sidebar", #selector(BrowserWindowController.toggleIconsOnlySidebar(_:)), "i",
                 modifiers: [.command, .control]),
            item("Compact Mode", #selector(BrowserWindowController.toggleCompactMode(_:)), "c",
                 modifiers: [.command, .control]),
            item("Also Hide Toolbar", #selector(BrowserWindowController.toggleCompactToolbar(_:)), ""),
            item("Keep Sidebar Showing",
                 #selector(BrowserWindowController.toggleCompactSidebarPin(_:)), "s",
                 modifiers: [.command, .control, .option]),
            item("Toggle Sidebar Position",
                 #selector(BrowserWindowController.toggleSidebarPosition(_:)), "s",
                 modifiers: [.command, .option]),
            item("Zen Mode (Hide All UI)",
                 #selector(BrowserWindowController.toggleZenMode(_:)), "z",
                 modifiers: [.command, .control]),
            submenu("Sidebar Mode", [
                representedItem("Always Expanded", #selector(BrowserWindowController.setSidebarModeFromMenu(_:)), SidebarMode.expanded),
                representedItem("Icons Only (Expand on Hover)", #selector(BrowserWindowController.setSidebarModeFromMenu(_:)), SidebarMode.iconsOnly),
                representedItem("Compact (Slide in on Hover)", #selector(BrowserWindowController.setSidebarModeFromMenu(_:)), SidebarMode.compact),
                representedItem("Hidden", #selector(BrowserWindowController.setSidebarModeFromMenu(_:)), SidebarMode.hidden)
            ]),
            submenu("Sidebar Position", [
                representedItem("Left", #selector(BrowserWindowController.setSidebarPositionFromMenu(_:)), SidebarPosition.leading),
                representedItem("Right", #selector(BrowserWindowController.setSidebarPositionFromMenu(_:)), SidebarPosition.trailing)
            ]),
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
                 modifiers: [.command, .option]),
            .separator(),
            item("Translate Page\u{2026}",
                 #selector(BrowserWindowController.toggleTranslationPopover(_:)), "t",
                 modifiers: [.command, .option]),
            item("Show Original Page",
                 #selector(BrowserWindowController.restoreOriginalActivePage(_:)), ""),
            item("View Page Source", #selector(BrowserWindowController.viewPageSource(_:)), "u",
                 modifiers: [.command, .option, .shift]),
            item("Picture in Picture",
                 #selector(BrowserWindowController.togglePictureInPicture(_:)), "p",
                 modifiers: [.command, .option]),
            item("Mute Tab",
                 #selector(BrowserWindowController.toggleMuteActiveTab(_:)), "m",
                 modifiers: [.command, .option]),
            .separator(),
            item("Enter / Exit Reader Mode",
                 #selector(BrowserWindowController.toggleReaderMode(_:)), "r",
                 modifiers: [.command, .shift]),
            item("Add to Reading List",
                 #selector(BrowserWindowController.addToReadingList(_:)), "d",
                 modifiers: [.command, .shift]),
            item("Show Reading List\u{2026}",
                 #selector(BrowserWindowController.toggleReadingListPopover(_:)), "l",
                 modifiers: [.command, .shift, .option]),
            item("Read Aloud",
                 #selector(BrowserWindowController.readAloudCurrentPage(_:)), "s",
                 modifiers: [.command, .option]),
            .separator(),
            item("Toggle Web Panel",
                 #selector(BrowserWindowController.toggleWebPanel(_:)), "p",
                 modifiers: [.command, .control]),
            item("Pop Out Web Panel into Floating Window",
                 #selector(BrowserWindowController.popOutWebPanel(_:)), "")
        ]

        return submenu("View", items)
    }

    private static func developMenuItem() -> NSMenuItem {
        let items: [NSMenuItem] = [
            item("Show Web Inspector",
                 #selector(BrowserWindowController.showWebInspector(_:)), "i",
                 modifiers: [.command, .option]),
            item("Show JavaScript Console",
                 #selector(BrowserWindowController.showJavaScriptConsole(_:)), "c",
                 modifiers: [.command, .option]),
            item("Inspect Element",
                 #selector(BrowserWindowController.inspectElement(_:)), ""),
            .separator(),
            item("Empty Caches\u{2026}",
                 #selector(BrowserWindowController.emptyCaches(_:)), "e",
                 modifiers: [.command, .option, .shift]),
            .separator(),
            item("Task Manager",
                 #selector(BrowserWindowController.openTaskManager(_:)))
        ]
        return submenu("Develop", items)
    }

    private static func windowMenuItem() -> NSMenuItem {
        let menuItem = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Always on Top", #selector(BrowserWindowController.toggleAlwaysOnTop(_:)), "t",
                 modifiers: [.command, .control]),
            item("New Floating Web Window\u{2026}", #selector(BrowserWindowController.openFloatingWindow(_:)), "f",
                 modifiers: [.command, .option, .shift]),
            .separator(),
            item("Task Manager", #selector(BrowserWindowController.openTaskManager(_:)), "u",
                 modifiers: [.command, .option])
        ])
        NSApp.windowsMenu = menuItem.submenu
        return menuItem
    }
}
