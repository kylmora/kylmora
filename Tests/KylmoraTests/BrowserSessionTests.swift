import Foundation
import Testing
@testable import Kylmora

/// These exercise the model only. Tabs create their web view lazily, so none of
/// this touches WebKit.
@MainActor
enum TestSession {
    /// A session with no database and a throwaway session file, so tests never
    /// touch the user's real history or restore a real saved session.
    static func make() -> (BrowserSession, SessionStore) {
        let store = SessionStore(fileURL: FileManager.default.temporaryDirectory
            .appending(path: "kylmora-test-\(UUID().uuidString).json"))
        let defaults = UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!
        return (BrowserSession(database: nil, sessionStore: store, settings: Settings(defaults: defaults)), store)
    }
}

@Suite("Spaces and tabs")
@MainActor
struct BrowserSessionTests {
    private func url(_ string: String) -> URL { URL(string: string)! }

    @Test("A new session has one space holding one active tab")
    func initialState() {
        let session = TestSession.make().0
        #expect(session.spaces.count == 1)
        #expect(session.activeSpace.tabs.count == 1)
        #expect(session.activeTab != nil)
        #expect(session.activeTab?.isLoaded == false)
    }

    @Test("New tabs append and become active")
    func newTabAppendsAndSelects() {
        let session = TestSession.make().0
        let tab = session.newTab(url: url("https://example.com"))
        #expect(session.activeSpace.tabs.count == 2)
        #expect(session.activeSpace.tabs.last === tab)
        #expect(session.activeTab === tab)
    }

    @Test("A background tab does not steal selection")
    func backgroundTabDoesNotSelect() {
        let session = TestSession.make().0
        let first = session.activeTab
        session.newTab(url: url("https://example.com"), select: false)
        #expect(session.activeTab === first)
    }

    @Test("Closing the active tab selects its neighbour")
    func closingActiveSelectsNeighbour() {
        let session = TestSession.make().0
        let a = session.activeSpace.tabs[0]
        let b = session.newTab(url: url("https://b.example"))
        let c = session.newTab(url: url("https://c.example"))

        session.selectTab(b)
        session.closeTab(b)
        #expect(session.activeSpace.tabs.map(\.id) == [a.id, c.id])
        #expect(session.activeTab === c)
    }

    @Test("Closing the last remaining tab leaves nothing active")
    func closingLastTab() {
        let session = TestSession.make().0
        session.closeTab(session.activeTab!)
        #expect(session.activeSpace.tabs.isEmpty)
        #expect(session.activeTab == nil)
    }

    @Test("Closing an inactive tab keeps the selection")
    func closingInactiveKeepsSelection() {
        let session = TestSession.make().0
        let a = session.activeSpace.tabs[0]
        let b = session.newTab(url: url("https://b.example"))
        session.closeTab(a)
        #expect(session.activeTab === b)
    }

    @Test("Tab numbers are one-based and nine means last")
    func selectByNumber() {
        let session = TestSession.make().0
        let a = session.activeSpace.tabs[0]
        let b = session.newTab(url: url("https://b.example"))
        let c = session.newTab(url: url("https://c.example"))

        session.selectTab(number: 1)
        #expect(session.activeTab === a)
        session.selectTab(number: 2)
        #expect(session.activeTab === b)
        session.selectTab(number: 9)
        #expect(session.activeTab === c)
    }

    @Test("Next and previous tab wrap around")
    func selectByOffsetWraps() {
        let session = TestSession.make().0
        let a = session.activeSpace.tabs[0]
        let b = session.newTab(url: url("https://b.example"))

        session.selectTab(a)
        session.selectTab(offsetBy: -1)
        #expect(session.activeTab === b)
        session.selectTab(offsetBy: 1)
        #expect(session.activeTab === a)
    }

    @Test("Dragging a tab downward lands after the tabs it passed")
    func moveTabDown() {
        let session = TestSession.make().0
        let a = session.activeSpace.tabs[0]
        let b = session.newTab(url: url("https://b.example"))
        let c = session.newTab(url: url("https://c.example"))

        session.moveTab(from: 0, to: 3)
        #expect(session.activeSpace.tabs.map(\.id) == [b.id, c.id, a.id])
    }

