import AppKit
import Combine

/// The content pane: the active tab's page, or why it isn't there.
@MainActor
final class WebContentViewController: NSViewController {
    private let session: BrowserSession
    private let container = WebContainerView()
    /// The page sits inside the rounded card, below the top bar (D-UI1).
    private let contentContainer = ContentContainerView()
    /// Cmd-F. Lazy because it subscribes to the session on `install`, which
    /// must not happen before there is a view to install into.
    private lazy var find = FindController(session: session)
    /// Option-click a link to peek at it. Owns its own overlay over the page.
    private let glance = GlanceController()
    /// Toasts appear over the page, inset 8 points from its bottom-leading
    /// corner (D-TN4).
    private(set) lazy var toasts = ToastPresenter(hostView: contentContainer)

    /// Lazy for the same reason `find` is: nothing is built for a feature the
    /// user has not invoked.
    private lazy var splitContainer: SplitContainerView = {
        let container = SplitContainerView()
        container.onFocusPane = { [weak self] id in
            guard let self, let tab = self.session.activeSpace.tabs.first(where: { $0.id == id }) else { return }
            self.session.selectTab(tab)
        }
        container.onClosePane = { [weak self] id in
            guard let self, let tab = self.session.activeSpace.tabs.first(where: { $0.id == id }) else { return }
            self.session.closeTab(tab)
        }
        container.onToggleStickPane = { [weak self] id in
            self?.session.toggleStickPane(id)
        }
        container.onUnsplitPane = { [weak self] id in
            guard let self, let tab = self.session.activeSpace.tabs.first(where: { $0.id == id }) else { return }
            self.session.removeFromSplit(tab)
        }
        container.onEqualize = { [weak self] _ in
            self?.session.equalizeSplit()
        }
        container.onLayoutChange = { [weak self] layout in
            self?.session.updateSplitLayout(layout)
        }
        return container
    }()
    private var cancellables: Set<AnyCancellable> = []

    init(session: BrowserSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("WebContentViewController is created in code only")
    }

    override func loadView() {
        contentContainer.setPage(container)
        view = contentContainer
    }

    /// The bar above the page. The window controller wires its buttons,
    /// because it is what owns the sidebar and the menu actions they repeat.
    var topBar: ContentTopBar { contentContainer.topBar }

    /// The wash on the strip around the page card. Set from the window
    /// controller when the space in front changes.
    func setOpaque(_ opaque: Bool) {
        contentContainer.setOpaque(opaque)
    }

    var spaceWash: NSColor? {
        get { contentContainer.spaceWash }
        set { contentContainer.spaceWash = newValue }
    }

    /// The gradient wash on the strip, for a space washed with two colours.
    var spaceGradient: WashGradient? {
        get { contentContainer.spaceGradient }
        set { contentContainer.spaceGradient = newValue }
    }

    /// The strip around the page card follows a space switch in the sidebar.
    func blendSpaceWash(toward other: NSColor?, fraction: CGFloat) {
        contentContainer.blendSpaceWash(toward: other, fraction: fraction)
    }

    func showSpaceWash(_ wash: NSColor?, animatedOver duration: TimeInterval) {
        contentContainer.showSpaceWash(wash, animatedOver: duration)
    }

    func showSpaceGradient(_ gradient: WashGradient?, animatedOver duration: TimeInterval) {
        contentContainer.showSpaceGradient(gradient, animatedOver: duration)
    }

    /// Widened when the sidebar is hidden, because the split view's divider is
    /// what supplies this gutter the rest of the time.
    var cardLeadingInset: CGFloat {
        get { contentContainer.cardLeadingInset }
        set { contentContainer.cardLeadingInset = newValue }
    }

    /// Compact mode animates this to collapse the bar (D-CM8).
    var topBarTopConstraint: NSLayoutConstraint { contentContainer.topBarTopConstraint }


