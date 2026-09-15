import Testing
import AppKit
import WebKit
@testable import Kylmora

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

@Suite("Web Inspector & Develop Menu (F-16)")
@MainActor
struct WebInspectorTests {

    @Test("Settings has showDevelopMenu flag with notification")
    func testDevelopMenuSettings() {
        let initial = Settings.shared.showDevelopMenu
        defer { Settings.shared.showDevelopMenu = initial }

        let fired = Box(false)
        let token = NotificationCenter.default.addObserver(
            forName: .developMenuSettingDidChange,
            object: nil,
            queue: .main
        ) { _ in
            fired.value = true
        }
        defer { NotificationCenter.default.removeObserver(token) }

        Settings.shared.showDevelopMenu = !initial
        #expect(Settings.shared.showDevelopMenu == !initial)
        #expect(fired.value)
    }

    @Test("WebEnvironment creates web views with isInspectable enabled")
    func testWebEnvironmentInspectable() {
        let webView = WebEnvironment.shared.makeWebView(identity: .standard)
        #expect(webView.isInspectable)
    }

    @Test("MainMenu respects showDevelopMenu setting and contains inspector items")
    func testMainMenuDevelopMenu() {
        let initial = Settings.shared.showDevelopMenu
        defer { Settings.shared.showDevelopMenu = initial }

        let mock = MenuDelegateStub()
        Settings.shared.showDevelopMenu = true
        let menuWithDevelop = MainMenu.build(
            bookmarks: mock,
            history: mock,
            tabs: mock,
            pinnedSites: mock,
            spaces: mock
        )
        let developMenu = menuWithDevelop.items.first(where: { $0.title == "Develop" })
        #expect(developMenu != nil)

        if let submenu = developMenu?.submenu {
            let titles = submenu.items.map { $0.title }
            #expect(titles.contains("Show Web Inspector"))
            #expect(titles.contains("Show JavaScript Console"))
            #expect(titles.contains("Inspect Element"))
            #expect(titles.contains("Empty Caches\u{2026}"))
        }

        Settings.shared.showDevelopMenu = false
        let menuWithoutDevelop = MainMenu.build(
            bookmarks: mock,
            history: mock,
            tabs: mock,
            pinnedSites: mock,
            spaces: mock
        )
        let noDevelopMenu = menuWithoutDevelop.items.first(where: { $0.title == "Develop" })
        #expect(noDevelopMenu == nil)
    }

    @Test("Tab inspector actions execute safely")
    func testTabInspectorActions() {
        let tab = Tab(url: URL(string: "https://example.com")!, identity: .standard)
        // Should execute safely even without an attached view
        tab.showWebInspector()
        tab.showJavaScriptConsole()

        // And with an attached webview
        _ = tab.webView()
        tab.showWebInspector()
        tab.showJavaScriptConsole()
    }

    @Test("CommandCatalog registers developer commands")
    func testDeveloperCommandsInCatalog() {
        let commands = CommandCatalog.all
        let ids = Set(commands.map(\.id))

        #expect(ids.contains("show-web-inspector"))
        #expect(ids.contains("show-js-console"))
        #expect(ids.contains("inspect-element"))
        #expect(ids.contains("empty-caches"))

        let inspectorCmd = commands.first(where: { $0.id == "show-web-inspector" })
        #expect(inspectorCmd?.shortcut == "⌥⌘I")

        let consoleCmd = commands.first(where: { $0.id == "show-js-console" })
        #expect(consoleCmd?.shortcut == "⌥⌘C")
    }

    @Test("GlanceWebView context menu includes Inspect Element")
    func testGlanceWebViewContextMenuInspectElement() {
        let glance = GlanceWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let menu = NSMenu(title: "Context")
        menu.addItem(withTitle: "Reload", action: nil, keyEquivalent: "")

        glance.willOpenMenu(menu, with: NSEvent())

        let hasInspect = menu.items.contains(where: { $0.title == "Inspect Element" })
        #expect(hasInspect)
    }
}
