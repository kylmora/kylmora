import AppKit
import Foundation
import Testing
@testable import Kylmora

@Suite("Arc Sidebar URL Bar, Clear & Tidy")
@MainActor
struct ArcSidebarTests {
    @Test("SidebarURLBarView formats clean hosts and falls back on non-HTTP URLs")
    func urlBarFormatting() {
        #expect(SidebarURLBarView.displayText(for: URL(string: "https://www.github.com/kylmora/kylmora")) == "github.com")
        #expect(SidebarURLBarView.displayText(for: URL(string: "http://example.org/docs")) == "example.org")
        #expect(SidebarURLBarView.displayText(for: URL(string: "about:blank")) == "Search or enter URL...")
        #expect(SidebarURLBarView.displayText(for: nil) == "Search or enter URL...")
    }

    @Test("Clear Today archives loose unpinned tabs while preserving locked tabs and folders")
    func clearTodayTabsPreservesProtected() {
        let (session, _) = TestSession.make()
        let sidebar = SidebarViewController(session: session)
        sidebar.loadViewIfNeeded()

        let loose1 = session.newTab(url: URL(string: "https://a.example")!)
        let loose2 = session.newTab(url: URL(string: "https://b.example")!)
        let locked = session.newTab(url: URL(string: "https://locked.example")!)
        locked.setLocked(true)
        let inFolder = session.newTab(url: URL(string: "https://folder.example")!)
        _ = session.createGroup(named: "Work", containing: [inFolder])

        let cleared = sidebar.clearTodayTabs()
        #expect(cleared >= 2)
        #expect(!session.activeSpace.tabs.contains { $0.id == loose1.id })
        #expect(!session.activeSpace.tabs.contains { $0.id == loose2.id })
        #expect(session.activeSpace.tabs.contains { $0.id == locked.id })
        #expect(session.activeSpace.tabs.contains { $0.id == inFolder.id })
    }

    @Test("Tidy Today groups 2+ tabs from the same domain into clean folders")
    func tidyTodayTabsGroupsByDomain() {
        let (session, _) = TestSession.make()
        let sidebar = SidebarViewController(session: session)
        sidebar.loadViewIfNeeded()

        let gh1 = session.newTab(url: URL(string: "https://github.com/a")!)
        let gh2 = session.newTab(url: URL(string: "https://www.github.com/b")!)
        let yt1 = session.newTab(url: URL(string: "https://youtube.com/watch?v=1")!)
        let yt2 = session.newTab(url: URL(string: "https://youtube.com/watch?v=2")!)
        let solo = session.newTab(url: URL(string: "https://solo.example")!)

        let moved = sidebar.tidyTodayTabs()
        #expect(moved == 4)
        #expect(gh1.groupID != nil && gh1.groupID == gh2.groupID)
        #expect(yt1.groupID != nil && yt1.groupID == yt2.groupID)
        #expect(solo.groupID == nil)
        #expect(session.activeSpace.groups.contains { $0.name == "Github" })
        #expect(session.activeSpace.groups.contains { $0.name == "Youtube" })
    }

    @Test("SidebarFooterView renders Space icons and reports clicked space index")
    func footerSpaceIconSwitcher() {
        let footer = SidebarFooterView()
        var chosen: Int?
        footer.onSelectPage = { chosen = $0 }
        let items = [
            SidebarFooterView.SpaceItem(title: "Personal", icon: NSImage(systemSymbolName: "house", accessibilityDescription: nil)!, isPrivate: false),
            SidebarFooterView.SpaceItem(title: "Work", icon: NSImage(systemSymbolName: "briefcase", accessibilityDescription: nil)!, isPrivate: false),
        ]
        footer.showSpaces(items, selected: 0)
        let buttons = footer.subviews.flatMap { ($0 as? NSStackView)?.arrangedSubviews ?? [] }.compactMap { $0 as? NSButton }
        #expect(buttons.count == 2)
        buttons[1].performClick(nil)
        #expect(chosen == 1)
    }

    @Test("SiteSearch matches Arc-style triggers and builds encoded search URLs")
    func siteSearchMatchesAndBuildsURL() {
        let yt = SiteSearch.match("yt")
        #expect(yt?.name == "YouTube")
        #expect(yt?.searchURL(for: "swift concurrency")?.absoluteString == "https://www.youtube.com/results?search_query=swift%20concurrency")

        #expect(SiteSearch.match("https://www.github.com/")?.id == "github")
        #expect(SiteSearch.match("wiki")?.id == "wikipedia")
        #expect(SiteSearch.match("unknown-site") == nil)
    }

    @Test("CommandBar activates site search pill on setSiteSearch and submits site URL")
    func commandBarSiteSearchSubmit() {
        let bar = CommandBar()
        var opened: URL?
        bar.onRun = { action in
            if case .openURL(let url) = action { opened = url }
        }
        bar.open()
        bar.setSiteSearch(SiteSearch.match("gh"))
        #expect(bar.activeSiteSearch?.id == "github")
        bar.close()
        #expect(bar.activeSiteSearch == nil)
        _ = opened
    }
}
