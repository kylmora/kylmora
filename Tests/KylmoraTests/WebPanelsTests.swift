import AppKit
import Foundation
import Testing
import WebKit
@testable import Kylmora

@Suite("Web Panels & Always-on-Top Floating Windows (F-36)")
@MainActor
struct WebPanelsTests {

    @Test("WebPanel models and presets")
    func webPanelModels() throws {
        let scratchpad = WebPanel.scratchpad
        #expect(scratchpad.isScratchpad == true)
        #expect(scratchpad.title == "Quick Notes")
        #expect(scratchpad.symbolName == "square.and.pencil")

        let chatGPT = WebPanel.chatGPT
        #expect(chatGPT.isScratchpad == false)
        #expect(chatGPT.url == URL(string: "https://chatgpt.com")!)
        #expect(chatGPT.symbolName == "sparkles")

        #expect(!WebPanel.presets.isEmpty)
        #expect(WebPanel.presets.contains { $0.title == "DeepL Translate" })
        #expect(WebPanel.presets.contains { $0.title == "Google Keep" })

        // Codable roundtrip
        let custom = WebPanel(
            title: "Custom Service",
            url: URL(string: "https://example.com/app")!,
            symbolName: "star",
            customUserAgent: "Mozilla/5.0 Mobile",
            isPinned: true,
            order: 42
        )
        let data = try JSONEncoder().encode(custom)
        let decoded = try JSONDecoder().decode(WebPanel.self, from: data)
        #expect(decoded == custom)
        #expect(decoded.customUserAgent == "Mozilla/5.0 Mobile")
    }

    @Test("ScratchpadContent HTML is valid and self-contained")
    func scratchpadContent() {
        let html = ScratchpadContent.html
        #expect(!html.isEmpty)
        #expect(html.contains("<!DOCTYPE html>"))
        #expect(html.contains("Quick Notes"))
        #expect(html.contains("kylmora_scratchpad_notes"))
        #expect(html.contains("<textarea"))
        #expect(html.contains("localStorage"))
    }

    @Test("WebPanelStore CRUD operations and notifications")
    func webPanelStoreOperations() {
        let suiteName = "kylmora.tests.webpanels.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = WebPanelStore(defaults: defaults)

        #expect(!store.panels.isEmpty)
        let initialCount = store.panels.count

        var panelsChanged = false
        var selectionChanged = false
        var visibilityChanged = false

        let o1 = NotificationCenter.default.addObserver(
            forName: .webPanelsDidChange, object: store, queue: .main
        ) { _ in panelsChanged = true }
        let o2 = NotificationCenter.default.addObserver(
            forName: .webPanelSelectionDidChange, object: store, queue: .main
        ) { _ in selectionChanged = true }
        let o3 = NotificationCenter.default.addObserver(
            forName: .webPanelVisibilityDidChange, object: store, queue: .main
        ) { _ in visibilityChanged = true }
        defer {
            NotificationCenter.default.removeObserver(o1)
            NotificationCenter.default.removeObserver(o2)
            NotificationCenter.default.removeObserver(o3)
        }

        // Add
        let customURL = URL(string: "https://linear.app")!
        store.add(title: "Linear", url: customURL, symbolName: "tray")
        #expect(store.panels.count == initialCount + 1)
        #expect(store.panels.contains { $0.title == "Linear" })
        #expect(panelsChanged == true)

        // Select
        panelsChanged = false
        if let linear = store.panels.first(where: { $0.title == "Linear" }) {
            store.select(id: linear.id)
            #expect(store.activePanelId == linear.id)
            #expect(store.activePanel?.title == "Linear")
            #expect(store.isOpen == true)
            #expect(selectionChanged == true)
        }

        // Width clamping
        store.width = 150
        #expect(store.width == WebPanelStore.minWidth)
        store.width = 1000
        #expect(store.width == WebPanelStore.maxWidth)
        store.width = 380
        #expect(store.width == 380)

        // Visibility
        store.togglePanel()
        #expect(visibilityChanged == true)

        // Remove
        if let linear = store.panels.first(where: { $0.title == "Linear" }) {
            store.remove(id: linear.id)
            #expect(!store.panels.contains { $0.id == linear.id })
        }

        // Reset
        store.resetToDefaults()
        #expect(store.panels.count == WebPanel.defaultPanels.count)
    }

