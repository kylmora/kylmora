import AppKit

/// Fills the Bookmarks and History menus the moment before they open.
///
/// Menus are rebuilt on demand rather than kept in sync: history changes on
/// every page load, and nobody is looking at a closed menu.
@MainActor
final class StoredItemsMenu: NSObject, NSMenuDelegate {
    enum Kind {
        case bookmarks
        case history
    }

    private let kind: Kind
    private let session: BrowserSession

    init(kind: Kind, session: BrowserSession) {
        self.kind = kind
        self.session = session
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.title == "Recently Closed" {
            populateRecentlyClosed(menu)
            return
        }

        switch kind {
        case .bookmarks:
            rebuildTree(menu, header: bookmarkCommands(), tree: BookmarkTree.build(from: session.bookmarks))
        case .history:
            // Already-loaded results would be stale; fetch, then fill in place.
            rebuild(menu, header: historyCommands(), entries: [])
            Task { [weak self] in
                guard let self else { return }
                let entries = await self.session.recentHistory(limit: 20)
                self.rebuild(menu, header: self.historyCommands(), entries: entries.map { ($0.title, $0.url) })
            }
        }
    }

    private func bookmarkCommands() -> [NSMenuItem] {
        [
            item("Add Bookmark", #selector(BrowserWindowController.toggleBookmark(_:)), "d"),
            item("Bookmark Manager & Search\u{2026}", #selector(BrowserWindowController.openBookmarkManager(_:)), "b", modifiers: [.command, .shift]),
            item("Clean Up Duplicate Bookmarks", #selector(BrowserWindowController.cleanupDuplicateBookmarks(_:)))
        ]
    }

    private func historyCommands() -> [NSMenuItem] {
        [
            item("Search History (Full-Text)\u{2026}", #selector(BrowserWindowController.openHistorySearch(_:)), "y", modifiers: [.command, .option]),
            item("Clear History\u{2026}", #selector(BrowserWindowController.clearHistory(_:))),
            .separator(),
            recentlyClosedMenuItem()
        ]
    }

    private func recentlyClosedMenuItem() -> NSMenuItem {
        let parentItem = NSMenuItem(title: "Recently Closed", action: nil, keyEquivalent: "")
        parentItem.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "Recently Closed")
        let sub = NSMenu(title: "Recently Closed")
        sub.delegate = self
        populateRecentlyClosed(sub)
        parentItem.submenu = sub
        return parentItem
    }

    private func populateRecentlyClosed(_ menu: NSMenu) {
        menu.removeAllItems()

        let recentWindows = session.recentClosedWindows
        let recentTabs = session.recentClosedTabs

        if recentWindows.isEmpty && recentTabs.isEmpty {
            let empty = NSMenuItem(title: "No Recently Closed Tabs or Windows", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        // Reopen Last Closed Tab
        let reopenLast = item("Reopen Last Closed Tab", #selector(BrowserWindowController.reopenClosedTab(_:)), "t", modifiers: [.command, .shift])
        menu.addItem(reopenLast)
        menu.addItem(.separator())

        // Closed Windows section
        if !recentWindows.isEmpty {
            let windowHeader = NSMenuItem(title: "Closed Windows", action: nil, keyEquivalent: "")
            windowHeader.isEnabled = false
            menu.addItem(windowHeader)

            for window in recentWindows.prefix(8) {
                let title = truncate(window.summaryTitle, maxLength: 60)
                let item = NSMenuItem(
                    title: title,
                    action: #selector(BrowserWindowController.reopenClosedWindowFromMenu(_:)),
                    keyEquivalent: ""
                )
                item.image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: "Closed Window")
                item.representedObject = window.id
                item.toolTip = "\(window.tabCount) tabs: " + window.tabs.prefix(5).map { $0.url.absoluteString }.joined(separator: ", ")
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        // Closed Tabs section
        if !recentTabs.isEmpty {
            let tabHeader = NSMenuItem(title: "Closed Tabs", action: nil, keyEquivalent: "")
            tabHeader.isEnabled = false
            menu.addItem(tabHeader)

            for tab in recentTabs.prefix(15) {
                let title = truncate(tab.title, maxLength: 60)
                let item = NSMenuItem(
                    title: title,
                    action: #selector(BrowserWindowController.reopenClosedTabFromMenu(_:)),
                    keyEquivalent: ""
                )
                item.image = NSImage(systemSymbolName: "globe", accessibilityDescription: "Closed Tab")
                item.representedObject = tab.id
                item.toolTip = tab.url.absoluteString
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        // Batch actions
        menu.addItem(item("Reopen All Closed Tabs", #selector(BrowserWindowController.reopenAllClosedTabs(_:))))
        menu.addItem(item("Clear Recently Closed", #selector(BrowserWindowController.clearRecentlyClosed(_:))))
    }

    private func truncate(_ string: String, maxLength: Int) -> String {
        guard string.count > maxLength else { return string }
        return String(string.prefix(maxLength - 1)) + "\u{2026}"
    }

    private func rebuild(_ menu: NSMenu, header: [NSMenuItem], entries: [(String, URL)]) {
        menu.removeAllItems()
        header.forEach { menu.addItem($0) }
        menu.addItem(.separator())

        guard !entries.isEmpty else {
            let empty = NSMenuItem(title: kind == .bookmarks ? "No Bookmarks" : "No History", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        for (title, url) in entries {
            menu.addItem(urlItem(title: title, url: url))
        }
    }

    /// The bookmarks menu, with imported folders as submenus.
    private func rebuildTree(_ menu: NSMenu, header: [NSMenuItem], tree: [BookmarkTree]) {
        menu.removeAllItems()
        header.forEach { menu.addItem($0) }
        menu.addItem(.separator())

        guard !tree.isEmpty else {
            let empty = NSMenuItem(title: "No Bookmarks", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        fill(menu, with: tree)
    }

    private func fill(_ menu: NSMenu, with items: [BookmarkTree]) {
        for item in items {
            switch item {
            case .bookmark(let bookmark):
                menu.addItem(urlItem(title: bookmark.title, url: bookmark.url))
            case .folder(let name, let children):
                let folder = NSMenuItem(title: name.isEmpty ? "Folder" : name, action: nil, keyEquivalent: "")
                folder.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                let submenu = NSMenu(title: name)
                fill(submenu, with: children)
                folder.submenu = submenu
                menu.addItem(folder)
            }
        }
    }

    private func urlItem(title: String, url: URL) -> NSMenuItem {
        let entry = NSMenuItem(
            title: title.isEmpty ? url.absoluteString : title,
            action: #selector(BrowserWindowController.openStoredURL(_:)),
            keyEquivalent: ""
        )
        entry.representedObject = url
        entry.toolTip = url.absoluteString
        return entry
    }

    private func item(_ title: String, _ action: Selector, _ key: String = "", modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.keyEquivalentModifierMask = modifiers
        return mi
    }
}
