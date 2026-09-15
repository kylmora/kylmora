import AppKit
import Foundation
import Testing
@testable import Kylmora

@Suite("Recently Closed Tabs and Windows")
@MainActor
struct RecentlyClosedTests {
    private func url(_ string: String) -> URL { URL(string: string)! }

    @Test("Closing a tab records it in closedTabs and recentClosedTabs order")
    func recordAndRecentOrder() {
        let (session, _) = TestSession.make()
        let tab1 = session.newTab(url: url("https://first.example"))
        let tab2 = session.newTab(url: url("https://second.example"))

        session.closeTab(tab1)
        session.closeTab(tab2)

        #expect(session.closedTabs.count == 2)
        #expect(session.recentClosedTabs.count == 2)
        // Most recent first in recentClosedTabs
        #expect(session.recentClosedTabs[0].url.absoluteString == "https://second.example")
        #expect(session.recentClosedTabs[1].url.absoluteString == "https://first.example")
    }

    @Test("Closed tabs list enforces limit of 25")
    func closedTabsLimitEnforced() {
        let (session, _) = TestSession.make()
        for i in 1...30 {
            let tab = session.newTab(url: url("https://test\(i).example"))
            session.closeTab(tab)
        }

        #expect(session.closedTabs.count == BrowserSession.closedTabLimit)
        #expect(session.closedTabs.count == 25)
        #expect(session.recentClosedTabs.first?.url.absoluteString == "https://test30.example")
        #expect(session.recentClosedTabs.last?.url.absoluteString == "https://test6.example")
    }

    @Test("Reopening closed tab by ID restores exact tab and preserves other closed tabs")
    func reopenClosedTabByID() {
        let (session, _) = TestSession.make()
        let tabA = session.newTab(url: url("https://a.example"))
        let tabB = session.newTab(url: url("https://b.example"))
        let tabC = session.newTab(url: url("https://c.example"))

        session.closeTab(tabA)
        session.closeTab(tabB)
        session.closeTab(tabC)

        let target = session.recentClosedTabs.first { $0.url.absoluteString == "https://b.example" }!
        let restored = session.reopenClosedTab(id: target.id)

        #expect(restored != nil)
        #expect(restored?.url.absoluteString == "https://b.example")
        #expect(session.activeTab === restored)
        #expect(session.closedTabs.count == 2)
        #expect(!session.closedTabs.contains { $0.id == target.id })
    }

    @Test("Batch closeTabs records a ClosedWindow")
    func batchCloseRecordsWindow() {
        let (session, _) = TestSession.make()
        let t1 = session.newTab(url: url("https://alpha.example"))
        let t2 = session.newTab(url: url("https://beta.example"))
        let t3 = session.newTab(url: url("https://gamma.example"))

        session.closeTabs([t1, t2, t3])

        #expect(session.closedWindows.count == 1)
        let window = session.closedWindows[0]
        #expect(window.tabCount == 3)
        #expect(window.summaryTitle.contains("3 tabs"))
    }

    @Test("closeAllTabs records a ClosedWindow and can restore entire window")
    func closeAllTabsAndRestoreWindow() {
        let (session, _) = TestSession.make()
        let space = session.activeSpace
        _ = session.newTab(url: url("https://site1.example"))
        _ = session.newTab(url: url("https://site2.example"))
        _ = session.newTab(url: url("https://site3.example"))

        let initialTabCount = space.tabs.count
        #expect(initialTabCount >= 3)

        session.closeAllTabs(in: space)
        #expect(session.closedWindows.count == 1)

        let restoredTabs = session.reopenClosedWindow()
        #expect(restoredTabs.count == initialTabCount)
        #expect(session.closedWindows.isEmpty)
        #expect(session.activeTab === restoredTabs.last)
    }

    @Test("Closed windows list enforces limit of 15")
    func closedWindowsLimitEnforced() {
        let (session, _) = TestSession.make()
        let space = session.activeSpace

        for _ in 1...20 {
            let t1 = session.newTab(url: url("https://one.example"))
            let t2 = session.newTab(url: url("https://two.example"))
            session.closeTabs([t1, t2])
        }

        #expect(session.closedWindows.count == BrowserSession.closedWindowLimit)
        #expect(session.closedWindows.count == 15)
    }

