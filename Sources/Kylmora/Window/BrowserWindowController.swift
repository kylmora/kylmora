import AppKit
import Combine
import WebKit

/// The one and only browser window.
///
/// Spaces and tabs switch inside it; the application never opens a second
/// browser window to change context.
@MainActor
final class BrowserWindowController: NSWindowController, NSMenuItemValidation {
    private(set) var session: BrowserSession
    private let splitViewController = KylmoraSplitViewController()
    /// The split view plus the rim over it.
    private let root = KylmoraRootViewController()
    private let sidebar: SidebarViewController
    private let content: WebContentViewController
    /// Cmd-L. Installed over the page, so the panel floats above the content
    /// and not above the sidebar.
    private let commandBar = CommandBar()
    /// Held while shown so it is not deallocated mid-display.
    private var siteSettingsPopover: NSPopover?
    private var shieldPopover: NSPopover?
    /// The small windows links from other apps open in. Owned here because this
    /// is the browser window they belong to, and it outlives every one of them.
    private lazy var littleArcs = LittleArcCoordinator(session: session)
    /// Compact mode. Implicitly unwrapped because it needs `self` as its
    /// sidebar slot, which is not available until after `super.init`.
    private var compact: CompactChrome!
    private let gestures = SidebarSwipeController()
    /// Remembered across a detach: a sidebar that is out of the split view has
    /// no width left to read.
    private var lastSidebarWidth = Style.Metrics.sidebarWidth
    private var sidebarCollapseObservation: NSKeyValueObservation?
    private var isSidebarCollapsed = false
    private var isTopBarHovered = false
    private var isWindowFullScreen = false
    /// Whether compact mode was on before full screen borrowed it to hide
    /// the chrome for the space in front. Nil while it has not been borrowed.
    private var compactWasEnabledBeforeFullScreen: Bool?
    /// Compact mode has put the window's lights on the page's top bar, which
    /// then has to make room for them.
    private var lightsRideOnTopBar = false
    /// The top bar's bookmark button, whose glyph follows the page.
    private weak var bookmarkButton: IconButton?
    private var cancellables: Set<AnyCancellable> = []

