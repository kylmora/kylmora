import Foundation
import Testing
@testable import Kylmora

@Suite("Locking a tab against closing")
@MainActor
struct TabLockTests {
    private let url = URL(string: "https://example.com/keep")!

    @Test("A locked tab refuses to close, and says so by returning false")
    func lockedTabDoesNotClose() {
        let session = TestSession.make().0
        let tab = session.newTab(url: url)
        tab.setLocked(true)

        #expect(session.closeTab(tab) == false)
        #expect(session.activeSpace.tabs.contains { $0 === tab })
    }

    @Test("Unlocking gives the tab back to the close button")
    func unlockingRestoresClosing() {
        let session = TestSession.make().0
        let tab = session.newTab(url: url)
        tab.setLocked(true)
        tab.setLocked(false)

        #expect(session.closeTab(tab) == true)
        #expect(!session.activeSpace.tabs.contains { $0 === tab })
    }

    @Test("A sweep steps around the locked tab and closes the rest")
    func sweepsSkipTheLockedTab() {
        // The reason the lock exists: "Close Other Tabs" is one menu item away
        // from every tab you meant to keep.
        let session = TestSession.make().0
        let anchor = session.activeTab!
        let kept = session.newTab(url: url)
        let doomed = session.newTab(url: URL(string: "https://example.com/other")!)
        kept.setLocked(true)
        session.selectTab(anchor)

        session.closeOtherTabs(than: anchor)
        #expect(session.activeSpace.tabs.contains { $0 === kept })
        #expect(!session.activeSpace.tabs.contains { $0 === doomed })
    }

    @Test("Closing every tab in the space leaves the locked ones standing")
    func closeAllSkipsTheLockedTab() {
        let session = TestSession.make().0
        let kept = session.newTab(url: url)
        kept.setLocked(true)

        session.closeAllTabs(in: session.activeSpace)
        #expect(session.activeSpace.tabs.count == 1)
        #expect(session.activeSpace.tabs.first === kept)
    }

    @Test("A locked tab is kept out of the archive too")
    func lockingAlsoKeepsItInTheSidebar() {
        // The lock is the stronger promise of the two: a tab you cannot close
        // should not be quietly filed away by a timer either.
        let session = TestSession.make().0
        let tab = session.newTab(url: url)
        tab.setLocked(true)
        #expect(tab.keepsInSidebar)

        tab.backdateLastActive(by: 30 * 86_400)
        let stale = TabArchiving.candidates(
            among: [tab],
            threshold: 3_600,
            isPinned: { _ in false },
            isProviderManaged: { _ in false }
        )
        #expect(stale.isEmpty)
    }

    @Test("The lock survives a relaunch")
    func lockIsPersisted() {
        let (session, store) = TestSession.make()
        let tab = session.newTab(url: url)
        tab.setLocked(true)
        try? store.save(session.snapshot())

        let settings = Settings(defaults: UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!)
        let reopened = BrowserSession(database: nil, sessionStore: store, settings: settings)
        let restored = reopened.activeSpace.tabs.first { $0.url == url }
        #expect(restored?.isLocked == true)
    }

    @Test("A session written before locks existed restores unlocked")
    func absentLockMeansUnlocked() {
        // The safe direction to be wrong in. A lock nobody set would be a tab
        // nobody can shut, with no obvious way to find out why.
        let stored = SessionSnapshot.Tab(url: url)
        let tab = Tab(restoring: stored, identity: .standard)
        #expect(tab.isLocked == false)
    }
}

@Suite("Locking a folder against deletion")
@MainActor
struct GroupLockTests {
    @Test("A locked folder refuses to be removed")
    func lockedGroupSurvives() {
        let session = TestSession.make().0
        let group = session.createGroup(named: "Taxes")
        session.setLocked(true, for: group)

        #expect(session.removeGroup(group) == false)
        #expect(session.activeSpace.groups.contains { $0 === group })
    }

    @Test("The lock holds even when the deletion offered to take the tabs")
    func lockedGroupKeepsItsTabs() {
        let session = TestSession.make().0
        let tab = session.newTab(url: URL(string: "https://example.com/filed")!)
        let group = session.createGroup(named: "Taxes", containing: [tab])
        session.setLocked(true, for: group)

        #expect(session.removeGroup(group, closingTabs: true) == false)
        #expect(session.activeSpace.tabs.contains { $0 === tab })
    }

    @Test("Unlocking lets the folder go")
    func unlockingAllowsRemoval() {
        let session = TestSession.make().0
        let group = session.createGroup(named: "Taxes")
        session.setLocked(true, for: group)
        session.setLocked(false, for: group)

        #expect(session.removeGroup(group) == true)
        #expect(session.activeSpace.groups.isEmpty)
    }

    @Test("A folder's lock survives a relaunch")
    func groupLockIsPersisted() {
        let (session, store) = TestSession.make()
        let group = session.createGroup(named: "Taxes")
        session.setLocked(true, for: group)
        try? store.save(session.snapshot())

        let settings = Settings(defaults: UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!)
        let reopened = BrowserSession(database: nil, sessionStore: store, settings: settings)
        #expect(reopened.activeSpace.groups.first?.isLocked == true)
    }
}
