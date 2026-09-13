import AppKit
import Foundation
import Testing
@testable import Kylmora

@Suite("Tab groups")
@MainActor
struct TabGroupTests {
    private func url(_ s: String) -> URL { URL(string: s)! }

    @Test("A new space has no groups and no pins")
    func emptyByDefault() {
        let session = TestSession.make().0
        #expect(session.activeSpace.groups.isEmpty)
        #expect(session.activeSpace.pinnedSites.isEmpty)
        #expect(session.activeSpace.ungroupedTabs.count == session.activeSpace.tabs.count)
    }

    @Test("Grouping tabs files them without reordering the space")
    func groupingKeepsOrder() {
        let session = TestSession.make().0
        let a = session.activeSpace.tabs[0]
        let b = session.newTab(url: url("https://b.example"))
        let c = session.newTab(url: url("https://c.example"))

        let group = session.createGroup(named: "Research", emoji: "🔬", containing: [a, c])

        #expect(session.activeSpace.tabs.map(\.id) == [a.id, b.id, c.id])
        #expect(session.activeSpace.tabs(in: group).map(\.id) == [a.id, c.id])
        #expect(session.activeSpace.ungroupedTabs.map(\.id) == [b.id])
        #expect(group.displayName == "🔬 Research")
    }

    @Test("A group with no emoji shows just its name")
    func displayNameWithoutEmoji() {
        let group = TabGroup(name: "Work")
        #expect(group.displayName == "Work")
    }

    @Test("Collapsing is a view state, not a tab state")
    func collapsingDoesNotTouchTabs() {
        let session = TestSession.make().0
        let tab = session.activeSpace.tabs[0]
        let group = session.createGroup(named: "Work", containing: [tab])

        session.toggleCollapsed(group)
        #expect(group.isCollapsed)
        #expect(session.activeSpace.tabs(in: group).count == 1)
        #expect(tab.groupID == group.id)

        session.toggleCollapsed(group)
        #expect(group.isCollapsed == false)
    }

    @Test("Deleting a group frees its tabs instead of closing them")
    func deletingGroupKeepsTabs() {
        let session = TestSession.make().0
        let tab = session.activeSpace.tabs[0]
        let group = session.createGroup(named: "Work", containing: [tab])

        session.removeGroup(group)
        #expect(session.activeSpace.groups.isEmpty)
        #expect(session.activeSpace.tabs.count == 1)
        #expect(tab.groupID == nil)
    }

    @Test("Deleting a group with closingTabs removes its tabs and frees the rest")
    func deletingGroupClosingTabs() {
        let session = TestSession.make().0
        let loose = session.activeSpace.tabs[0]
        let one = session.newTab(url: url("https://one.example"))
        let two = session.newTab(url: url("https://two.example"))
        let group = session.createGroup(named: "Work", containing: [one, two])
        #expect(session.activeSpace.tabs.count == 3)

        session.removeGroup(group, closingTabs: true)
        #expect(session.activeSpace.groups.isEmpty)
        // The two grouped tabs are gone; the loose one is untouched.
        #expect(session.activeSpace.tabs.map(\.id) == [loose.id])
        // Whatever is selected is a tab that still exists.
        if let active = session.activeSpace.activeTabID {
            #expect(session.activeSpace.tabs.contains { $0.id == active })
        }
    }

    @Test("closingTabs closes only the group's own tabs, not tabs outside it")
    func closingTabsSparesOtherGroups() {
        let session = TestSession.make().0
        let a = session.newTab(url: url("https://a.example"))
        let b = session.newTab(url: url("https://b.example"))
        let keep = session.createGroup(named: "Keep", containing: [a])
        let drop = session.createGroup(named: "Drop", containing: [b])

        session.removeGroup(drop, closingTabs: true)
        #expect(session.activeSpace.tabs.contains { $0.id == a.id })
        #expect(session.activeSpace.tabs.contains { $0.id == b.id } == false)
        #expect(session.activeSpace.group(withID: keep.id) != nil)
        #expect(a.groupID == keep.id)
    }