    init(session: BrowserSession) {
        self.session = session
        self.sidebar = SidebarViewController(session: session)
        self.content = WebContentViewController(session: session)

        let window = BrowserWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Kylmora"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 720, height: 460)
        // System window tabs would sit alongside our own tabs and mean something
        // different. One window means one tab concept.
        window.tabbingMode = .disallowed

        super.init(window: window)

        buildSplitView()
        wireTopBar()
        wireCommandBar()
        root.host(splitViewController)
        window.contentViewController = root
        // While the command bar is open the page may not take the keyboard:
        // a page that autofocuses a field would otherwise swallow the address
        // being typed (see `BrowserWindow`).
        window.focusPolicy = { [weak self] responder in
            guard let self, self.commandBar.isOpen else { return true }
            return !Self.isWebContent(responder)
        }

        compact = CompactChrome(
            slot: self,
            contentView: content.view,
            toolbarView: content.topBar,
            toolbarTopConstraint: content.topBarTopConstraint,
            window: window,
            configuration: Settings.shared.compactModeConfiguration
        )
        compact.onTrafficLightHostChange = { [weak self] host in
            self?.lightsRideOnTopBar = host == .toolbar
            self?.updateTrafficLights()
        }
        // Restoring a compact window must not play the entry animation, or
        // every launch starts with the sidebar sliding away.
        compact.setEnabled(Settings.shared.compactModeEnabled, animated: false)
        // The sidebar already follows the session for this; it hands the
        // space on so the strip around the page card and the rim around the
        // window match it exactly rather than being computed a second time
        // from the same model.
        sidebar.onShownSpaceChange = { [weak self] space, duration in
            self?.content.showSpaceWash(space.wash(for: space.activeTab), animatedOver: duration)
            self?.content.showSpaceGradient(space.washGradient(for: space.activeTab), animatedOver: duration)
            self?.root.border.show(space.effectiveBorder, animatedOver: duration)
            self?.applyLook(of: space)
        }
        sidebar.onShownSpaceBlend = { [weak self] space, fraction in
            self?.content.blendSpaceWash(toward: space?.wash(for: space?.activeTab), fraction: fraction)
            self?.root.border.blend(toward: space?.effectiveBorder, fraction: fraction)
        }
        sidebar.onWashChange = { [weak self] wash in
            self?.content.spaceWash = wash
        }
        sidebar.onGradientChange = { [weak self] gradient in
            self?.content.spaceGradient = gradient
        }
        content.spaceWash = session.activeSpace.wash(for: session.activeSpace.activeTab)
        content.spaceGradient = session.activeSpace.washGradient(for: session.activeSpace.activeTab)
        root.border.show(session.activeSpace.effectiveBorder, animatedOver: 0)
        applyLook(of: session.activeSpace)

        content.onOpenBookmark = { [weak self] url in self?.open(stored: url) }
        GlanceLinkMonitor.shared.onOpenLittleArc = { [weak self] url in
            guard let self else { return }
            self.littleArcs.open(url: url, in: self.externalLinkSpace)
        }
        content.topBar.onHoverChanged = { [weak self] isHovered in
            self?.isTopBarHovered = isHovered
            self?.updateTrafficLights()
        }
        gestures.delegate = self
        gestures.install()
        observeWindowState()
        observeTitle()

        // Size the window last: assigning `contentViewController` above resizes
        // it to the view's fitting size, so restoring or picking a frame any
        // earlier is immediately clobbered. Remember whatever size the user
        // settles on across launches; the very first launch has nothing saved,
        // and the fitting size is cramped, so open large -- most of the screen,
        // centred -- instead.
        if !window.setFrameUsingName("KylmoraMainWindow") {
            if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
                let width = min(visible.width - 160, 1600)
                let height = min(visible.height - 120, 1040)
                window.setContentSize(NSSize(width: width, height: height))
            }
            window.center()
        }
        window.setFrameAutosaveName("KylmoraMainWindow")
    }

    required init?(coder: NSCoder) {
        fatalError("BrowserWindowController is created in code only")
    }

    private func buildSplitView() {
        // Plain, not `sidebarWithViewController:`. See SidebarViewController.
        let sidebarItem = NSSplitViewItem(viewController: sidebar)
        // Measured to match the reference design.
        sidebarItem.minimumThickness = Style.Metrics.sidebarMinWidth
        sidebarItem.maximumThickness = Style.Metrics.sidebarMaxWidth
        sidebarItem.canCollapse = true
        sidebarItem.holdingPriority = .defaultLow

        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 400

        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(contentItem)
        splitViewController.splitView.autosaveName = "KylmoraSidebar"

        // Hiding the sidebar leaves the traffic lights on the page's top bar,
        // because the sidebar is what normally hosts them. The bar has to
        // step aside for them or its first button sits underneath the close
        // button.
        sidebarCollapseObservation = sidebarItem.observe(\.isCollapsed, options: [.initial, .new]) { _, change in
            // Only the new value crosses into the closure: the split view item
            // itself is main-actor state and sending it would be a data race.
            let isCollapsed = change.newValue ?? false
            MainActor.assumeIsolated { [weak self] in
                self?.isSidebarCollapsed = isCollapsed
                self?.content.cardLeadingInset = isCollapsed
                    ? Style.Metrics.elementSeparation
                    : 0
                self?.updateTrafficLights()
            }
        }
        // The autosaved position wins over the item's thickness bounds, so the
        // measured width has to be asked for explicitly.
        splitViewController.splitView.setPosition(Style.Metrics.sidebarWidth, ofDividerAt: 0)
    }

    /// The top bar repeats commands the menu already owns, so it calls the same
    /// methods rather than reaching into the session a second way.
    private func wireTopBar() {
        let bar = content.topBar
        bar.sidebarToggle.setClickHandler { [weak self] in
            self?.toggleKylmoraSidebar(nil)
        }
        bar.backButton.setClickHandler { [weak self] in self?.goBack(nil) }
        bar.forwardButton.setClickHandler { [weak self] in self?.goForward(nil) }
        bar.reloadButton.setClickHandler { [weak self] in
            guard let tab = self?.session.activeTab else { return }
            if tab.isLoading { tab.stopLoading() } else { tab.reload() }
        }
        bar.addressField.onNavigate = { [weak self] text in
            guard let self,
                  let url = URLResolver.resolve(
                    text,
                    using: Settings.shared.searchEngine(isPrivate: self.session.activeSpace.isPrivate)
                  )
            else { return }
            if let tab = self.session.activeTab {
                tab.load(url)
            } else {
                self.session.newTab(url: url)
            }
        }
        bar.zoomControl.zoomOut.setClickHandler { [weak self] in self?.stepZoom(by: -1) }
        bar.zoomControl.zoomIn.setClickHandler { [weak self] in self?.stepZoom(by: 1) }
        bar.zoomControl.onReset = { [weak self] in self?.resetZoom() }
        var actions = [
            TopBarAction(symbolName: "checkmark.shield.fill", label: "Shield") { [weak self] in
                self?.showShieldPopover()
            },
            TopBarAction(symbolName: "gearshape.fill", label: "Site Settings") { [weak self] in
                self?.showSiteSettings()
            },
            TopBarAction(symbolName: "square.and.arrow.up", label: "Share") { [weak self] in
                self?.shareCurrentPage()
            },
            TopBarAction(symbolName: "magnifyingglass", label: "Find in Page") { [weak self] in
                self?.performFind(nil)
            },
            TopBarAction(symbolName: "bookmark", label: "Add Bookmark") { [weak self] in
                self?.toggleBookmark(nil)
            },
            TopBarAction(symbolName: "macwindow", label: "Page Menu") { [weak self] in
                self?.showPageMenu()
            }
        ]
        if #available(macOS 15.4, *) {
            actions.append(TopBarAction(symbolName: "puzzlepiece.extension", label: "Extensions") { [weak self] in
                self?.showExtensionsMenu()
            })
        }
        bar.setActions(actions)
        bookmarkButton = bar.actionButton(labelled: "Add Bookmark") as? IconButton
        if #available(macOS 15.4, *) {
            ExtensionManager.shared.popupAnchor = { [weak bar] in bar?.actionButton(labelled: "Extensions") }
        }
    }

    /// The page menu off the toolbar: the handful of page-level choices Kylmora
    /// actually has. Focus Mode and Translate are deliberately absent -- there
    /// is nothing behind them yet, and a dead menu item is worse than none.
    private func showPageMenu() {
        guard let tab = session.activeTab, let anchor = content.topBar.actionButton(labelled: "Page Menu") else { return }
        let url = tab.displayURL
        let menu = NSMenu()

        let reader = NSMenuItem(title: "Reader Mode", action: #selector(togglePageReaderMode), keyEquivalent: "")
        reader.target = self
        reader.state = SiteSettings.shared.resolve(.readerMode, for: url) == "on" ? .on : .off
        menu.addItem(reader)

        menu.addItem(.separator())

        let engine = Settings.shared.searchEngine
        let searchItem = NSMenuItem(title: "Search engine \u{2014} \(engine.name)", action: nil, keyEquivalent: "")
        let searchSub = NSMenu()
        for candidate in Settings.shared.searchEngines {
            let item = NSMenuItem(title: candidate.name, action: #selector(selectSearchEngine(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = candidate.id
            item.state = candidate.id == engine.id ? .on : .off
            searchSub.addItem(item)
        }
        searchItem.submenu = searchSub
        menu.addItem(searchItem)

        menu.addItem(.separator())

        let currentZoom = Double(tab.currentWebView?.pageZoom ?? SiteSettings.shared.pageZoom(for: url))
        let currentPercent = Int((currentZoom * 100).rounded())
        let zoomItem = NSMenuItem(title: "Zoom \u{2014} \(currentPercent)%", action: nil, keyEquivalent: "")
        let zoomSub = NSMenu()
        for step in Self.zoomSteps {
            let percent = Int(((Double(step) ?? 1) * 100).rounded())
            let item = NSMenuItem(title: "\(percent)%", action: #selector(selectZoom(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = step
            item.state = percent == currentPercent ? .on : .off
            zoomSub.addItem(item)
        }
        zoomItem.submenu = zoomSub
        menu.addItem(zoomItem)

        let siteSettings = NSMenuItem(title: "Website Settings", action: #selector(showSiteSettingsFromMenu), keyEquivalent: "")
        siteSettings.target = self
        menu.addItem(siteSettings)

        menu.addItem(.separator())

        let boostItem = NSMenuItem(title: "Boost This Site\u{2026}", action: #selector(openBoostEditorFromMenu(_:)), keyEquivalent: "")
        boostItem.target = self
        menu.addItem(boostItem)

        if let host = url.host?.lowercased() {
            let isDark = BoostStore.shared.boost(for: host)?.isDarkModeEnabled ?? false
            let darkItem = NSMenuItem(
                title: isDark ? "Disable Universal Dark Mode" : "Enable Universal Dark Mode",
                action: #selector(toggleDarkModeFromMenu(_:)),
                keyEquivalent: ""
            )
            darkItem.target = self
            darkItem.state = isDark ? .on : .off
            menu.addItem(darkItem)
        }

        menu.addItem(.separator())

        let installAppItem = NSMenuItem(title: "Install Site as Web App\u{2026}", action: #selector(installCurrentSiteAsWebApp(_:)), keyEquivalent: "")
        installAppItem.target = self
        menu.addItem(installAppItem)

        let openStandaloneItem = NSMenuItem(title: "Open in Standalone Window", action: #selector(openCurrentSiteAsStandaloneWebApp(_:)), keyEquivalent: "")
        openStandaloneItem.target = self
        menu.addItem(openStandaloneItem)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.maxY + 4), in: anchor)
    }

    @objc private func togglePageReaderMode() {
        guard let url = session.activeTab?.displayURL, let host = url.host() else { return }
        let now = SiteSettings.shared.resolve(.readerMode, for: url)
        SiteSettings.shared.update { $0.set(now == "on" ? "off" : "on", for: host, in: .readerMode) }
        session.activeTab?.reload()
    }

    @objc private func selectSearchEngine(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let engine = Settings.shared.searchEngines.first(where: { $0.id == id }) else { return }
        Settings.shared.searchEngine = engine
    }

    @objc private func selectZoom(_ sender: NSMenuItem) {
        guard let step = sender.representedObject as? String else { return }
        session.activeTab?.setPageZoom(step)
        showZoomLevel()
    }

    @objc private func showSiteSettingsFromMenu() { showSiteSettings() }

    /// The per-site settings for the current page, in a popover off the gear.
    private func showSiteSettings() {
        guard let url = session.activeTab?.displayURL, url.host() != nil,
              let anchor = content.topBar.actionButton(labelled: "Site Settings") else { return }
        let controller = SiteSettingsPopover(url: url)
        controller.onApply = { [weak self] in self?.session.activeTab?.reload() }
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        siteSettingsPopover = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    // MARK: - Content Blocking & Element Picker

    @objc func showShieldPopover() {
        guard let tab = session.activeTab, let anchor = content.topBar.actionButton(labelled: "Shield") else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        let shieldVC = ShieldPopoverViewController(
            url: tab.displayURL,
            webView: tab.currentWebView,
            onReload: { [weak tab] in tab?.reload() },
            onBlockElement: { [weak self, weak tab] in
                guard let self, let webView = tab?.currentWebView else { return }
                self.startElementPicker(in: webView)
            },
            onOpenSettings: { [weak self] in
                self?.showAdvancedBlockingSettings()
            }
        )
        popover.contentViewController = shieldVC
        shieldPopover = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    @objc func startElementPickerFromMenu(_ sender: Any?) {
        startElementPicker()
    }

    func startElementPicker() {
        guard let tab = session.activeTab, let webView = tab.currentWebView else { return }
        startElementPicker(in: webView)
    }

    func startElementPicker(in webView: WKWebView) {
        ElementPickerCoordinator.shared.startPicking(in: webView)
    }

    @objc func toggleContentBlockingFromMenu(_ sender: Any?) {
        toggleCurrentSiteContentBlocking()
    }

    func toggleCurrentSiteContentBlocking() {
        guard let tab = session.activeTab, let host = tab.displayURL.host() else { return }
        let url = tab.displayURL
        let current = SiteSettings.shared.blocksContent(for: url)
        let normalizedHost = SiteSettings.normalise(host)
        SiteSettings.shared.update {
            $0.set(current ? "off" : "on", for: normalizedHost, in: .contentBlockers)
        }
        if let controller = tab.currentWebView?.configuration.userContentController {
            ContentBlocker.shared.applySiteChoice(for: url, to: controller)
        }
        content.updateTopBar()
    }

    func showAdvancedBlockingSettings() {
        let blockerVC = AdvancedBlockingViewController()
        content.presentAsSheet(blockerVC)
    }

    @objc func openBoostEditorFromMenu(_ sender: Any?) {
        openBoostEditor()
    }

    func openBoostEditor() {
        guard let tab = session.activeTab,
              let host = tab.displayURL.host?.lowercased(),
              let webView = tab.currentWebView else { return }
        let editor = BoostEditorViewController(host: host, webView: webView)
        content.presentAsSheet(editor)
    }

    @objc func toggleDarkModeFromMenu(_ sender: Any?) {
        toggleDarkModeForCurrentSite()
    }

    func toggleDarkModeForCurrentSite() {
        guard let tab = session.activeTab,
              let host = tab.displayURL.host?.lowercased(),
              let webView = tab.currentWebView else { return }
        _ = BoostStore.shared.toggleDarkMode(for: host)
        if let boost = BoostStore.shared.boost(for: host) {
            BoostCoordinator.shared.applyLive(boost: boost, to: webView)
        }
    }

    @objc func installCurrentSiteAsWebApp(_ sender: Any?) {
        guard let tab = session.activeTab else { return }
        let url = tab.displayURL
        let host = url.host ?? "Web App"
        let name = tab.displayTitle.isEmpty ? host : tab.displayTitle
        let spaces = session.spaces.map { ($0.id, $0.name) }
        let currentSpaceID = session.activeSpace.id

        let installer = WebAppInstallViewController(
            name: name,
            url: url,
            icon: nil,
            spaces: spaces,
            defaultSpaceID: currentSpaceID
        )

        installer.onInstall = { (finalName: String, targetURL: URL, spaceID: UUID?, icon: NSImage?) in
            do {
                let app = try WebAppManager.shared.install(
                    name: finalName,
                    url: targetURL,
                    spaceID: spaceID,
                    icon: icon
                )
                WebAppManager.shared.open(app: app)
                if let bundlePath = app.appBundlePath {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: bundlePath)])
                }
            } catch {
                NSLog("Kylmora: Failed to install web app: \(error.localizedDescription)")
            }
        }

        content.presentAsSheet(installer)
    }

    @objc func openCurrentSiteAsStandaloneWebApp(_ sender: Any?) {
        guard let tab = session.activeTab else { return }
        let url = tab.displayURL
        let title = tab.displayTitle
        let spaceID = session.activeSpace.id
        WebAppManager.shared.openStandalone(url: url, title: title, spaceID: spaceID)
    }

    @objc func copyCurrentURL(_ sender: Any?) {
        guard let url = session.activeTab?.displayURL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
    }

    @objc func togglePinActiveTab(_ sender: Any?) {
        guard let tab = session.activeTab else { return }
        if let site = session.activeSpace.pinnedSites.first(where: { $0.id == tab.pinnedSiteID || $0.matches(tab.url) }) {
            session.removePinnedSite(site)
        } else {
            session.pin(tab)
        }
    }

    @objc func duplicateActiveTab(_ sender: Any?) {
        guard let tab = session.activeTab else { return }
        _ = session.duplicate(tab)
    }

    /// The macOS share sheet for the current page, hung off the share button.
    private func shareCurrentPage() {
        guard let url = session.activeTab?.displayURL,
              let anchor = content.topBar.actionButton(labelled: "Share") else { return }
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    /// The zoom steps the Websites pane offers, so the toolbar buttons and the
    /// per-site setting speak the same language.
    private static let zoomSteps = ["0.5", "0.75", "0.85", "1", "1.15", "1.25", "1.5", "1.75", "2", "2.5", "3"]

    /// Zooms the page one step out (`-1`) or in (`+1`) from wherever it is, and
    /// remembers it for the site so a reload or a return keeps it.
    private func stepZoom(by step: Int) {
        guard let tab = session.activeTab else { return }
        let steps = Self.zoomSteps
        let current = Double(tab.currentWebView?.pageZoom ?? SiteSettings.shared.pageZoom(for: tab.url))
        let nearest = steps.enumerated().min {
            abs((Double($0.element) ?? 1) - current) < abs((Double($1.element) ?? 1) - current)
        }?.offset ?? (steps.firstIndex(of: "1") ?? 0)
        let index = min(max(nearest + step, 0), steps.count - 1)
        tab.setPageZoom(steps[index])
        showZoomLevel()
    }

    private func resetZoom() {
        session.activeTab?.setPageZoom("1")
        showZoomLevel()
    }

    /// Reflects the active tab's zoom in the top bar's percentage readout.
    func showZoomLevel() {
        let zoom = session.activeTab.map {
            Double($0.currentWebView?.pageZoom ?? SiteSettings.shared.pageZoom(for: $0.url))
        } ?? 1
        content.topBar.zoomControl.setPercent(Int((zoom * 100).rounded()))
    }

    /// One button for every extension rather than one each: the bar is
    /// narrow, and an extension is used far less often than the page.
    @available(macOS 15.4, *)
    private func showExtensionsMenu() {
        let manager = ExtensionManager.shared
        let menu = NSMenu()
        let actions = manager.actions
        if actions.isEmpty {
            let none = NSMenuItem(title: manager.entries.isEmpty ? "No Extensions Installed" : "No Extension Buttons",
                                  action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for (entry, action) in actions {
            let item = NSMenuItem(title: action.label.isEmpty ? entry.displayName : action.label,
                                  action: #selector(performExtensionAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action
            item.image = action.icon(for: CGSize(width: 16, height: 16)) ?? entry.icon
            item.isEnabled = action.isEnabled
            if !action.badgeText.isEmpty { item.title += "  \(action.badgeText)" }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Extension Settings\u{2026}", action: #selector(showExtensionSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        guard let anchor = content.topBar.actionButton(labelled: "Extensions") else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.maxY + 4), in: anchor)
    }

    @available(macOS 15.4, *)
    @objc private func performExtensionAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? WKWebExtension.Action else { return }
        ExtensionManager.shared.perform(action)
    }

    @objc private func showExtensionSettings() {
        (NSApp.delegate as? AppDelegate)?.showSettings(nil, on: .extensions)
    }

    /// The command bar is Kylmora's omnibox, moved off the sidebar. It never sees
    /// the session: it is given a provider that ranks values and a handler that
    /// performs one.
    private func wireCommandBar() {
        commandBar.install(in: content.view)

        commandBar.searchEngineProvider = { [weak self] in
            guard let self else { return .duckDuckGo }
            return Settings.shared.searchEngine(isPrivate: self.session.activeSpace.isPrivate)
        }
        commandBar.resultsProvider = { [weak self] query in
            guard let self else { return [] }
            let settings = Settings.shared
            let sources = settings.suggestionSources
            let history = sources.history ? await self.session.historySuggestions(matching: query, limit: 12) : []
            let activeID = self.session.activeTab?.id
            let engine = settings.searchEngine(isPrivate: self.session.activeSpace.isPrivate)
            let search = engine.url(for: query.trimmingCharacters(in: .whitespacesAndNewlines))
                .map { SearchCandidate(engineName: engine.name, url: $0) }

            let allTabs: [TabCandidate] = self.session.spaces.flatMap { space in
                space.tabs.map { tab in
                    TabCandidate(
                        id: tab.id,
                        title: tab.displayTitle,
                        address: AddressFormatter.display(tab.url),
                        url: tab.url,
                        isActive: tab.id == activeID,
                        spaceName: space.name
                    )
                }
            }

            let spaces: [SpaceCandidate] = self.session.spaces.map { space in
                SpaceCandidate(
                    id: space.id,
                    name: space.name,
                    isActive: space.id == self.session.activeSpace.id,
                    tabCount: space.tabs.count
                )
            }

            let commands = CommandCatalog.all

            return CommandRanker.rank(
                query: query,
                tabs: allTabs,
                spaces: spaces,
                commands: commands,
                history: history.map {
                    HistoryCandidate(
                        url: $0.url,
                        title: $0.title,
                        key: $0.key,
                        visitCount: $0.visitCount
                    )
                },
                bookmarks: self.session.bookmarks.map {
                    BookmarkCandidate(url: $0.url, title: $0.title, key: AddressFormatter.display($0.url))
                },
                search: search,
                sources: CommandSources(
                    openTabs: sources.openTabs,
                    spaces: true,
                    commands: true,
                    history: sources.history,
                    bookmarks: sources.bookmarks,
                    searchEngine: sources.searchEngine,
                    topHits: sources.topHits
                )
            )
        }

        commandBar.onRun = { [weak self] action in
            guard let self else { return }
            switch action {
            case .switchToTab(let id):
                // A tab in another space needs that space selected first;
                // `selectTab` only looks inside the active one.
                guard let space = self.session.spaces.first(where: { space in
                    space.tabs.contains { $0.id == id }
                }), let tab = space.tabs.first(where: { $0.id == id }) else { return }
                self.session.selectSpace(space)
                self.session.selectTab(tab)
            case .switchToSpace(let id):
                guard let space = self.session.spaces.first(where: { $0.id == id }) else { return }
                self.session.selectSpace(space)
            case .runCommand(let commandId):
                self.executeCommand(commandId)
            case .openURL(let url):
                // The same chord that peeks at a link peeks at a result.
                if GlanceInvocation.isGlanceChord(NSEvent.modifierFlags) {
                    self.content.openGlance(url)
                } else if self.commandBar.isNewTabMode {
                    self.session.newTab(url: url)
                } else if let tab = self.session.activeTab {
                    tab.load(url)
                } else {
                    self.session.newTab(url: url)
                }
            }
        }
    }

    /// The window title follows the visible page, which is what Mission Control
    /// and the Window menu show. The bookmark button follows it too.
    private func observeTitle() {
        session.changes
            .sink { [weak self] change in
                guard let self else { return }
                switch change {
                case .activeTab, .tabs:
                    self.updateTitle()
                case .spaces:
                    self.updateTitle()
                    // A live edit to the front space -- its appearance, wash,
                    // theme-color or border, from the Spaces settings pane --
                    // arrives as `.spaces` with no space switch, so the window
                    // is repainted here the way the switch path does. Without
                    // this the change does not show until the next switch.
                    self.refreshShownSpaceLook()
                case .tab(let tab):
                    if tab.id == self.session.activeTab?.id { self.updateTitle() }
                case .bookmarks:
                    self.updateBookmarkButton()
                case .structure:
                    break
                }
            }
            .store(in: &cancellables)
        updateTitle()
    }

    private func updateTitle() {
        window?.title = session.activeTab?.displayTitle ?? "Kylmora"
        updateBookmarkButton()
    }

    /// A filled bookmark on a page that is bookmarked, the outline on one that
    /// is not: the button says which of its two jobs a click does.
    private func updateBookmarkButton() {
        let bookmarked = session.activeTabIsBookmarked
        bookmarkButton?.setSymbol(
            bookmarked ? "bookmark.fill" : "bookmark",
            label: bookmarked ? "Remove Bookmark" : "Add Bookmark"
        )
    }

    /// Whether a responder is the page: a web view or anything inside one.
    private static func isWebContent(_ responder: NSResponder?) -> Bool {
        var view = responder as? NSView
        while let current = view {
            if current is WKWebView { return true }
            view = current.superview
        }
        return false
    }

    // MARK: - Menu actions

    /// Ours rather than `NSSplitViewController.toggleSidebar`, which only acts
    /// on an item created with sidebar behaviour.
    @objc func toggleKylmoraSidebar(_ sender: Any?) {
        guard let item = splitViewController.splitViewItems.first else { return }
        item.animator().isCollapsed.toggle()
    }

    /// Shows the archive, or puts it away. It is a mode of the sidebar rather
    /// than a window of its own, so opening it from the menu has to bring the
    /// sidebar back rather than toggle something nobody can see.
    @objc func toggleArchive(_ sender: Any?) {
        if sidebar.isShowingArchive {
            sidebar.setArchiveVisible(false)
            return
        }
        splitViewController.splitViewItems.first?.animator().isCollapsed = false
        sidebar.setArchiveVisible(true)
    }

    @objc func openCommandBar(_ sender: Any?) {
        commandBar.toggle()
        updateCompactSidebarForCommandBar()
    }

    @objc func openLocation(_ sender: Any?) {
        if commandBar.isOpen {
            commandBar.toggle()
        } else {
            let initialText = session.activeTab.map { AddressFormatter.display($0.url) } ?? ""
            commandBar.open(text: initialText, openInNewTab: false)
        }
        updateCompactSidebarForCommandBar()
    }

    private func updateCompactSidebarForCommandBar() {
        // The command bar is a reveal trigger; a missed close leaves the
        // floating sidebar pinned open.
        let reason = CompactRevealReason.commandBar
        if commandBar.isOpen {
            compact.controller.addReason(reason, to: .sidebar)
        } else {
            compact.controller.removeReason(reason, from: .sidebar)
        }
    }

    @objc func toggleCompactMode(_ sender: Any?) {
        compact.toggle()
        Settings.shared.compactModeEnabled = compact.controller.state.isEnabled
    }

    /// Pins the floating sidebar open. The only reveal reason no timer clears.
    @objc func toggleCompactSidebarPin(_ sender: Any?) {
        compact.controller.toggleUserShow()
    }

    /// Hides the bar above the page as well. Refused while the sidebar is
    /// hidden, because the traffic lights ride on it.
    @objc func toggleCompactToolbar(_ sender: Any?) {
        var configuration = Settings.shared.compactModeConfiguration
        configuration.hidesToolbar.toggle()
        Settings.shared.compactModeConfiguration = configuration
        compact.controller.setConfiguration(configuration)
    }

    /// Hides the window controls while the sidebar is hidden, and brings them
    /// back when the pointer is over the bar they would sit on.
    ///
    /// The sidebar is what normally hosts them. Without it they land on
    /// the page's top bar, on top of its first button. One answer is to hide
    /// them outright; hiding them permanently would leave no way to close the
    /// window with the mouse, so they return on hover, and the bar's buttons
    /// step aside for them while they are showing.
    // MARK: - The space's look

    /// Applies what the space in front decides about the window: its
    /// appearance, and what happens to the chrome in full screen.
    /// Repaints the window for the front space after its look is edited in the
    /// Spaces pane. Mirrors the four steps the space-switch path runs in
    /// `onShownSpaceChange`, instantly rather than animated, because an edit is
    /// not a switch.
    private func refreshShownSpaceLook() {
        let space = sidebar.shownSpaceForLook
        content.showSpaceWash(space.wash(for: space.activeTab), animatedOver: 0)
        content.showSpaceGradient(space.washGradient(for: space.activeTab), animatedOver: 0)
        root.border.show(space.effectiveBorder, animatedOver: 0)
        applyLook(of: space)
    }

    private func applyLook(of space: Space) {
        // Light or dark for this window only. The Settings window and the
        // panels keep following the General pane; nil here means "as the app".
        window?.appearance = space.look.appearance.appearance

        // Full screen: the system hides its own titlebar, and the space says
        // whether the sidebar and the bar above the page go with it. Both
        // hiding is done by borrowing compact mode with a configuration of
        // the space's own; neither hiding suppresses compact mode as before.
        let look = space.look
        var configuration = Settings.shared.compactModeConfiguration
        configuration.hidesSidebar = look.autoShowsSidebarInFullScreen
        configuration.hidesToolbar = !look.alwaysShowsToolbarInFullScreen
        let hidesChrome = isWindowFullScreen && (configuration.hidesSidebar || configuration.hidesToolbar)
        if hidesChrome {
            if compactWasEnabledBeforeFullScreen == nil {
                compactWasEnabledBeforeFullScreen = compact.controller.state.isEnabled
            }
            compact.controller.setSuppression(.windowFullScreen, active: false)
            compact.controller.setConfiguration(configuration)
            compact.setEnabled(true, animated: false)
        } else {
            if let wasEnabled = compactWasEnabledBeforeFullScreen {
                compactWasEnabledBeforeFullScreen = nil
                compact.controller.setConfiguration(Settings.shared.compactModeConfiguration)
                compact.setEnabled(wasEnabled, animated: false)
            }
            compact.controller.setSuppression(.windowFullScreen, active: isWindowFullScreen)
        }

        let opaque = isWindowFullScreen && look.isOpaqueInFullScreen
        sidebar.setOpaque(opaque)
        content.setOpaque(opaque)
    }

    private func updateTrafficLights() {
        guard let window else { return }
        if lightsRideOnTopBar {
            // Compact mode has re-parented the lights onto the bar itself,
            // eight points in; the bar's own buttons start after them.
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(type)?.alphaValue = 1
            }
            content.topBar.leadingInset = Style.Metrics.trafficLightWidth
            return
        }
        let shouldHide = WindowChrome.hidesWindowControls(
            sidebarCollapsed: isSidebarCollapsed,
            topBarHovered: isTopBarHovered,
            keepsButtons: Settings.shared.compactModeShowsWindowButtons
        )
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.allowsImplicitAnimation = true
            for button in buttons {
                button.animator().alphaValue = shouldHide ? 0 : 1
            }
        }
        content.topBar.leadingInset = WindowChrome.topBarLeadingInset(
            sidebarCollapsed: isSidebarCollapsed,
            topBarHovered: isTopBarHovered,
            reserved: Style.Metrics.trafficLightWidth,
            normal: Style.Metrics.sidebarInset
        )
    }

    /// Compact mode has to hear about the window, not just the pointer: a
    /// minimise or a fullscreen transition moves the pointer without ever
    /// sending an exit event, and that is the classic way to leave the sidebar
    /// revealed with nothing keeping it there.
    private func observeWindowState() {
        guard let window else { return }
        let center = NotificationCenter.default
        center.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.compact.controller.windowDidResignOrResize()
                self?.gestures.cancelSwipe()
            }
        }
        for (name, active) in [
            (NSWindow.didEnterFullScreenNotification, true),
            (NSWindow.didExitFullScreenNotification, false)
        ] {
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isWindowFullScreen = active
                    // A full-screen window has square corners; a rim clipped
                    // to round ones would leave the corners of the screen bare.
                    self.root.border.cornerRadius = active ? 0 : Style.Metrics.windowCornerRadius
                    self.applyLook(of: self.sidebar.shownSpaceForLook)
                }
            }
        }
        for (name, active) in [
            (NSWindow.didMiniaturizeNotification, true),
            (NSWindow.didDeminiaturizeNotification, false)
        ] {
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.compact.controller.setSuppression(.miniaturized, active: active)
                }
            }
        }
    }

    /// With no multi-selection, the pair to split is the selected tab and the
    /// one after it. `SplitLayout` refuses a split of one, which is the right
    /// answer for a space with a single tab.
    @objc func splitSideBySide(_ sender: Any?) { beginSplit(.sideBySide) }
    @objc func splitStacked(_ sender: Any?) { beginSplit(.stacked) }
    @objc func splitGrid(_ sender: Any?) { beginSplit(.grid) }
    @objc func unsplit(_ sender: Any?) { session.unsplit() }

    private func beginSplit(_ grid: SplitLayout.Grid) {
        let tabs = session.activeSpace.tabs
        guard let current = session.activeTab,
              let index = tabs.firstIndex(where: { $0.id == current.id }) else { return }
        let partner = tabs.indices.contains(index + 1) ? tabs[index + 1]
            : tabs.indices.contains(index - 1) ? tabs[index - 1]
            : nil
        guard let partner else { return }
        session.splitTabs([current, partner], grid: grid)
    }
    @objc func reopenClosedTab(_ sender: Any?) {
        session.reopenClosedTab()
    }

    @objc func newTab(_ sender: Any?) {
        if Settings.shared.openCommandBarOnNewTab {
            commandBar.open(openInNewTab: true)
            updateCompactSidebarForCommandBar()
        } else {
            session.newTab()
            commandBar.open(openInNewTab: false)
            updateCompactSidebarForCommandBar()
        }
    }
    @objc func closeTab(_ sender: Any?) {
        let multiSelected = sidebar.selectedTabs
        if multiSelected.count > 1 {
            session.closeTabs(multiSelected)
            return
        }
        guard let tab = session.activeTab, TabClosing.confirm(closing: tab) else { return }
        session.closeTab(tab)
    }

    @objc func closeAllTabsInCurrentSpace(_ sender: Any?) {
        session.closeAllTabs(in: session.activeSpace)
    }

    private func executeCommand(_ id: String) {
        switch id {
        case "new-tab":
            _ = session.newTab()
        case "close-tab":
            let multiSelected = sidebar.selectedTabs
            if multiSelected.count > 1 {
                session.closeTabs(multiSelected)
            } else if let tab = session.activeTab, TabClosing.confirm(closing: tab) {
                session.closeTab(tab)
            }
        case "close-all-tabs-in-space":
            closeAllTabsInCurrentSpace(nil)
        case "close-selected-tabs":
            let multiSelected = sidebar.selectedTabs
            if !multiSelected.isEmpty {
                session.closeTabs(multiSelected)
            } else if let tab = session.activeTab, TabClosing.confirm(closing: tab) {
                session.closeTab(tab)
            }
        case "reload-selected-tabs":
            let multiSelected = sidebar.selectedTabs
            if !multiSelected.isEmpty {
                session.reloadTabs(multiSelected)
            } else if let tab = session.activeTab {
                tab.reload()
            }
        case "reopen-closed-tab":
            _ = session.reopenClosedTab()
        case "duplicate-tab":
            duplicateActiveTab(nil)
        case "pin-tab":
            togglePinActiveTab(nil)
        case "copy-url":
            copyCurrentURL(nil)
        case "next-tab":
            selectNextTab(nil)
        case "previous-tab":
            selectPreviousTab(nil)
        case "next-space":
            selectNextSpace(nil)
        case "previous-space":
            selectPreviousSpace(nil)
        case "new-space":
            _ = session.addSpace(named: "New Space")
        case "split-side-by-side":
            splitSideBySide(nil)
        case "split-stacked":
            splitStacked(nil)
        case "split-grid":
            splitGrid(nil)
        case "unsplit":
            unsplit(nil)
        case "reload-page":
            reloadPage(nil)
        case "stop-loading":
            stopLoading(nil)
        case "go-back":
            goBack(nil)
        case "go-forward":
            goForward(nil)
        case "find-in-page":
            performFind(nil)
        case "reader-mode":
            togglePageReaderMode()
        case "zoom-in":
            stepZoom(by: 1)
        case "zoom-out":
            stepZoom(by: -1)
        case "zoom-reset":
            resetZoom()
        case "toggle-sidebar":
            toggleKylmoraSidebar(nil)
        case "toggle-compact":
            toggleCompactMode(nil)
        case "toggle-archive":
            toggleArchive(nil)
        case "full-screen":
            window?.toggleFullScreen(nil)
        case "downloads":
            DownloadManager.shared.showList()
        case "settings":
            (NSApp.delegate as? AppDelegate)?.showSettings(nil)
        case "sync-settings":
            (NSApp.delegate as? AppDelegate)?.showSyncSettings(nil)
        case "sync-now":
            (NSApp.delegate as? AppDelegate)?.syncNow(nil)
        case "export-backup":
            (NSApp.delegate as? AppDelegate)?.exportBackup(nil)
        case "import-backup":
            (NSApp.delegate as? AppDelegate)?.importBackup(nil)
        case "import-arc":
            (NSApp.delegate as? AppDelegate)?.importArcSidebar(nil)
        case "clear-history":
            session.clearHistory()
        case "block-element":
            startElementPicker()
        case "toggle-content-blocking":
            toggleCurrentSiteContentBlocking()
        case "blocking-settings":
            showAdvancedBlockingSettings()
        case "boost-site":
            openBoostEditor()
        case "toggle-dark-mode":
            toggleDarkModeForCurrentSite()
        case "open-little-arc":
            openLittleArc()
        case "install-site-as-app":
            installCurrentSiteAsWebApp(nil)
        case "open-standalone-app":
            openCurrentSiteAsStandaloneWebApp(nil)
        default:
            break
        }
    }

    /// Option-Command-1 to 9: the space's pinned sites, in tile order. The
    /// item's tag is its one-based position (`WindowListMenu`).
    @objc func openPinnedSiteByNumber(_ sender: Any?) {
        guard Settings.shared.favouriteShortcutsEnabled,
              let item = sender as? NSMenuItem else { return }
        let sites = session.activeSpace.pinnedSites
        guard sites.indices.contains(item.tag - 1) else { return }
        session.openPinnedSite(sites[item.tag - 1])
    }

    /// Control-1 to 9: a space by position, as the sidebar's menu lists them.
    @objc func selectSpaceByNumber(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, session.spaces.indices.contains(item.tag - 1) else { return }
        let space = session.spaces[item.tag - 1]
        guard space.id != session.activeSpaceID else { return }
        session.selectSpace(space)
    }
    @objc func reloadPage(_ sender: Any?) { session.activeTab?.reload() }
    @objc func stopLoading(_ sender: Any?) { session.activeTab?.stopLoading() }
    @objc func performFind(_ sender: Any?) { content.showFind() }
    @objc func promoteGlance(_ sender: Any?) { content.promoteGlance() }
    @objc func closeGlance(_ sender: Any?) { content.closeGlance() }
    @objc func findNext(_ sender: Any?) { content.findNext() }
    @objc func findPrevious(_ sender: Any?) { content.findPrevious() }
    @objc func goBack(_ sender: Any?) { session.activeTab?.goBack() }
    @objc func goForward(_ sender: Any?) { session.activeTab?.goForward() }
    @objc func selectNextTab(_ sender: Any?) { session.selectTab(offsetBy: 1) }
    @objc func selectPreviousTab(_ sender: Any?) { session.selectTab(offsetBy: -1) }
    @objc func selectNextSpace(_ sender: Any?) { switchSpace(by: 1, wraps: Settings.shared.spaceSwitchWraps) }
    @objc func selectPreviousSpace(_ sender: Any?) { switchSpace(by: -1, wraps: Settings.shared.spaceSwitchWraps) }

    /// How many Little Arc windows are open. The quit warning counts them: a
    /// little window holds a page the user has not kept, and quitting discards
    /// it.
    var openLittleArcCount: Int { littleArcs.openCount }

    @objc func openLittleArcWindow(_ sender: Any?) {
        openLittleArc()
    }

    func openLittleArc(url: URL? = nil) {
        let destination = url
            ?? session.activeTab?.displayURL
            ?? Settings.shared.newTabURL(isPrivate: externalLinkSpace.isPrivate)
        littleArcs.open(url: destination, in: externalLinkSpace)
    }

    /// A link handed over by another app: a Little Arc window, a glance or a
    /// tab, as the Browsing pane says, and a tab in every case if Shift is held
    /// as the link arrives.
    func openExternal(_ url: URL) {
        switch LittleArcRouting.destination(
            for: Settings.shared.externalLinkPresentation,
            shiftHeld: NSEvent.modifierFlags.contains(.shift)
        ) {
        case .littleArc:
            // Deliberately without raising this window: staying where the link
            // was clicked is the entire point of a Little Arc.
            littleArcs.open(url: url, in: externalLinkSpace)
        case .glance:
            showBrowserWindow()
            content.openGlance(url)
        case .tab:
            showBrowserWindow()
            session.newTab(url: url, origin: .external)
        }
    }

    /// The space links from other apps belong to: the one in front, unless the
    /// General pane names a default space.
    private var externalLinkSpace: Space {
        Settings.shared.externalLinkTarget == .defaultSpace ? session.defaultSpace : session.activeSpace
    }

    /// Brings the browser forward for a link that is about to become a tab or a
    /// glance inside it -- the one path where leaving the window where it is
    /// would hide the thing the user just asked for.
    private func showBrowserWindow() {
        let space = externalLinkSpace
        if space.id != session.activeSpaceID { session.selectSpace(space) }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The one path a space switch takes, so the swipe, the menu and the
    /// keyboard all animate the same way. Only the footer's dots jump, because
    /// a dot names a destination rather than a direction.
    func switchSpace(by offset: Int, wraps: Bool) {
        guard let target = SwitchNavigation.destination(
            from: activeSwitchableIndex,
            offset: offset,
            count: switchableCount,
            wraps: wraps
        ), target != activeSwitchableIndex else {
            sidebar.cancelSwipe()
            return
        }
        // The outgoing space leaves first and the space changes while nothing
        // is on screen, so the switch is one view leaving and returning rather
        // than two spaces needing to exist at once.
        let space = session.spaces[target]
        sidebar.animateSwitch(offset: offset) { [weak self] in
            self?.session.selectSpace(space)
        }
    }

    /// Cmd-1 through Cmd-9 select a tab by position; Cmd-9 is the last tab.
    /// The item's tag is its one-based position (`WindowListMenu`).
    @objc func selectTabByNumber(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, item.tag > 0 else { return }
        session.selectTab(number: item.tag)
    }

    // MARK: - Bookmarks

    @objc func toggleBookmark(_ sender: Any?) {
        session.toggleBookmarkForActiveTab()
    }

    /// Opens a bookmark or history entry in a new tab.
    @objc func openStoredURL(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let url = item.representedObject as? URL else { return }
        open(stored: url)
    }

    /// A bookmark or history item: a glance with the chord held, else a new
    /// tab or the current one as the Browsing pane says.
    private func open(stored url: URL) {
        if GlanceInvocation.isGlanceChord(NSEvent.modifierFlags) {
            content.openGlance(url)
        } else if Settings.shared.opensBookmarksInNewTabs || session.activeTab == nil {
            session.newTab(url: url)
        } else {
            session.activeTab?.load(url)
        }
    }

    @objc func clearHistory(_ sender: Any?) {
        session.clearHistory()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBack(_:)): return session.activeTab?.canGoBack ?? false
        case #selector(goForward(_:)): return session.activeTab?.canGoForward ?? false
        case #selector(closeTab(_:)), #selector(reloadPage(_:)): return session.activeTab != nil
        case #selector(reopenClosedTab(_:)): return session.canReopenClosedTab
        case #selector(openPinnedSiteByNumber(_:)):
            guard Settings.shared.favouriteShortcutsEnabled else { return false }
            return session.activeSpace.pinnedSites.indices.contains(menuItem.tag - 1)
        case #selector(selectTabByNumber(_:)):
            return session.activeSpace.listedTabs.indices.contains(menuItem.tag - 1)
        case #selector(selectSpaceByNumber(_:)):
            return session.spaces.indices.contains(menuItem.tag - 1)
        case #selector(stopLoading(_:)): return session.activeTab?.isLoading ?? false
        case #selector(splitSideBySide(_:)), #selector(splitStacked(_:)), #selector(splitGrid(_:)):
            return session.activeSpace.tabs.count > 1
        case #selector(unsplit(_:)): return session.activeSplit != nil
        case #selector(toggleKylmoraSidebar(_:)):
            let collapsed = splitViewController.splitViewItems.first?.isCollapsed ?? false
            menuItem.title = collapsed ? "Show Sidebar" : "Hide Sidebar"
            return true
        case #selector(toggleCompactMode(_:)):
            menuItem.state = compact.controller.state.isEnabled ? .on : .off
            return true
        case #selector(toggleCompactSidebarPin(_:)):
            return compact.controller.state.isEnabled
        case #selector(toggleCompactToolbar(_:)):
            let configuration = Settings.shared.compactModeConfiguration
            menuItem.state = configuration.resolved.hidesToolbar ? .on : .off
            // Disabled, not hidden: an item that vanishes reads as a bug, and
            // one that is visibly off explains why.
            return !configuration.hidesSidebar
        case #selector(promoteGlance(_:)): return content.canPromoteGlance
        case #selector(closeGlance(_:)): return content.isGlanceOpen
        case #selector(performFind(_:)): return content.canFind
        case #selector(findNext(_:)), #selector(findPrevious(_:)): return content.canRepeatFind
        case #selector(toggleBookmark(_:)):
            menuItem.title = session.activeTabIsBookmarked ? "Remove Bookmark" : "Add Bookmark"
            return session.activeTab != nil
        case #selector(selectNextTab(_:)), #selector(selectPreviousTab(_:)):
            return session.activeSpace.tabs.count > 1
        case #selector(selectNextSpace(_:)), #selector(selectPreviousSpace(_:)):
            return session.spaces.count > 1
        default: return true
        }
    }
}

