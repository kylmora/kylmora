import AppKit
import Foundation
import Testing
@testable import Kylmora

private final class MenuStub: NSObject, NSMenuDelegate {}

@Suite("Tab bar above the page")
@MainActor
struct TabStripTests {
    @Test("The strip shows one cell per tab, marks the active one, and reports clicks")
    func cells() {
        let strip = TabStripView(frame: NSRect(x: 0, y: 0, width: 800, height: TabStripView.height))
        let tabs = [
            Tab(url: URL(string: "https://a.example/")!, identity: .standard),
            Tab(url: URL(string: "https://b.example/")!, identity: .standard),
            Tab(url: URL(string: "https://c.example/")!, identity: .standard)
        ]
        strip.show(tabs, activeID: tabs[1].id, isPrivate: false)
        #expect(strip.cells.count == 3)
        #expect(strip.cells.map(\.isActive) == [false, true, false])
        #expect(strip.cells[0].accessibilityLabel() == "a.example")

        var selected: Tab?
        var closed: Tab?
        strip.onSelect = { selected = $0 }
        strip.onClose = { closed = $0 }
        strip.cells[2].onSelect?()
        strip.cells[0].onClose?()
        #expect(selected === tabs[2])
        #expect(closed === tabs[0])

        strip.refresh(activeID: tabs[2].id)
        #expect(strip.cells.map(\.isActive) == [false, false, true])
        strip.show([], activeID: nil, isPrivate: false)
        #expect(strip.cells.isEmpty)
    }

    @Test("The container gives the strip its height only while it is shown")
    func containerHeight() {
        let container = ContentContainerView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        container.layoutSubtreeIfNeeded()
        #expect(container.tabStrip.isHidden)
        #expect(container.tabStrip.frame.height == 0)
        container.showsTabStrip = true
        container.layoutSubtreeIfNeeded()
        #expect(!container.tabStrip.isHidden)
        #expect(container.tabStrip.frame.height == TabStripView.height)
        container.showsTabStrip = false
        container.layoutSubtreeIfNeeded()
        #expect(container.tabStrip.frame.height == 0)
    }

    @Test("The setting announces itself and is reachable from the menu, shortcuts and palette")
    func wiring() {
        let settings = Settings.shared
        let before = settings.showsTabStrip
        defer { settings.showsTabStrip = before }
        var notified = 0
        let token = NotificationCenter.default.addObserver(forName: .tabStripDidChange, object: nil, queue: nil) { _ in notified += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        settings.showsTabStrip = !before
        settings.showsTabStrip = !before
        #expect(notified == 1)

        let stub = MenuStub()
        let menu = MainMenu.build(bookmarks: stub, history: stub, tabs: stub, pinnedSites: stub, spaces: stub)
        var found: NSMenuItem?
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if item.title == "Show Tab Bar" { found = item }
                if let sub = item.submenu { walk(sub) }
            }
        }
        walk(menu)
        #expect(found?.keyEquivalent == "b")
        #expect(found?.keyEquivalentModifierMask == [.command, .control])
        #expect(CommandCatalog.all.contains { $0.id == "toggle-tab-bar" })
        let definition = ShortcutManager.shared.definition(for: "toggle-tab-bar")
        #expect(definition != nil)
        if let definition { #expect(BrowserWindowController.instancesRespond(to: definition.selector)) }
    }
}