    @Test("Dragging a tab upward lands at the drop row")
    func moveTabUp() {
        let session = TestSession.make().0
        let a = session.activeSpace.tabs[0]
        let b = session.newTab(url: url("https://b.example"))
        let c = session.newTab(url: url("https://c.example"))

        session.moveTab(from: 2, to: 0)
        #expect(session.activeSpace.tabs.map(\.id) == [c.id, a.id, b.id])
    }

    @Test("A new space becomes active and starts with one tab")
    func addSpace() {
        let session = TestSession.make().0
        let work = session.addSpace(named: "Work")
        #expect(session.spaces.count == 2)
        #expect(session.activeSpaceID == work.id)
        #expect(work.tabs.count == 1)
    }

    @Test("Spaces keep their own tabs")
    func spacesIsolateTabs() {
        let session = TestSession.make().0
        let personal = session.activeSpace
        session.newTab(url: url("https://personal.example"))
        #expect(personal.tabs.count == 2)

        let work = session.addSpace(named: "Work")
        session.newTab(url: url("https://work.example"))
        #expect(work.tabs.count == 2)
        #expect(personal.tabs.count == 2)

        session.selectSpace(personal)
        #expect(session.activeSpace.tabs.count == 2)
        #expect(session.activeTab.map { personal.index(of: $0) != nil } == true)
    }

    @Test("Space switching wraps and never leaves the window")
    func spaceOffsetWraps() {
        let session = TestSession.make().0
        let personal = session.activeSpace
        let work = session.addSpace(named: "Work")

        session.selectSpace(offsetBy: 1)
        #expect(session.activeSpaceID == personal.id)
        session.selectSpace(offsetBy: -1)
        #expect(session.activeSpaceID == work.id)
    }

    @Test("The last space cannot be closed")
    func lastSpaceIsKept() {
        let session = TestSession.make().0
        session.removeSpace(session.activeSpace)
        #expect(session.spaces.count == 1)
    }

    @Test("Closing a space activates another one")
    func removingActiveSpace() {
        let session = TestSession.make().0
        let personal = session.activeSpace
        let work = session.addSpace(named: "Work")

        session.removeSpace(work)
        #expect(session.spaces.count == 1)
        #expect(session.activeSpaceID == personal.id)
    }

    @Test("Renaming ignores blank input")
    func renameIgnoresBlank() {
        let session = TestSession.make().0
        let space = session.activeSpace
        session.rename(space, to: "   ")
        #expect(space.name == "Personal")
        session.rename(space, to: " Research ")
        #expect(space.name == "Research")
    }
}

@Suite("Tab display")
@MainActor
struct TabTests {
    @Test("An unloaded tab shows its host, without the www prefix")
    func displayTitleFallsBackToHost() {
        let tab = Tab(url: URL(string: "https://www.example.com/a/b")!, identity: .standard)
        #expect(tab.displayTitle == "example.com")
    }

    @Test("An unloaded tab cannot navigate its history")
    func unloadedTabHasNoHistory() {
        let tab = Tab(url: URL(string: "https://example.com")!, identity: .standard)
        #expect(tab.isLoaded == false)
        #expect(tab.canGoBack == false)
        #expect(tab.canGoForward == false)
    }

    @Test("Loading a URL before the tab is shown updates the pending address")
    func loadBeforeShown() {
        let tab = Tab(url: URL(string: "https://example.com")!, identity: .standard)
        tab.load(URL(string: "https://other.example/page")!)
        #expect(tab.url.absoluteString == "https://other.example/page")
        #expect(tab.isLoaded == false)
    }
}

@Suite("Reopening a closed tab")
@MainActor
struct ClosedTabTests {
    private func url(_ string: String) -> URL { URL(string: string)! }

    @Test("The last closed tab comes back where it was, selected")
    func reopensLastClosed() {
        let session = TestSession.make().0
        let gone = session.newTab(url: url("https://gone.example"))
        session.newTab(url: url("https://stays.example"))
        #expect(session.canReopenClosedTab == false)

        session.closeTab(gone)
        #expect(session.canReopenClosedTab)
        let back = session.reopenClosedTab()
        #expect(back?.url == url("https://gone.example"))
        #expect(session.activeTab === back)
        #expect(session.activeSpace.tabs.last === back)
        #expect(session.canReopenClosedTab == false)
    }