    @Test("Deleting a group without closingTabs is the default and keeps the tabs")
    func removeGroupDefaultsToKeeping() {
        let session = TestSession.make().0
        let tab = session.newTab(url: url("https://kept.example"))
        let group = session.createGroup(named: "Work", containing: [tab])

        session.removeGroup(group)
        #expect(session.activeSpace.tabs.contains { $0.id == tab.id })
        #expect(tab.groupID == nil)
    }

    @Test("A tab can be moved between groups and back out")
    func movingBetweenGroups() {
        let session = TestSession.make().0
        let tab = session.activeSpace.tabs[0]
        let one = session.createGroup(named: "One")
        let two = session.createGroup(named: "Two")

        session.move(tab, to: one)
        #expect(session.activeSpace.tabs(in: one).count == 1)

        session.move(tab, to: two)
        #expect(session.activeSpace.tabs(in: one).isEmpty)
        #expect(session.activeSpace.tabs(in: two).count == 1)

        session.move(tab, to: nil)
        #expect(session.activeSpace.ungroupedTabs.count == 1)
    }

    @Test("Renaming ignores blank names but accepts a new emoji")
    func renaming() {
        let session = TestSession.make().0
        let group = session.createGroup(named: "Work")
        session.rename(group, to: "   ")
        #expect(group.name == "Work")
        session.rename(group, to: "Research", emoji: "🔬")
        #expect(group.displayName == "🔬 Research")
    }

    @Test("Groups and their filing survive a relaunch")
    func groupsRoundTrip() {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "kylmora-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = SessionStore(fileURL: file)
        let defaults = UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!

        let first = BrowserSession(database: nil, sessionStore: store, settings: Settings(defaults: defaults))
        let tab = first.activeSpace.tabs[0]
        let group = first.createGroup(named: "Research", emoji: "🔬", containing: [tab])
        first.toggleCollapsed(group)
        first.saveNow()

        let second = BrowserSession(database: nil, sessionStore: store, settings: Settings(defaults: defaults))
        #expect(second.activeSpace.groups.count == 1)
        let restored = second.activeSpace.groups[0]
        #expect(restored.displayName == "🔬 Research")
        #expect(restored.isCollapsed)
        #expect(second.activeSpace.tabs(in: restored).count == 1)
    }

    @Test("A group's colour survives a relaunch, and a plain one stays out of the file")
    func appearanceRoundTrips() throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "kylmora-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = SessionStore(fileURL: file)
        let defaults = UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!

        let first = BrowserSession(database: nil, sessionStore: store, settings: Settings(defaults: defaults))
        let coloured = first.createGroup(named: "Coloured")
        _ = first.createGroup(named: "Plain")
        first.setAppearance(
            TabGroupAppearance(fill: .gradient, startColorHex: "#ff0000", endColorHex: "#0000ff",
                               direction: .upRight, elevation: .bold),
            for: coloured
        )
        first.saveNow()

        // The default plate is left out of the JSON, so exactly one of the two
        // groups -- the coloured one -- writes a group appearance object. (The
        // `:{` distinguishes it from a space look's own `"appearance"` string.)
        let json = try String(contentsOf: file, encoding: .utf8)
        #expect(json.components(separatedBy: "\"appearance\":{").count - 1 == 1)

        let second = BrowserSession(database: nil, sessionStore: store, settings: Settings(defaults: defaults))
        let restoredColoured = try #require(second.activeSpace.groups.first { $0.name == "Coloured" })
        let restoredPlain = try #require(second.activeSpace.groups.first { $0.name == "Plain" })
        #expect(restoredColoured.appearance == TabGroupAppearance(
            fill: .gradient, startColorHex: "#ff0000", endColorHex: "#0000ff",
            direction: .upRight, elevation: .bold
        ))
        #expect(restoredPlain.appearance.isStandard)
    }

    @Test("A tab whose group is gone comes back ungrouped, not invisible")
    func orphanedTabIsUngrouped() throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "kylmora-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }

        let stored = """
            {"spaces":[{"name":"Personal","symbolName":"person","tint":"#0091ff",
            "tabs":[{"url":"https://example.com","groupID":"11111111-1111-1111-1111-111111111111"}],
            "activeTabIndex":0}],"activeSpaceIndex":0}
            """
        try Data(stored.utf8).write(to: file)

        let defaults = UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!
        let session = BrowserSession(
            database: nil,
            sessionStore: SessionStore(fileURL: file),
            settings: Settings(defaults: defaults)
        )
        #expect(session.activeSpace.tabs.count == 1)
        #expect(session.activeSpace.ungroupedTabs.count == 1)
    }
}