    var onPinchToOverview: (() -> Void)? {
        get { contentContainer.onPinchToOverview }
        set { contentContainer.onPinchToOverview = newValue }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        container.onNewTab = { [weak self] in self?.session.newTab() }
        find.install(in: container)
        session.showToast = { [weak self] toast in self?.toasts.show(toast) }
        SiteSettings.shared.addChangeObserver { [weak self] in self?.updateTopBar() }

        glance.install(
            in: container,
            // The view that is scaled back and dimmed behind the panel. A
            // closure, because the visible web view changes with every switch.
            ownerPage: { [weak self] in self?.session.activeTab?.currentWebView },
            identity: { [weak self] in self?.session.activeSpace.identity ?? .standard }
        )
        glance.onPromote = { [weak self] webView, _, ownerID in
            guard let self else { return }
            let owner = self.session.allTabs.first { $0.id == ownerID } ?? self.session.activeTab
            self.session.adoptGlancedTab(webView, after: owner)
        }
        glance.onRequestChildTab = { [weak self] configuration in
            guard let self, let parent = self.session.activeTab else { return nil }
            return self.session.adoptChildTab(of: parent, configuration: configuration).webView()
        }
        GlanceLinkMonitor.shared.isPinnedSite = { [weak self] url in
            self?.session.isPinnedSite(url) ?? false
        }
        GlanceLinkMonitor.shared.onOpenSplit = { [weak self] url in
            guard let self, let activeTab = self.session.activeTab else { return }
            self.session.openLinkInSplit(url, from: activeTab)
        }

        contentContainer.tabStrip.onSelect = { [weak self] tab in self?.session.selectTab(tab) }
        contentContainer.tabStrip.onClose = { [weak self] tab in
            guard let self, !tab.isLocked, TabClosing.confirm(closing: tab) else { return }
            _ = self.session.closeTab(tab)
        }
        contentContainer.tabStrip.onNewTab = { [weak self] in _ = self?.session.newTab() }
        contentContainer.tabStrip.onReorder = { [weak self] from, to in self?.session.moveTab(from: from, to: to) }
        for name in [Notification.Name.tabStripDidChange, .zenModeDidChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateTabStrip(rebuild: true) }
            }
        }
        updateTabStrip(rebuild: true)

        session.changes
            .sink { [weak self] change in
                guard let self else { return }
                switch change {
                case .tab(let tab) where tab.id != self.session.activeTab?.id:
                    // A background tab's title or sound changed: its cell follows.
                    self.updateTabStrip(rebuild: false)
                    return
                case .activeTab, .spaces, .tabs, .structure:
                    self.updateTabStrip(rebuild: true)
                case .tab:
                    self.updateTabStrip(rebuild: false)
                case .bookmarks:
                    break
                }
                switch change {
                case .activeTab, .spaces, .tabs:
                    // A glance belongs to the page it was opened over; when
                    // that page is no longer on screen there is nothing to fly
                    // back to.
                    self.glance.dismiss(.selectionChanged)
                    self.showActiveTab()
                    if case .spaces = change { self.updateBookmarksBar() }
                case .tab(let tab):
                    // A failure or a recovery on the visible tab changes what
                    // this pane shows; other tabs do not.
                    if tab.id == self.session.activeTab?.id {
                        self.showActiveTab()
                        if !tab.isLoading, let webView = tab.currentWebView {
                            Task { [weak self] in
                                await PageTranslator.shared.detectLanguage(in: webView, for: tab.id)
                                self?.updateTopBar()
                                await TabSnapshotStore.shared.capture(tab: tab)
                            }
                        }
                    }
                case .bookmarks:

                    self.updateBookmarksBar()
                case .structure:
                    // Splitting and unsplitting are announced here, and both
                    // change what the pane draws.
                    self.showActiveTab()
                }
            }
            .store(in: &cancellables)
        showActiveTab()
        contentContainer.bookmarksBar.onOpen = { [weak self] url in self?.onOpenBookmark?(url) }
        updateBookmarksBar()
    }

    /// A bookmark in the bar was clicked. The window decides where it opens,
    /// as it does for the Bookmarks menu.
    var onOpenBookmark: ((URL) -> Void)?

    /// The bar shows the one bookmark list, styled and shown as the space in
    /// front says.
    private func updateBookmarksBar() {
        let space = session.activeSpace
        contentContainer.showsBookmarksBar = space.look.showsBookmarksBar
        guard space.look.showsBookmarksBar else { return }

        let bookmarks: [Bookmark]
        if let folder = space.bookmarkFolder?.trimmingCharacters(in: .whitespacesAndNewlines), !folder.isEmpty {
            let filtered = session.bookmarks.filter { $0.folder.localizedCaseInsensitiveCompare(folder) == .orderedSame }
            bookmarks = filtered.isEmpty ? session.bookmarks : filtered
        } else {
            bookmarks = session.bookmarks
        }
        contentContainer.bookmarksBar.show(bookmarks, style: space.look.bookmarksBarStyle, isPrivate: space.isPrivate)
    }

    /// Building the web view here is what makes tab creation lazy: a tab that is
    /// never shown never allocates one.
    private func showActiveTab() {
        // Whatever this leaves on screen is the full set that may play media;
        // pause the rest. Deferred so it runs after the branch below has built
        // the visible tab's web view, on every exit path (single, split, none).
        defer { session.updateMediaSuspension() }
        updateTopBar()

        if let split = session.activeSplit {
            // Releasing the single-page view first matters: a tab cannot be a
            // subview of two containers, and the pane is where it belongs now.
            container.show(nil, failure: nil, url: nil, onRetry: nil)
            if splitContainer.superview == nil { contentContainer.setPage(splitContainer) }
            splitContainer.show(
                tabs: session.activeSpace.tabs,
                layout: split,
                focused: session.activeTab?.id,
                isSticky: { [weak self] id in self?.session.isSticky(id) ?? false }
            )
            return
        }

        if splitContainer.superview != nil {
            splitContainer.tearDown()
            contentContainer.setPage(container)
        }

        guard let tab = session.activeTab else {
            container.show(nil, failure: nil, url: nil, onRetry: nil)
            return
        }
        tab.markActive()
        if tab.showsStartPage { refreshStartPage(for: tab) }
        container.show(
            tab.webView(),
            document: tab.contentOverlay,
            failure: tab.failure,
            url: tab.displayURL,
            onRetry: { [weak tab] in tab?.reload() }
        )
    }

    /// Kylmora has no site-name source yet, so the breadcrumb shows the title
    /// alone and drops the separator with it (D-UI4). The real address stays
    /// in the tooltip and the accessibility value either way.
    func updateTopBar() {
        let tab = session.activeTab
        topBar.update(
            canGoBack: tab?.canGoBack ?? false,
            canGoForward: tab?.canGoForward ?? false,
            isLoading: tab?.isLoading ?? false,
            hasPage: tab != nil
        )
        if let shieldButton = topBar.actionButton(labelled: "Shield") as? IconButton {
            let isBlocked = SiteSettings.shared.blocksContent(for: tab?.displayURL)
            if isBlocked {
                shieldButton.setSymbol("checkmark.shield.fill", label: "Shield")
                shieldButton.contentTintColor = .systemGreen
            } else {
                shieldButton.setSymbol("shield.slash.fill", label: "Shield")
                shieldButton.contentTintColor = .secondaryLabelColor
            }
        }
        if let transButton = topBar.actionButton(labelled: "Translate Page") as? IconButton {
            if let tab = tab {
                let transState = PageTranslator.shared.state(for: tab.id)
                if transState.isTranslated {
                    transButton.contentTintColor = .systemBlue
                    transButton.toolTip = "Translated on-device to \(TranslationLanguages.displayName(for: transState.targetLanguage))"
                } else if case .available(let src, _) = transState.status {
                    transButton.contentTintColor = .systemOrange
                    transButton.toolTip = "Page is in \(TranslationLanguages.displayName(for: src)) • Click to translate on-device"
                } else {
                    transButton.contentTintColor = .secondaryLabelColor
                    transButton.toolTip = "Translate Page (On-Device)"
                }
            } else {
                transButton.contentTintColor = .secondaryLabelColor
            }
        }
        let settings = Settings.shared
        // The full address, so what the user edits or copies is the whole URL
        // rather than a bare host that would drop the path.
        // The start page has no address to show or copy: the field is empty
        // and ready to type into.
        let onStartPage = tab?.showsStartPage ?? false
        topBar.addressField.show(
            display: onStartPage ? "" : tab.map {
                AddressFormatter.display($0.displayURL, full: true, unicodeDomains: settings.showsUnicodeDomains)
            },
            url: onStartPage ? nil : tab?.displayURL
        )
        let zoom = tab.map { Double($0.currentWebView?.pageZoom ?? SiteSettings.shared.pageZoom(for: $0.url)) } ?? 1
        topBar.zoomControl.setPercent(Int((zoom * 100).rounded()))
    }

    // MARK: - Tab strip

    /// Shows or hides the row of tabs and fills it from the active space.
    /// Zen mode hides it with everything else.
    func updateTabStrip(rebuild: Bool) {
        let settings = Settings.shared
        let shows = settings.showsTabStrip && !settings.zenModeEnabled
        contentContainer.showsTabStrip = shows
        guard shows else { return }
        let space = session.activeSpace
        if rebuild {
            contentContainer.tabStrip.show(space.tabs, activeID: session.activeTab?.id, isPrivate: space.isPrivate)
        } else {
            contentContainer.tabStrip.refresh(activeID: session.activeTab?.id)
        }
    }

    // MARK: - Start page

    /// Fills the tab's start page from the session: the Space's pinned sites,
    /// the most visited pages, recently closed tabs and the unread reading
    /// list. History comes from the database, so the tiles land a beat after
    /// the page.
    func refreshStartPage(for tab: Tab) {
        guard tab.showsStartPage, let view = tab.contentOverlay as? StartPageView else { return }
        let space = session.activeSpace
        var model = StartPageModel()
        model.spaceName = space.name
        model.spaceColor = space.color
        model.isPrivate = space.isPrivate
        model.pinned = space.pinnedSites.map { StartPageModel.Link(id: $0.id.uuidString, url: $0.url, title: $0.title) }
        model.recentlyClosed = session.closedTabs.prefix(6).map {
            StartPageModel.Link(id: $0.id.uuidString, url: $0.url, title: $0.title)
        }
        model.readingList = ReadingListStore.shared.unreadItems.prefix(5).map {
            StartPageModel.Link(id: $0.id.uuidString, url: $0.url, title: $0.title)
        }
        view.onOpen = { [weak tab] url in tab?.load(url) }
        view.configure(with: model)

        guard !space.isPrivate else { return }
        Task { [weak self, weak tab, weak view] in
            guard let self else { return }
            let sites = await self.session.topSites(limit: 12)
            guard let tab, tab.showsStartPage, let view, view.model.spaceName == model.spaceName else { return }
            var filled = view.model
            filled.topSites = sites.map { StartPageModel.Link(url: $0.url, title: $0.title) }
            view.configure(with: filled)
        }
    }

    // MARK: - Find in page

    var canFind: Bool { find.canFind }
    var canRepeatFind: Bool { find.canRepeat }

    /// A tab showing a document searches the document; the find bar is for
    /// web pages.
    func showFind() {
        if let documentView = session.activeTab?.documentView, session.activeSplit == nil {
            documentView.focusSearch()
            return
        }
        find.show()
    }

    // MARK: - Glance

    var isGlanceOpen: Bool { glance.isOpen }
    var canPromoteGlance: Bool { glance.canPromote }

    func openGlance(_ url: URL) {
        glance.open(url: url, origin: .centre, source: .command,
                    ownerTabID: session.activeTab?.id)
    }

    func closeGlance() { glance.dismiss(.closeButton) }
    func promoteGlance() { glance.promote() }
    func findNext() {
        if let documentView = session.activeTab?.documentView, session.activeSplit == nil {
            documentView.findNext()
            return
        }
        find.findNext()
    }
    func findPrevious() {
        if let documentView = session.activeTab?.documentView, session.activeSplit == nil {
            documentView.findPrevious()
            return
        }
        find.findPrevious()
    }
}