    @Test("Closed tabs come back most recent first")
    func mostRecentFirst() {
        let session = TestSession.make().0
        let first = session.newTab(url: url("https://first.example"))
        let second = session.newTab(url: url("https://second.example"))
        session.closeTab(first)
        session.closeTab(second)
        #expect(session.reopenClosedTab()?.url == url("https://second.example"))
        #expect(session.reopenClosedTab()?.url == url("https://first.example"))
        #expect(session.reopenClosedTab() == nil)
    }

    @Test("A tab closed in another space reopens in that space")
    func reopensInItsOwnSpace() {
        let session = TestSession.make().0
        let personal = session.activeSpace
        let work = session.addSpace(named: "Work")
        let tab = session.newTab(url: url("https://work.example"))
        session.selectSpace(personal)
        session.closeTab(tab)

        _ = session.reopenClosedTab()
        #expect(session.activeSpace === work)
        #expect(work.tabs.contains { $0.url == url("https://work.example") })
    }

    @Test("A private space's closed tabs are not remembered")
    func privateTabsAreForgotten() {
        let session = TestSession.make().0
        session.addSpace(named: "Private", isPrivate: true)
        let tab = session.newTab(url: url("https://secret.example"))
        session.closeTab(tab)
        #expect(session.canReopenClosedTab == false)
    }
}

@Suite("Live folders open tabs through the session")
@MainActor
struct LiveFolderDelegateTests {
    @Test("An item becomes a background tab in the folder, titled before it loads")
    func opensItemInFolder() {
        let session = TestSession.make().0
        let personal = session.activeSpace
        let folder = session.createGroup(named: "Feed")
        let work = session.addSpace(named: "Work")
        #expect(session.activeSpace === work)

        let item = LiveFolderItem(
            id: "1", title: "Hello", url: URL(string: "https://feed.example/1")!, subtitle: nil, date: nil
        )
        let id = session.liveFolderManager(session.liveFolders, openTabFor: item, inFolder: folder.id)

        // Into the folder's space, not the one the user is looking at.
        let tab = personal.tabs.first { $0.id == id }
        #expect(tab != nil)
        #expect(tab?.groupID == folder.id)
        #expect(tab?.displayTitle == "Hello")
        #expect(session.activeSpace === work)
        #expect(work.tabs.allSatisfy { $0.id != id })
    }

    @Test("Stale items close only their own tabs")
    func closesStaleTabs() {
        let session = TestSession.make().0
        let folder = session.createGroup(named: "Feed")
        let item = LiveFolderItem(
            id: "1", title: "Old", url: URL(string: "https://feed.example/old")!, subtitle: nil, date: nil
        )
        let id = session.liveFolderManager(session.liveFolders, openTabFor: item, inFolder: folder.id)!
        let mine = session.newTab(url: URL(string: "https://mine.example")!)

        session.liveFolderManager(session.liveFolders, closeTabs: [id, mine.id], inFolder: folder.id)
        #expect(session.activeSpace.tabs.allSatisfy { $0.id != id })
        // Not in the folder, so not the manager's to close, whatever it says.
        #expect(session.activeSpace.tabs.contains { $0 === mine })
    }
}

@Suite("The tab menu's operations")
@MainActor
struct TabMenuOperationTests {
    private func url(_ string: String) -> URL { URL(string: string)! }

    @Test("A duplicate lands right after its original, in the same folder, selected")
    func duplicateLandsBeside() {
        let session = TestSession.make().0
        let a = session.newTab(url: url("https://a.example"))
        let b = session.newTab(url: url("https://b.example"))
        let folder = session.createGroup(named: "Work", containing: [a, b])
        session.selectTab(b)

        let copy = session.duplicate(a)
        let tabs = session.activeSpace.tabs
        #expect(copy?.url == a.url)
        #expect(copy?.groupID == folder.id)
        #expect(tabs.firstIndex { $0 === copy } == tabs.firstIndex { $0 === a }! + 1)
        #expect(session.activeTab === copy)
    }