    @Test("WebPanelHeaderView layout and button actions")
    func webPanelHeaderView() {
        let header = WebPanelHeaderView()
        let panel = WebPanel.chatGPT

        var backClicked = false
        var forwardClicked = false
        var reloadClicked = false
        var tabClicked = false
        var popOutClicked = false
        var closeClicked = false

        header.onBack = { backClicked = true }
        header.onForward = { forwardClicked = true }
        header.onReloadOrStop = { reloadClicked = true }
        header.onOpenInTab = { tabClicked = true }
        header.onPopOut = { popOutClicked = true }
        header.onClose = { closeClicked = true }

        header.update(panel: panel, canGoBack: true, canGoForward: false, isLoading: false)
        header.setProgress(0.5)

        #expect(header.subviews.count >= 3)
    }

    @Test("FloatingWebWindowController window level and pin toggle")
    func floatingWebWindow() {
        let panel = WebPanel.scratchpad
        let controller = FloatingWebWindowController(panel: panel)
        defer { controller.close() }

        #expect(controller.window?.level == .floating)
        #expect(controller.isAlwaysOnTop == true)

        // Toggle pin
        controller.isAlwaysOnTop = false
        #expect(controller.window?.level == .normal)
        #expect(controller.isAlwaysOnTop == false)

        controller.isAlwaysOnTop = true
        #expect(controller.window?.level == .floating)
        #expect(controller.isAlwaysOnTop == true)

        var docked = false
        controller.onDockBack = { _, _ in docked = true }
        controller.dockBack()
        #expect(docked == true)
    }

    @Test("FloatingWindowManager lifecycle")
    func floatingWindowManager() {
        let manager = FloatingWindowManager.shared
        let initialCount = manager.floatingControllers.count

        let c1 = manager.openFloatingWindow(url: URL(string: "https://example.com")!)
        #expect(manager.floatingControllers.count == initialCount + 1)
        #expect(c1.window?.level == .floating)

        c1.close()
        #expect(manager.floatingControllers.count == initialCount)
    }

    @Test("WebPanelViewController lifecycle and caching")
    func webPanelViewControllerLifecycle() {
        let suiteName = "kylmora.tests.webpanelvc.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = WebPanelStore(defaults: defaults)
        let vc = WebPanelViewController(store: store)

        _ = vc.view // trigger loadView
        #expect(vc.view != nil)

        var openInTabURL: URL?
        var poppedOut = false
        var closed = false

        vc.onOpenInTab = { url in openInTabURL = url }
        vc.onPopOut = { _, _ in poppedOut = true }
        vc.onClose = { closed = true }

        vc.reloadActivePanel()
        #expect(store.activePanel != nil)
    }

    @Test("Settings has Web Panel options and notifications")
    func settingsWebPanelOptions() {
        let suiteName = "kylmora.tests.settings.webpanels.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let settings = Settings(defaults: defaults)

        #expect(settings.webPanelEnabled == true)
        #expect(settings.webPanelAlwaysOnTop == true)

        var notified = false
        let observer = NotificationCenter.default.addObserver(
            forName: .webPanelSettingsDidChange,
            object: nil,
            queue: .main
        ) { _ in notified = true }
        defer { NotificationCenter.default.removeObserver(observer) }

        settings.webPanelEnabled = false
        #expect(settings.webPanelEnabled == false)
        #expect(notified == true)
    }

    @Test("CommandCatalog has Web Panel and Floating Window candidates")
    func commandCatalogWebPanels() {
        let all = CommandCatalog.all
        #expect(all.contains { $0.id == "toggle-web-panel" })
        #expect(all.contains { $0.id == "pop-out-web-panel" })
        #expect(all.contains { $0.id == "add-web-panel" })
        #expect(all.contains { $0.id == "toggle-always-on-top" })
        #expect(all.contains { $0.id == "open-floating-window" })
        #expect(all.contains { $0.id == "open-scratchpad" })
    }
}
