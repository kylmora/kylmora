import AppKit
import Foundation
import Testing
@testable import Kylmora

@Suite("Multi-Select Tabs & Bulk Actions")
@MainActor
struct MultiTabTests {
    private func url(_ string: String) -> URL { URL(string: string)! }

    @Test("closeTabs closes multiple selected tabs in batch")
    func testCloseTabs() {
        let session = TestSession.make().0
        let tab1 = session.activeTab!
        let tab2 = session.newTab(url: url("https://example.com/2"))
        let tab3 = session.newTab(url: url("https://example.com/3"))
        let tab4 = session.newTab(url: url("https://example.com/4"))

        #expect(session.activeSpace.tabs.count == 4)

        session.closeTabs([tab2, tab3])

        #expect(session.activeSpace.tabs.count == 2)
        #expect(session.activeSpace.tabs.contains { $0.id == tab1.id })
        #expect(session.activeSpace.tabs.contains { $0.id == tab4.id })
        #expect(!session.activeSpace.tabs.contains { $0.id == tab2.id })
        #expect(!session.activeSpace.tabs.contains { $0.id == tab3.id })
    }

    @Test("closeAllTabs in space removes all unpinned tabs")
    func testCloseAllTabsInSpace() {
        let session = TestSession.make().0
        _ = session.newTab(url: url("https://example.com/1"))
        _ = session.newTab(url: url("https://example.com/2"))
        _ = session.newTab(url: url("https://example.com/3"))

        #expect(session.activeSpace.tabs.count == 4)

        session.closeAllTabs(in: session.activeSpace)

        #expect(session.activeSpace.tabs.isEmpty)
        #expect(session.activeTab == nil)
    }

    @Test("moveTabs moves multiple tabs to another space")
    func testMoveTabs() {
        let session = TestSession.make().0
        let space1 = session.activeSpace
        let space2 = session.addSpace(named: "Work")

        session.selectSpace(space1)
        let tab1 = session.activeTab!
        let tab2 = session.newTab(url: url("https://example.com/2"))
        let tab3 = session.newTab(url: url("https://example.com/3"))

        #expect(space1.tabs.count == 3)
        #expect(space2.tabs.count == 1) // default empty tab created for new space

        session.moveTabs([tab1, tab3], toSpace: space2)

        #expect(space1.tabs.count == 1)
        #expect(space1.tabs.first?.id == tab2.id)

        #expect(space2.tabs.count == 3)
        #expect(space2.tabs.contains { $0.url == tab1.url })
        #expect(space2.tabs.contains { $0.url == tab3.url })
    }

    @Test("duplicateTabs creates duplicates for all specified tabs")
    func testDuplicateTabs() {
        let session = TestSession.make().0
        let tab1 = session.activeTab!
        let tab2 = session.newTab(url: url("https://example.com/duplicate-me"))

        let duplicated = session.duplicateTabs([tab1, tab2])

        #expect(duplicated.count == 2)
        #expect(session.activeSpace.tabs.count == 4)
    }

    @Test("pinTabs pins all given tabs")
    func testPinTabs() {
        let session = TestSession.make().0
        let tab1 = session.activeTab!
        let tab2 = session.newTab(url: url("https://example.com/pin-me"))

        #expect(!session.isPinned(tab1))
        #expect(!session.isPinned(tab2))

        session.pinTabs([tab1, tab2])

        #expect(session.isPinned(tab1))
        #expect(session.isPinned(tab2))

        session.unpinTabs([tab1, tab2])

        #expect(!session.isPinned(tab1))
        #expect(!session.isPinned(tab2))
    }

    @Test("Sidebar selectedTabs returns matching tab models from selected row indexes")
    func testSidebarSelectedTabs() {
        let session = TestSession.make().0
        let tab1 = session.activeTab!
        let tab2 = session.newTab(url: url("https://example.com/tab2"))
        let tab3 = session.newTab(url: url("https://example.com/tab3"))

        let sidebar = SidebarViewController(session: session)
        sidebar.loadView()
        sidebar.viewDidLoad()

        // By default active tab is selected
        #expect(sidebar.selectedTabs.count == 1)
        #expect(sidebar.selectedTabs.first?.id == tab3.id)

        // Simulate multi-selection in table view
        let tableView = sidebar.tabListTableView
        tableView.selectRowIndexes(IndexSet(integersIn: 0..<session.activeSpace.tabs.count), byExtendingSelection: false)

        let selected = sidebar.selectedTabs
        #expect(selected.count == 3)
        #expect(selected.contains { $0.id == tab1.id })
        #expect(selected.contains { $0.id == tab2.id })
        #expect(selected.contains { $0.id == tab3.id })
    }
}