@Suite("Pinned sites")
@MainActor
struct PinnedSiteTests {
    private func url(_ s: String) -> URL { URL(string: s)! }

    @Test("Pinning the active tab adds one tile")
    func pinning() {
        let session = TestSession.make().0
        session.pinActiveTab()
        #expect(session.activeSpace.pinnedSites.count == 1)
    }

    @Test("The same site cannot be pinned twice")
    func noDuplicatePins() {
        let session = TestSession.make().0
        session.pinActiveTab()
        session.pinActiveTab()
        #expect(session.activeSpace.pinnedSites.count == 1)
    }

    @Test("Matching ignores query, fragment and a trailing slash")
    func matching() {
        let site = PinnedSite(url: url("https://mail.example.com/inbox"), title: "Mail")
        #expect(site.matches(url("https://mail.example.com/inbox/")))
        #expect(site.matches(url("https://mail.example.com/inbox?page=2")))
        #expect(site.matches(url("https://MAIL.example.com/inbox#top")))
        #expect(site.matches(url("https://mail.example.com/sent") ) == false)
        #expect(site.matches(url("https://other.example.com/inbox")) == false)
    }

    @Test("Opening a pin reuses the tab already on that site")
    func openingReusesTab() {
        let session = TestSession.make().0
        let existing = session.newTab(url: url("https://mail.example.com/inbox"))
        let before = session.activeSpace.tabs.count
        session.newTab(url: url("https://elsewhere.example"))

        let site = PinnedSite(url: url("https://mail.example.com/inbox?page=2"), title: "Mail")
        session.openPinnedSite(site)

        #expect(session.activeTab === existing)
        #expect(session.activeSpace.tabs.count == before + 1)
    }

    @Test("Opening a pin with no matching tab opens one")
    func openingCreatesTab() {
        let session = TestSession.make().0
        let before = session.activeSpace.tabs.count
        session.openPinnedSite(PinnedSite(url: url("https://new.example"), title: "New"))
        #expect(session.activeSpace.tabs.count == before + 1)
        #expect(session.activeTab?.url.host() == "new.example")
    }

    @Test("Pins reorder and persist")
    func reorderAndPersist() {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "kylmora-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = SessionStore(fileURL: file)
        let defaults = UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!

        let first = BrowserSession(database: nil, sessionStore: store, settings: Settings(defaults: defaults))
        first.activeSpace.addPinnedSite(PinnedSite(url: url("https://a.example"), title: "A"))
        first.activeSpace.addPinnedSite(PinnedSite(url: url("https://b.example"), title: "B"))
        first.movePinnedSite(from: 1, to: 0)
        #expect(first.activeSpace.pinnedSites.map(\.title) == ["B", "A"])
        first.saveNow()

        let second = BrowserSession(database: nil, sessionStore: store, settings: Settings(defaults: defaults))
        #expect(second.activeSpace.pinnedSites.map(\.title) == ["B", "A"])
    }
}

@Suite("Pinned shortcuts own a tab")
@MainActor
struct PinnedTabOwnershipTests {
    private func url(_ s: String) -> URL { URL(string: s)! }

    @Test("Opening a pin twice reuses its tab rather than piling up duplicates")
    func opensOnce() {
        let session = TestSession.make().0
        let site = PinnedSite(url: url("https://slack.com/"), title: "Slack")
        session.activeSpace.addPinnedSite(site)

        let before = session.activeSpace.tabs.count
        session.openPinnedSite(site)
        session.openPinnedSite(site)
        session.openPinnedSite(site)
        #expect(session.activeSpace.tabs.count == before + 1)
    }