    @Test("Reopening closed window by ID restores target window")
    func reopenClosedWindowByID() {
        let (session, _) = TestSession.make()
        let t1 = session.newTab(url: url("https://win1-a.example"))
        let t2 = session.newTab(url: url("https://win1-b.example"))
        session.closeTabs([t1, t2])

        let t3 = session.newTab(url: url("https://win2-a.example"))
        let t4 = session.newTab(url: url("https://win2-b.example"))
        session.closeTabs([t3, t4])

        #expect(session.closedWindows.count == 2)
        let firstWindowID = session.closedWindows[0].id

        let restored = session.reopenClosedWindow(id: firstWindowID)
        #expect(restored.count == 2)
        #expect(restored.contains { $0.url.absoluteString == "https://win1-a.example" })
        #expect(session.closedWindows.count == 1)
    }

    @Test("Private space tabs are never recorded in closedTabs or closedWindows")
    func privateSpaceNotRecorded() {
        let (session, _) = TestSession.make()
        let privateSpace = session.addSpace(named: "Secret", isPrivate: true)
        let tab1 = session.newTab(url: url("https://private1.example"))
        let tab2 = session.newTab(url: url("https://private2.example"))

        session.closeTabs([tab1, tab2])
        session.closeAllTabs(in: privateSpace)

        #expect(session.closedTabs.isEmpty)
        #expect(session.closedWindows.isEmpty)
        #expect(!session.canReopenClosedTab)
    }

    @Test("reopenAllClosedTabs restores both closed windows and tabs")
    func reopenAllClosedTabsAndWindows() {
        let (session, _) = TestSession.make()
        let t1 = session.newTab(url: url("https://tab1.example"))
        session.closeTab(t1)

        let t2 = session.newTab(url: url("https://tab2.example"))
        let t3 = session.newTab(url: url("https://tab3.example"))
        session.closeTabs([t2, t3])

        #expect(!session.closedTabs.isEmpty)
        #expect(!session.closedWindows.isEmpty)

        let allRestored = session.reopenAllClosedTabs()
        #expect(allRestored.count >= 3)
        #expect(session.closedTabs.isEmpty)
        #expect(session.closedWindows.isEmpty)
    }

    @Test("clearRecentlyClosed empties both closedTabs and closedWindows")
    func clearRecentlyClosedEmptiesLists() {
        let (session, _) = TestSession.make()
        let t1 = session.newTab(url: url("https://clear1.example"))
        session.closeTab(t1)

        let t2 = session.newTab(url: url("https://clear2.example"))
        let t3 = session.newTab(url: url("https://clear3.example"))
        session.closeTabs([t2, t3])

        session.clearRecentlyClosed()
        #expect(session.closedTabs.isEmpty)
        #expect(session.closedWindows.isEmpty)
        #expect(!session.canReopenClosedTab)
    }

    @Test("StoredItemsMenu builds Recently Closed submenu correctly")
    func storedItemsMenuRecentlyClosed() {
        let (session, _) = TestSession.make()
        let historyMenuDelegate = StoredItemsMenu(kind: .history, session: session)
        let menu = NSMenu(title: "History")
        historyMenuDelegate.menuNeedsUpdate(menu)

        // Find Recently Closed menu item
        let recentlyClosedItem = menu.items.first { $0.title == "Recently Closed" }
        #expect(recentlyClosedItem != nil)
        #expect(recentlyClosedItem?.submenu != nil)

        let submenu = recentlyClosedItem!.submenu!
        // When empty:
        #expect(submenu.items.contains { $0.title == "No Recently Closed Tabs or Windows" })

        // Now close tabs and windows
        let t1 = session.newTab(url: url("https://example.com/test"))
        session.closeTab(t1)
        let t2 = session.newTab(url: url("https://site-a.com"))
        let t3 = session.newTab(url: url("https://site-b.com"))
        session.closeTabs([t2, t3])

        // Trigger submenu update
        historyMenuDelegate.menuNeedsUpdate(submenu)

        #expect(!submenu.items.contains { $0.title == "No Recently Closed Tabs or Windows" })
        #expect(submenu.items.contains { $0.title == "Reopen Last Closed Tab" })
        #expect(submenu.items.contains { $0.title == "Closed Windows" })
        #expect(submenu.items.contains { $0.title == "Closed Tabs" })
        #expect(submenu.items.contains { $0.title == "Reopen All Closed Tabs" })
        #expect(submenu.items.contains { $0.title == "Clear Recently Closed" })
    }

    @Test("Command catalog includes reopen-all-closed-tabs and clear-recently-closed")
    func commandCatalogEntries() {
        let commands = CommandCatalog.all
        #expect(commands.contains { $0.id == "reopen-all-closed-tabs" })
        #expect(commands.contains { $0.id == "clear-recently-closed" })
    }
}