    @Test("Close Other Tabs leaves exactly the one, and Close Tabs Below keeps what is above")
    func closeOthersAndBelow() {
        let session = TestSession.make().0
        let a = session.newTab(url: url("https://a.example"))
        let b = session.newTab(url: url("https://b.example"))
        let c = session.newTab(url: url("https://c.example"))

        session.closeTabs(below: b)
        #expect(session.activeSpace.tabs.contains { $0 === a })
        #expect(session.activeSpace.tabs.contains { $0 === b })
        #expect(!session.activeSpace.tabs.contains { $0 === c })

        session.closeOtherTabs(than: b)
        #expect(session.activeSpace.tabs.count == 1)
        #expect(session.activeSpace.tabs[0] === b)
    }

    @Test("Moving a tab to another space rebuilds it under that space's identity")
    func moveToSpace() {
        let session = TestSession.make().0
        let personal = session.activeSpace
        let tab = session.newTab(url: url("https://moved.example"))
        let folder = session.createGroup(named: "Work", containing: [tab])
        _ = folder
        let work = session.addSpace(named: "Work")
        session.selectSpace(personal)

        session.move(tab, toSpace: work)
        #expect(!personal.tabs.contains { $0 === tab })
        let moved = work.tabs.first { $0.url == url("https://moved.example") }
        #expect(moved != nil)
        #expect(moved?.identity == work.identity)
        // Loose in its new space, and the user has not been moved with it.
        #expect(moved?.groupID == nil)
        #expect(session.activeSpace === personal)
        // A move is not a close: nothing to reopen.
        #expect(session.canReopenClosedTab == false)
    }

    @Test("Moving a group to another space carries its tabs and keeps them filed")
    func moveGroupToSpace() {
        let session = TestSession.make().0
        let personal = session.activeSpace
        let a = session.newTab(url: url("https://a.example"))
        let b = session.newTab(url: url("https://b.example"))
        let group = session.createGroup(named: "Reading", containing: [a, b])
        let work = session.addSpace(named: "Work")
        session.selectSpace(personal)

        session.move(group, toSpace: work)

        // Gone from the source -- the group and both its tabs.
        #expect(personal.group(withID: group.id) == nil)
        #expect(!personal.tabs.contains { $0 === a || $0 === b })

        // Landed in the target, both tabs still filed under the same group and
        // rebuilt for the target's identity.
        #expect(work.group(withID: group.id) != nil)
        let moved = work.tabs(in: group)
        #expect(moved.count == 2)
        #expect(Set(moved.map(\.url)) == [url("https://a.example"), url("https://b.example")])
        #expect(moved.allSatisfy { $0.identity == work.identity })
        // The user is not dragged along with it.
        #expect(session.activeSpace === personal)
    }

    @Test("Reordering a group moves it among the top-level groups")
    func reorderGroups() {
        let session = TestSession.make().0
        let a = session.newTab(url: url("https://a.example"))
        let b = session.newTab(url: url("https://b.example"))
        let first = session.createGroup(named: "First", containing: [a])
        let second = session.createGroup(named: "Second", containing: [b])
        let space = session.activeSpace
        #expect(space.groups.map(\.id) == [first.id, second.id])

        // Second ahead of First.
        session.moveGroup(second, before: first)
        #expect(space.groups.map(\.id) == [second.id, first.id])

        // Second past the last group again.
        session.moveGroup(second, before: nil)
        #expect(space.groups.map(\.id) == [first.id, second.id])
    }

    @Test("Pinning a tab makes it the tile's own, once")
    func pinIsIdempotent() {
        let session = TestSession.make().0
        let tab = session.newTab(url: url("https://pin.example"))
        #expect(session.isPinned(tab) == false)
        session.pin(tab)
        #expect(session.isPinned(tab))
        #expect(tab.pinnedSiteID != nil)
        #expect(session.activeSpace.pinnedSites.count == 1)
        session.pin(tab)
        #expect(session.activeSpace.pinnedSites.count == 1)
    }
}
