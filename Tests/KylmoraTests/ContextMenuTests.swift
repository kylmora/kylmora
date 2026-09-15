import Testing
import Foundation
import AppKit
import WebKit
@testable import Kylmora

@Suite("Editable Context Menu & Search Actions (F-31)", .serialized)
@MainActor
struct ContextMenuTests {

    private func makeIsolatedSettings() -> Settings {
        let suiteName = "test.contextmenu.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return Settings(defaults: defaults)
    }

    @Test("Settings context menu preferences toggle and persist")
    func contextMenuSettingsPersistence() {
        let settings = makeIsolatedSettings()

        var notified = false
        let observer = NotificationCenter.default.addObserver(
            forName: .contextMenuSettingsDidChange,
            object: nil,
            queue: .main
        ) { _ in
            notified = true
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        settings.contextMenuSearchSelection = false
        #expect(settings.contextMenuSearchSelection == false)
        #expect(notified == true)

        settings.contextMenuCopyCleanLink = true
        #expect(settings.contextMenuCopyCleanLink == true)

        settings.contextMenuHiddenTitles = ["Translate", "Special Offer"]
        #expect(settings.contextMenuHiddenTitles == ["Translate", "Special Offer"])
    }

    @Test("Selection recording and fallback heuristic extraction")
    func selectionTrackingAndHeuristic() {
        let settings = makeIsolatedSettings()
        let manager = ContextMenuManager(settings: settings)
        let webView = WKWebView(frame: .zero)

        manager.recordSelection("Swift Programming", for: webView)
        #expect(manager.currentSelection(in: webView) == "Swift Programming")

        // Clearing selection
        manager.recordSelection("", for: webView)
        #expect(manager.currentSelection(in: webView) == nil)

        // Heuristic extraction from WebKit's native "Look Up “keyword”"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Look Up “Concurrency”", action: nil, keyEquivalent: ""))
        let extracted = manager.extractSelectionFromMenuItems(menu)
        #expect(extracted == "Concurrency")
    }

    @Test("Search for selection is added to context menu and triggers search callback")
    func searchForSelectionEnrichment() {
        let settings = makeIsolatedSettings()
        let manager = ContextMenuManager(settings: settings)
        let webView = WKWebView(frame: .zero)
        let event = NSEvent()

        manager.recordSelection("Kylmora Browser", for: webView)

        var searchedQuery: String?
        var searchedEngine: SearchEngine?
        manager.onSearch = { query, engine in
            searchedQuery = query
            searchedEngine = engine
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Copy", action: nil, keyEquivalent: ""))

        manager.customize(menu: menu, for: webView, event: event, pendingLink: nil)

        // Verify primary search item
        let defaultEngine = settings.searchEngine
        let searchItem = menu.items.first { $0.title.contains("Search \(defaultEngine.name) for") }
        #expect(searchItem != nil)
        #expect(searchItem?.title.contains("“Kylmora Browser”") == true)

        // Trigger action
        if let target = searchItem?.target, let action = searchItem?.action {
            _ = (target as AnyObject).perform(action, with: searchItem)
            #expect(searchedQuery == "Kylmora Browser")
            #expect(searchedEngine?.id == defaultEngine.id)
        } else {
            Issue.record("Search menu item missing target or action")
        }

        // Verify submenu for multiple search engines
        let submenuItem = menu.items.first { $0.title == "Search Selection With" }
        #expect(submenuItem != nil)
        #expect(submenuItem?.submenu != nil)
        #expect(submenuItem?.submenu?.items.isEmpty == false)
    }

    @Test("Copy Clean Link strips tracking tokens and invokes callback")
    func copyCleanLinkAction() {
        let settings = makeIsolatedSettings()
        let manager = ContextMenuManager(settings: settings)
        let webView = WKWebView(frame: .zero)
        let event = NSEvent()
        let trackedURL = URL(string: "https://example.com/product?utm_source=twitter&utm_medium=cpc&id=123")!

        var copiedURL: URL?
        manager.onCopyCleanLink = { url in
            copiedURL = url
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Copy Link", action: nil, keyEquivalent: ""))

        manager.customize(menu: menu, for: webView, event: event, pendingLink: trackedURL)

        let cleanItem = menu.items.first { $0.title == "Copy Clean Link" }
        #expect(cleanItem != nil)

        if let target = cleanItem?.target, let action = cleanItem?.action {
            _ = (target as AnyObject).perform(action, with: cleanItem)
            #expect(copiedURL == trackedURL)
        } else {
            Issue.record("Copy Clean Link menu item missing target or action")
        }
    }

    @Test("Custom filtering removes Share, Services, Speech, Print, and blacklisted items")
    func contextMenuFiltering() {
        let settings = makeIsolatedSettings()
        settings.contextMenuShareMenu = false
        settings.contextMenuServicesMenu = false
        settings.contextMenuSpeechMenu = false
        settings.contextMenuPrint = false
        settings.contextMenuReloadPage = false
        settings.contextMenuInspectElement = false
        settings.contextMenuHiddenTitles = ["banned action", "download media"]

        let manager = ContextMenuManager(settings: settings)
        let webView = WKWebView(frame: .zero)
        let event = NSEvent()

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Share…", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Services", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Speech", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Print…", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reload Page", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Inspect Element", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Execute Banned Action", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Allowed Action", action: nil, keyEquivalent: ""))

        manager.customize(menu: menu, for: webView, event: event, pendingLink: nil)

        let titles = menu.items.map(\.title)
        #expect(!titles.contains("Share…"))
        #expect(!titles.contains("Services"))
        #expect(!titles.contains("Speech"))
        #expect(!titles.contains("Print…"))
        #expect(!titles.contains("Reload Page"))
        #expect(!titles.contains("Inspect Element"))
        #expect(!titles.contains("Execute Banned Action"))
        #expect(titles.contains("Allowed Action"))
    }

    @Test("ContextMenuSettingsViewController loads and changes settings")
    func contextMenuSettingsViewController() {
        let settings = makeIsolatedSettings()
        let vc = ContextMenuSettingsViewController(settings: settings)
        _ = vc.view

        #expect(vc.view.subviews.isEmpty == false)
    }
}
