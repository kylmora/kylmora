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
        [item("Add Bookmark", #selector(BrowserWindowController.toggleBookmark(_:)), "d")]
    }

    private func historyCommands() -> [NSMenuItem] {
        [item("Clear History", #selector(BrowserWindowController.clearHistory(_:)))]
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

    private func item(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: key)
    }
}
