import AppKit

/// Fills the View menu's Tabs, Pinned Sites and Spaces submenus when they
/// open, and when the menu bar searches them for a key equivalent.
///
/// These used to be hidden menu items carrying the shortcuts alone. A hidden
/// `NSMenuItem` takes no part in key-equivalent matching, so Cmd-1 through
/// Cmd-9, Option-Cmd-1 through 9 and Control-1 through 9 never fired. Listing
/// the real tabs, pins and spaces instead keeps the menu short, shows the
/// shortcuts where they can be learnt, and makes them work.
///
/// `menuNeedsUpdate` is enough for the shortcuts: AppKit calls it before
/// matching a key equivalent as long as the delegate does not implement
/// `menuHasKeyEquivalent`, which this deliberately does not.
@MainActor
final class WindowListMenu: NSObject, NSMenuDelegate {
    enum Kind {
        case tabs
        case pinnedSites
        case spaces
    }

    private let kind: Kind
    private let session: BrowserSession

    init(kind: Kind, session: BrowserSession) {
        self.kind = kind
        self.session = session
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let items: [NSMenuItem]
        switch kind {
        case .tabs: items = tabItems()
        case .pinnedSites: items = pinnedSiteItems()
        case .spaces: items = spaceItems()
        }
        if items.isEmpty {
            let empty = NSMenuItem(title: emptyTitle, action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        items.forEach { menu.addItem($0) }
    }

    private var emptyTitle: String {
        switch kind {
        case .tabs: return "No Tabs"
        case .pinnedSites: return "No Pinned Sites"
        case .spaces: return "No Spaces"
        }
    }

    /// Cmd-1 to Cmd-8 by position; Cmd-9 is always the last tab, as in
    /// every other browser. Only the tabs the sidebar lists: a pinned site's
    /// tab lives in its tile and is reached through the tile's own shortcut.
    private func tabItems() -> [NSMenuItem] {
        let tabs = session.activeSpace.listedTabs
        let activeID = session.activeTab?.id
        return tabs.enumerated().map { index, tab in
            let item = NSMenuItem(
                title: tab.displayTitle,
                action: #selector(BrowserWindowController.selectTabByNumber(_:)),
                keyEquivalent: Self.shortcut(forIndex: index, count: tabs.count, lastIsNine: true)
            )
            item.tag = index + 1
            item.state = tab.id == activeID ? .on : .off
            return item
        }
    }

    private func pinnedSiteItems() -> [NSMenuItem] {
        let sites = session.activeSpace.pinnedSites
        return sites.enumerated().map { index, site in
            let item = NSMenuItem(
                title: site.title.isEmpty ? AddressFormatter.display(site.url) : site.title,
                action: #selector(BrowserWindowController.openPinnedSiteByNumber(_:)),
                keyEquivalent: Self.shortcut(forIndex: index, count: sites.count, lastIsNine: false)
            )
            item.keyEquivalentModifierMask = [.command, .option]
            item.tag = index + 1
            return item
        }
    }

    /// Control rather than Command, as the sidebar's space menu advertises:
    /// Command-1 through 9 belong to the tabs.
    private func spaceItems() -> [NSMenuItem] {
        let active = session.activeSpaceID
        return session.spaces.enumerated().map { index, space in
            let item = NSMenuItem(
                title: space.name,
                action: #selector(BrowserWindowController.selectSpaceByNumber(_:)),
                keyEquivalent: SpaceTheme.shortcut(forIndex: index) ?? ""
            )
            item.keyEquivalentModifierMask = .control
            item.tag = index + 1
            item.state = space.id == active ? .on : .off
            item.image = space.isPrivate
                ? NSImage(systemSymbolName: "eyeglasses", accessibilityDescription: nil)
                : space.dotImage()
            return item
        }
    }

    /// The digit for a position, or none past the ninth. With `lastIsNine`
    /// the ninth digit goes to the last entry however many there are.
    static func shortcut(forIndex index: Int, count: Int, lastIsNine: Bool) -> String {
        if lastIsNine, index == count - 1, count >= 9 { return "9" }
        guard index < (lastIsNine ? 8 : 9) else { return "" }
        return String(index + 1)
    }
}
