import AppKit
import Foundation
import Testing
@testable import Kylmora

private final class MenuStub: NSObject, NSMenuDelegate {}

@Suite("Tab housekeeping, auto reload, notes, Quick Look and What's New")
@MainActor
struct SmallFeaturesTests {
    private func url(_ s: String) -> URL { URL(string: s)! }

    @Test("Closing duplicates keeps one tab per address, the active one first, and spares locks and pins")
    func duplicates() {
        let (session, _) = TestSession.make()
        let space = session.activeSpace
        for tab in space.tabs { _ = session.closeTab(tab) }
        let a1 = session.newTab(url: url("https://a.example/"))
        let b = session.newTab(url: url("https://b.example/"))
        let a2 = session.newTab(url: url("https://a.example/"))
        let a3 = session.newTab(url: url("https://a.example/"))
        a3.setLocked(true)
        session.selectTab(a2)

        #expect(session.closeDuplicateTabs() == 1)
        let remaining = space.tabs
        #expect(remaining.contains { $0 === a2 }, "the active copy is the one kept")
        #expect(!remaining.contains { $0 === a1 })
        #expect(remaining.contains { $0 === a3 }, "locked tabs stay")
        #expect(remaining.contains { $0 === b })
        #expect(session.closeDuplicateTabs() == 0)
    }

    @Test("Sorting reorders by title, domain or last use without losing a tab")
    func sorting() {
        let (session, _) = TestSession.make()
        let space = session.activeSpace
        for tab in space.tabs { _ = session.closeTab(tab) }
        let zeta = session.newTab(url: url("https://zeta.example/"))
        let alpha = session.newTab(url: url("https://www.alpha.example/"))
        let mid = session.newTab(url: url("https://mid.example/"))
        session.rename(zeta, to: "Apples")
        session.rename(alpha, to: "Zebras")
        session.rename(mid, to: "Mangoes")

        session.sortTabs(by: .domain)
        #expect(space.tabs.map { $0.displayURL.host() } == ["www.alpha.example", "mid.example", "zeta.example"])
        session.sortTabs(by: .title)
        #expect(space.tabs.map(\.displayTitle) == ["Apples", "Mangoes", "Zebras"])
        alpha.backdateLastActive(by: 3600)
        mid.backdateLastActive(by: 60)
        session.sortTabs(by: .lastUsed)
        #expect(space.tabs.first === zeta)
        #expect(space.tabs.last === alpha)
        #expect(space.tabs.count == 3)
        #expect(!space.replaceTabs(with: [zeta]), "a sort can never drop a tab")
    }

    @Test("Auto reload and a note stay with the tab, through the session file")
    func autoReloadAndNote() {
        let tab = Tab(url: url("https://dash.example/"), identity: .standard)
        #expect(tab.autoReloadInterval == nil)
        tab.setAutoReload(every: 30)
        tab.setNote("  Standup dashboard  ")
        #expect(tab.autoReloadInterval == 30)
        #expect(tab.note == "Standup dashboard")
        let snapshot = tab.snapshot()
        #expect(snapshot.autoReloadSeconds == 30)
        #expect(snapshot.note == "Standup dashboard")
        let restored = Tab(restoring: snapshot, identity: .standard)
        #expect(restored.autoReloadInterval == 30)
        #expect(restored.note == "Standup dashboard")
        tab.setAutoReload(every: nil)
        tab.setNote("")
        #expect(tab.snapshot().autoReloadSeconds == nil)
        #expect(tab.snapshot().note == nil)
        #expect(SidebarViewController.autoReloadTitle(30) == "Every 30 seconds")
        #expect(SidebarViewController.autoReloadTitle(60) == "Every 1 minute")
        #expect(SidebarViewController.autoReloadTitle(300) == "Every 5 minutes")
    }

    @Test("What's New shows once after an update, never on a first launch")
    func whatsNew() {
        #expect(!WhatsNew.shouldShow(previous: nil, current: "1.2.0"))
        #expect(!WhatsNew.shouldShow(previous: "1.2.0", current: "1.2.0"))
        #expect(!WhatsNew.shouldShow(previous: "1.2", current: "1.2.0"), "the same version written two ways")
        #expect(WhatsNew.shouldShow(previous: "1.1.0", current: "1.2.0"))
        #expect(!WhatsNew.shouldShow(previous: "1.1.0", current: "0"), "a dev build has no version to announce")
        #expect(WhatsNew.releaseNotesURL(for: "1.2.0").absoluteString == "https://github.com/kylmora/kylmora/releases/tag/v1.2.0")

        let settings = Settings(defaults: UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!)
        #expect(settings.lastLaunchedVersion == nil)
        WhatsNew.presentIfNeeded(on: nil, settings: settings)
        #expect(settings.lastLaunchedVersion == AppInfo.version, "the first launch records the version without a sheet")
    }

    @Test("The File menu carries Close Duplicate Tabs and Sort Tabs By, and the palette knows them")
    func menus() {
        let stub = MenuStub()
        let menu = MainMenu.build(bookmarks: stub, history: stub, tabs: stub, pinnedSites: stub, spaces: stub)
        let file = menu.items.first { $0.title == "File" }?.submenu
        #expect(file?.items.contains { $0.title == "Close Duplicate Tabs" } == true)
        let sort = file?.items.first { $0.title == "Sort Tabs By" }?.submenu
        #expect(sort?.items.map(\.title) == ["Title", "Domain", "Last Used"])
        for id in ["close-duplicate-tabs", "sort-tabs-title", "sort-tabs-domain", "sort-tabs-last-used"] {
            #expect(CommandCatalog.all.contains { $0.id == id })
        }
    }

    @Test("The downloads table answers the space bar with Quick Look")
    func quickLook() {
        let table = DownloadTableView()
        var asked = 0
        table.onQuickLook = { asked += 1 }
        let space = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
        table.keyDown(with: space)
        #expect(asked == 1)
    }
}
