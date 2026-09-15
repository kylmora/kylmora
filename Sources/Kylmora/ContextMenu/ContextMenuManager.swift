import AppKit
import WebKit

/// Manages customization and filtering of web view context menus.
///
/// Provides user-configurable removal of clutter (Share, Services, Speech, Print, etc.),
/// dedicated "Search <Engine> for '<selection>'" actions with multiple engines,
/// and "Copy Clean Link" (stripping tracking parameters).
@MainActor
final class ContextMenuManager: NSObject {
    static let shared = ContextMenuManager()

    static let messageHandlerName = "kylmoraContextMenu"

    /// Callback to perform a web search with a given query and engine.
    var onSearch: ((String, SearchEngine) -> Void)?

    /// Callback to copy a cleaned link without tracking parameters to the pasteboard.
    var onCopyCleanLink: ((URL) -> Void)?

    /// Callback to open in Glance.
    var onOpenGlance: ((URL, GlanceOriginHint, GlanceSource) -> Void)?
    /// Callback to open in Little Arc.
    var onOpenLittleArc: ((URL) -> Void)?
    /// Callback to open in Split View.
    var onOpenSplit: ((URL) -> Void)?

    private var selections: [ObjectIdentifier: (text: String, timestamp: Date)] = [:]
    private let settings: Settings

    init(settings: Settings = .shared) {
        self.settings = settings
        super.init()
    }

    /// Injects the selection tracking script into the web view configuration.
    func install(in configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        controller.removeScriptMessageHandler(forName: Self.messageHandlerName, contentWorld: .defaultClient)
        controller.add(self, contentWorld: .defaultClient, name: Self.messageHandlerName)

        let scriptSource = """
        (function () {
          const handler = window.webkit?.messageHandlers?.\(Self.messageHandlerName);
          if (!handler) { return; }

          function notifySelection() {
            try {
              const selection = window.getSelection();
              const text = selection ? selection.toString().trim() : "";
              handler.postMessage({ selection: text.slice(0, 500) });
            } catch (e) {}
          }

          document.addEventListener('selectionchange', notifySelection, { capture: true, passive: true });
          document.addEventListener('contextmenu', notifySelection, { capture: true, passive: true });
        })();
        """

        controller.addUserScript(
            WKUserScript(
                source: scriptSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                in: .defaultClient
            )
        )
    }

    /// Records text selection for a specific web view.
    func recordSelection(_ text: String, for webView: WKWebView) {
        if text.isEmpty {
            selections.removeValue(forKey: ObjectIdentifier(webView))
        } else {
            selections[ObjectIdentifier(webView)] = (text, Date())
        }
    }

    /// The current selected text in the given web view.
    func currentSelection(in webView: WKWebView) -> String? {
        guard let entry = selections[ObjectIdentifier(webView)] else { return nil }
        // Selections are considered fresh if recorded within 10 seconds
        if Date().timeIntervalSince(entry.timestamp) < 10 {
            return entry.text
        }
        return nil
    }