    @Test("The tab stays the shortcut's after the site navigates away")
    func survivesNavigation() {
        let session = TestSession.make().0
        let site = PinnedSite(url: url("https://slack.com/"), title: "Slack")
        session.activeSpace.addPinnedSite(site)
        session.openPinnedSite(site)

        // Exactly what caught this: the site redirects on first load.
        session.activeTab?.load(url("https://slack.com/intl/en-in/"))
        let count = session.activeSpace.tabs.count

        session.openPinnedSite(site)
        #expect(session.activeSpace.tabs.count == count)
    }

    @Test("Pinning the active tab keeps it selected and takes it off the list")
    func pinningActiveTab() {
        let session = TestSession.make().0
        let tab = session.newTab(url: url("https://pin.example/"))
        #expect(session.activeTab === tab)

        session.pin(tab)
        // The tab is the tile's own now: gone from the list, still the active
        // one, so the tile lights up rather than nothing being selected.
        #expect(tab.pinnedSiteID != nil)
        #expect(session.activeSpace.listedTabs.contains { $0.id == tab.id } == false)
        #expect(session.activeSpace.activeTabID == tab.id)
        #expect(session.activeSpace.tab(forPin: tab.pinnedSiteID!)?.id == tab.id)
    }

    @Test("Unpinning the active tab returns it to the list, still selected")
    func unpinningActiveTab() throws {
        let session = TestSession.make().0
        let tab = session.newTab(url: url("https://pin.example/"))
        session.pin(tab)
        let site = session.activeSpace.pinnedSites.first { $0.id == tab.pinnedSiteID }

        session.removePinnedSite(try #require(site))
        #expect(tab.pinnedSiteID == nil)
        #expect(session.activeSpace.listedTabs.contains { $0.id == tab.id })
        #expect(session.activeSpace.activeTabID == tab.id)
        #expect(session.activeSpace.pinnedSites.isEmpty)
    }

    @Test("A shortcut's tab is not listed, because its tile represents it")
    func notListed() {
        let session = TestSession.make().0
        let site = PinnedSite(url: url("https://slack.com/"), title: "Slack")
        session.activeSpace.addPinnedSite(site)
        session.openPinnedSite(site)

        let space = session.activeSpace
        #expect(space.tabs.contains { $0.pinnedSiteID == site.id })
        #expect(space.listedTabs.contains { $0.pinnedSiteID == site.id } == false)
        #expect(space.listedTabs.count == space.tabs.count - 1)
    }

    @Test("A tab already on the site is adopted rather than duplicated")
    func adoptsExistingTab() {
        let session = TestSession.make().0
        let existing = session.newTab(url: url("https://slack.com/"))
        let site = PinnedSite(url: url("https://slack.com/"), title: "Slack")
        session.activeSpace.addPinnedSite(site)

        let before = session.activeSpace.tabs.count
        session.openPinnedSite(site)
        #expect(session.activeSpace.tabs.count == before)
        #expect(existing.pinnedSiteID == site.id)
    }

    @Test("Unpinning returns the tab to the list instead of closing it")
    func unpinReleasesTab() {
        let session = TestSession.make().0
        let site = PinnedSite(url: url("https://slack.com/"), title: "Slack")
        session.activeSpace.addPinnedSite(site)
        session.openPinnedSite(site)
        let count = session.activeSpace.tabs.count

        session.removePinnedSite(site)
        #expect(session.activeSpace.tabs.count == count)
        #expect(session.activeSpace.listedTabs.count == count)
    }

    @Test("Ownership survives a relaunch")
    func survivesRestart() {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "kylmora-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = SessionStore(fileURL: file)
        let defaults = UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!

        let first = BrowserSession(database: nil, sessionStore: store, settings: Settings(defaults: defaults))
        let site = PinnedSite(url: url("https://slack.com/"), title: "Slack")
        first.activeSpace.addPinnedSite(site)
        first.openPinnedSite(site)
        first.saveNow()

        let second = BrowserSession(database: nil, sessionStore: store, settings: Settings(defaults: defaults))
        #expect(second.activeSpace.tab(forPin: site.id) != nil)
        #expect(second.activeSpace.listedTabs.count == second.activeSpace.tabs.count - 1)
    }
}