/// The page card supplies the only edge between the sidebar and the page.
/// A drawn divider on top of it is a second, harder line.
///
/// The split view has to be installed in `loadView`, before the controller
/// builds its own: assigning one afterwards detaches the items that were
/// already added and drops the sidebar and the page into a single column.
@MainActor
/// The window's content: the split view, with the space's rim drawn over it.
///
/// A container of its own rather than a subview added to the split view,
/// because an `NSSplitView` treats every subview as a pane. The compact
/// chrome parents its floating sidebar under whatever the window's content
/// controller is, which is now this; it never assumed the split view.
final class KylmoraRootViewController: NSViewController {
    let border = WindowBorderView()

    override func loadView() {
        view = NSView()
    }

    func host(_ child: NSViewController) {
        addChild(child)
        let hosted = child.view
        hosted.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosted)
        view.addSubview(border, positioned: .above, relativeTo: hosted)
        NSLayoutConstraint.activate([
            hosted.topAnchor.constraint(equalTo: view.topAnchor),
            hosted.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosted.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosted.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            border.topAnchor.constraint(equalTo: view.topAnchor),
            border.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            border.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            border.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
}

final class KylmoraSplitViewController: NSSplitViewController {
    private final class ClearDividerSplitView: NSSplitView {
        override var dividerColor: NSColor { .clear }
        // Zero width so the page card sits flush against the sidebar with no
        // 1pt gap between them: that gap, revealing whatever is behind the
        // split view, is the faint line otherwise seen at the seam. The card's
        // edge is still the separation; resizing keeps working because
        // an NSSplitView still tracks a drag on a zero-width divider.
        override var dividerThickness: CGFloat { 0 }
    }

    override func loadView() {
        let split = ClearDividerSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        splitView = split
        super.loadView()
    }
}

/// Compact mode takes the sidebar out of the split view and floats it over the
/// page. Only the window controller knows how the split view is built, so only
/// it can take it apart and put it back.
extension BrowserWindowController: CompactSidebarSlot {
    var restingSidebarWidth: CGFloat {
        let live = sidebar.view.frame.width
        if live >= Style.Metrics.sidebarMinWidth { lastSidebarWidth = live }
        return lastSidebarWidth
    }

    func detachSidebar() -> NSViewController {
        _ = restingSidebarWidth
        if let item = splitViewController.splitViewItems.first(
            where: { $0.viewController === sidebar }
        ) {
            splitViewController.removeSplitViewItem(item)
        }
        return sidebar
    }

    func reattachSidebar(_ controller: NSViewController) {
        let item = NSSplitViewItem(viewController: controller)
        item.minimumThickness = Style.Metrics.sidebarMinWidth
        item.maximumThickness = Style.Metrics.sidebarMaxWidth
        item.canCollapse = true
        item.holdingPriority = .defaultLow
        splitViewController.insertSplitViewItem(item, at: 0)
        // The autosaved position does not come back with a re-inserted item.
        splitViewController.splitView.setPosition(lastSidebarWidth, ofDividerAt: 0)
    }
}

extension BrowserWindowController: SidebarSwipeDelegate {
    /// A two-finger swipe across the sidebar does exactly what the dots in the
    /// sidebar's footer do: it moves one step along the spaces. Matching the
    /// dots is the whole requirement; the dots are the visible count.
    var switchableCount: Int { session.spaces.count }

    var activeSwitchableIndex: Int {
        session.spaces.firstIndex { $0.id == session.activeSpaceID } ?? 0
    }

    /// A drag that starts while the strip is still travelling would kill the
    /// incoming space's animation mid-flight and leave the outgoing one to
    /// finish alone, so the swipe refuses to start until the strip is at rest.
    var isSwitchInFlight: Bool { sidebar.isSwitchInFlight }

    var swipeRegion: NSRect? {
        guard let view = sidebar.viewIfLoaded, view.window != nil else { return nil }
        return view.convert(view.bounds, to: nil)
    }

    func swipeDidDrag(by translation: CGFloat, crossfade: CGFloat) {
        sidebar.applySwipe(translation: translation, crossfade: crossfade)
    }

    func swipeDidCancel() {
        sidebar.cancelSwipe()
    }

    func swipe(switchBy offset: Int, wraps: Bool) {
        switchSpace(by: offset, wraps: wraps)
    }
}