    /// Extracts quoted search or lookup text from native WebKit menu items (fallback heuristic).
    func extractSelectionFromMenuItems(_ menu: NSMenu) -> String? {
        for item in menu.items {
            let title = item.title
            // Look Up “phrase” or Translate “phrase” or Search with “phrase”
            if let start = title.firstIndex(of: "“"), let end = title.firstIndex(of: "”"), start < end {
                let candidate = String(title[title.index(after: start)..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty { return candidate }
            }
            if let start = title.firstIndex(of: "\""), let end = title.lastIndex(of: "\""), start < end {
                let candidate = String(title[title.index(after: start)..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty { return candidate }
            }
        }
        return nil
    }

    /// Customizes and filters an `NSMenu` before it is presented by a web view.
    func customize(
        menu: NSMenu,
        for webView: WKWebView,
        event: NSEvent,
        pendingLink: URL?
    ) {
        // 1. Remove unwanted system or default items based on user settings
        filterMenuItems(menu)

        // 2. Add "Search for…" entries if text is selected
        enrichWithSearchItems(menu, webView: webView)

        // 3. Add "Copy Clean Link" if a link was clicked
        if let link = pendingLink, settings.contextMenuCopyCleanLink {
            addCopyCleanLinkItem(menu, url: link)
        }

        // 4. Add Link Actions (Glance, Little Arc, Split View)
        if let link = pendingLink, settings.contextMenuGlanceActions {
            addGlanceLinkActions(menu, url: link, in: webView)
        }

        // 5. Add Screenshot Actions
        if settings.contextMenuCaptureScreenshot {
            addScreenshotActions(menu)
        }

        // 6. Inspect Element
        if settings.contextMenuInspectElement {
            addInspectElementItem(menu, webView: webView)
        }

        // 7. Clean up consecutive and trailing/leading separators
        cleanSeparators(menu)
    }

    private func filterMenuItems(_ menu: NSMenu) {
        let hideShare = !settings.contextMenuShareMenu
        let hideServices = !settings.contextMenuServicesMenu
        let hideSpeech = !settings.contextMenuSpeechMenu
        let hideInspect = !settings.contextMenuInspectElement
        let hideReload = !settings.contextMenuReloadPage
        let hidePrint = !settings.contextMenuPrint
        let hiddenTitles = settings.contextMenuHiddenTitles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }

        var toRemove: [NSMenuItem] = []

        for item in menu.items {
            let titleLower = item.title.lowercased()

            if hideShare && (titleLower == "share" || titleLower.hasPrefix("share…") || titleLower.hasPrefix("share...")) {
                toRemove.append(item)
                continue
            }
            if hideServices && (titleLower == "services" || (item.submenu != nil && item.submenu == NSApp.servicesMenu)) {
                toRemove.append(item)
                continue
            }
            if hideSpeech && (titleLower == "speech" || (item.submenu?.items.contains(where: { $0.title.contains("Speaking") }) ?? false)) {
                toRemove.append(item)
                continue
            }
            if hideInspect && (titleLower == "inspect element" || item.action == Selector(("_inspectElement:"))) {
                toRemove.append(item)
                continue
            }
            if hideReload && (titleLower == "reload" || titleLower == "reload page") {
                toRemove.append(item)
                continue
            }
            if hidePrint && (titleLower.hasPrefix("print") || item.action == Selector(("print:"))) {
                toRemove.append(item)
                continue
            }
            for hidden in hiddenTitles {
                guard !hidden.isEmpty else { continue }
                if titleLower.contains(hidden) {
                    toRemove.append(item)
                    break
                }
            }
        }

        for item in toRemove {
            menu.removeItem(item)
        }
    }

    private func enrichWithSearchItems(_ menu: NSMenu, webView: WKWebView) {
        guard settings.contextMenuSearchSelection else { return }
        guard let selection = currentSelection(in: webView) ?? extractSelectionFromMenuItems(menu),
              !selection.isEmpty else { return }

        // Remove any existing WebKit search items to prevent duplicates
        let searchItemsToRemove = menu.items.filter { item in
            let lower = item.title.lowercased()
            return lower.hasPrefix("search with ") || lower.hasPrefix("search on ") || lower.hasPrefix("search google") || lower.hasPrefix("search duckduckgo")
        }
        for item in searchItemsToRemove {
            menu.removeItem(item)
        }

        let defaultEngine = settings.searchEngine
        let snippet = selection.count > 25 ? "\(selection.prefix(22))…" : selection

        let searchItem = NSMenuItem(
            title: "Search \(defaultEngine.name) for “\(snippet)”",
            action: #selector(performDefaultSearch(_:)),
            keyEquivalent: ""
        )
        searchItem.target = self
        searchItem.representedObject = (selection, defaultEngine)

        // Find best insertion index (after Look Up if present, otherwise near the top)
        var insertionIndex = 0
        if let lookUpIndex = menu.items.firstIndex(where: { $0.title.hasPrefix("Look Up") }) {
            insertionIndex = lookUpIndex + 1
        }
        menu.insertItem(searchItem, at: min(insertionIndex, menu.numberOfItems))

        // Optional submenu for searching with any other configured search engine
        if settings.contextMenuSearchSubmenu {
            let allEngines = settings.searchEngines
            if allEngines.count > 1 {
                let submenu = NSMenu(title: "Search Selection With")
                for engine in allEngines {
                    let engineItem = NSMenuItem(
                        title: "Search \(engine.name)",
                        action: #selector(performSpecificSearch(_:)),
                        keyEquivalent: ""
                    )
                    engineItem.target = self
                    engineItem.representedObject = (selection, engine)
                    submenu.addItem(engineItem)
                }

                let searchWithItem = NSMenuItem(title: "Search Selection With", action: nil, keyEquivalent: "")
                searchWithItem.submenu = submenu
                menu.insertItem(searchWithItem, at: min(insertionIndex + 1, menu.numberOfItems))
            }
        }
    }

    private func addCopyCleanLinkItem(_ menu: NSMenu, url: URL) {
        guard !menu.items.contains(where: { $0.title == "Copy Clean Link" }) else { return }

        let cleanItem = NSMenuItem(
            title: "Copy Clean Link",
            action: #selector(copyCleanLink(_:)),
            keyEquivalent: ""
        )
        cleanItem.target = self
        cleanItem.representedObject = url

        if let copyIndex = menu.items.firstIndex(where: { $0.title.lowercased() == "copy link" }) {
            menu.insertItem(cleanItem, at: copyIndex + 1)
        } else {
            menu.insertItem(cleanItem, at: min(2, menu.numberOfItems))
        }
    }

    private func addGlanceLinkActions(_ menu: NSMenu, url: URL, in webView: WKWebView) {
        if !menu.items.contains(where: { $0.title == "Open Link in Glance" }) {
            let glanceItem = NSMenuItem(
                title: "Open Link in Glance",
                action: #selector(openGlanceAction(_:)),
                keyEquivalent: ""
            )
            glanceItem.target = self
            glanceItem.representedObject = (url, webView)
            menu.insertItem(glanceItem, at: min(2, menu.numberOfItems))
        }

        if !menu.items.contains(where: { $0.title == "Open Link in Little Arc" }) {
            let littleArcItem = NSMenuItem(
                title: "Open Link in Little Arc",
                action: #selector(openLittleArcAction(_:)),
                keyEquivalent: ""
            )
            littleArcItem.target = self
            littleArcItem.representedObject = url
            menu.insertItem(littleArcItem, at: min(3, menu.numberOfItems))
        }

        if !menu.items.contains(where: { $0.title == "Open Link in Split View" }) {
            let splitItem = NSMenuItem(
                title: "Open Link in Split View",
                action: #selector(openSplitAction(_:)),
                keyEquivalent: ""
            )
            splitItem.target = self
            splitItem.representedObject = url
            menu.insertItem(splitItem, at: min(4, menu.numberOfItems))
        }
    }

    private func addScreenshotActions(_ menu: NSMenu) {
        guard !menu.items.contains(where: { $0.title == "Capture Screenshot" }) else { return }

        let screenshotSubmenu = NSMenu(title: "Capture Screenshot")
        screenshotSubmenu.addItem(NSMenuItem(
            title: "Capture Visible Area",
            action: #selector(BrowserWindowController.captureVisibleArea(_:)),
            keyEquivalent: ""
        ))
        screenshotSubmenu.addItem(NSMenuItem(
            title: "Copy Visible Area to Clipboard",
            action: #selector(BrowserWindowController.copyVisibleAreaToClipboard(_:)),
            keyEquivalent: ""
        ))
        screenshotSubmenu.addItem(.separator())
        screenshotSubmenu.addItem(NSMenuItem(
            title: "Capture Full Page",
            action: #selector(BrowserWindowController.captureFullPage(_:)),
            keyEquivalent: ""
        ))
        screenshotSubmenu.addItem(NSMenuItem(
            title: "Copy Full Page to Clipboard",
            action: #selector(BrowserWindowController.copyFullPageToClipboard(_:)),
            keyEquivalent: ""
        ))

        let screenshotItem = NSMenuItem(title: "Capture Screenshot", action: nil, keyEquivalent: "")
        screenshotItem.submenu = screenshotSubmenu
        menu.addItem(.separator())
        menu.addItem(screenshotItem)
    }

    private func addInspectElementItem(_ menu: NSMenu, webView: WKWebView) {
        if !menu.items.contains(where: { $0.title == "Inspect Element" || $0.action == Selector(("_inspectElement:")) }) {
            menu.addItem(.separator())
            let inspectItem = NSMenuItem(
                title: "Inspect Element",
                action: #selector(inspectElementAction(_:)),
                keyEquivalent: ""
            )
            inspectItem.target = self
            inspectItem.representedObject = webView
            menu.addItem(inspectItem)
        }
    }

    private func cleanSeparators(_ menu: NSMenu) {
        var toRemove: [NSMenuItem] = []
        var lastWasSeparator = true // Suppress leading separator

        for item in menu.items {
            if item.isSeparatorItem {
                if lastWasSeparator {
                    toRemove.append(item)
                }
                lastWasSeparator = true
            } else {
                lastWasSeparator = false
            }
        }

        // Suppress trailing separator
        let remaining = menu.items.filter { !toRemove.contains($0) }
        if let last = remaining.last, last.isSeparatorItem {
            toRemove.append(last)
        }

        for item in toRemove {
            menu.removeItem(item)
        }
    }

    // MARK: - Actions

    @objc private func performDefaultSearch(_ sender: NSMenuItem) {
        guard let tuple = sender.representedObject as? (String, SearchEngine) else { return }
        onSearch?(tuple.0, tuple.1)
    }

    @objc private func performSpecificSearch(_ sender: NSMenuItem) {
        guard let tuple = sender.representedObject as? (String, SearchEngine) else { return }
        onSearch?(tuple.0, tuple.1)
    }

    @objc private func copyCleanLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onCopyCleanLink?(url)
    }

    @objc private func openGlanceAction(_ sender: NSMenuItem) {
        guard let (url, webView) = sender.representedObject as? (URL, WKWebView) else { return }
        let origin = GlanceLinkMonitor.shared.currentLink(in: webView)
            .flatMap { GlanceLinkMonitor.shared.windowOrigin(of: $0, in: webView) }
        onOpenGlance?(url, origin.map { .element($0) } ?? .centre, .contextMenu)
    }

    @objc private func openLittleArcAction(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onOpenLittleArc?(url)
    }

    @objc private func openSplitAction(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onOpenSplit?(url)
    }

    @objc private func inspectElementAction(_ sender: NSMenuItem) {
        guard let webView = sender.representedObject as? WKWebView else { return }
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        if webView.responds(to: Selector(("_showInspector:"))) {
            webView.perform(Selector(("_showInspector:")), with: nil)
        } else if let inspector = (webView as AnyObject).value(forKey: "_inspector") as? AnyObject {
            if inspector.responds(to: Selector(("show"))) {
                inspector.perform(Selector(("show")))
            }
        } else {
            NSApp.sendAction(Selector(("showWebInspector:")), to: webView, from: nil)
        }
    }
}

extension ContextMenuManager: WKScriptMessageHandler {
    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        Task { @MainActor in
            guard let body = message.body as? [String: Any],
                  let text = body["selection"] as? String,
                  let webView = message.webView else { return }
            self.recordSelection(text, for: webView)
        }
    }
}
