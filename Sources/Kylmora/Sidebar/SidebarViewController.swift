import AppKit
import Combine

/// The vertical navigation surface: omnibox, the active space's tabs, and the
/// space switcher. Everything the user does to change context happens here.
@MainActor
final class SidebarViewController: NSViewController {
    private static let tabRowType = NSPasteboard.PasteboardType("com.kylmora.Kylmora.tabRow")
    private static let groupRowType = NSPasteboard.PasteboardType("com.kylmora.Kylmora.groupRow")

    private let session: BrowserSession
    private let diaHeader = SidebarHeaderView()

    /// Buttons on the trailing end of the header strip. Empty is the usual
    /// state: the page's top bar carries them. A floating sidebar covers that
    /// bar, so what it covers has to be reachable from the sidebar itself.
    func setHeaderActions(_ actions: [TopBarAction]) {
        diaHeader.setActions(actions)
    }

    /// Whether the header strip is the traffic lights' host at the moment.
    /// The window controller decides; compact mode and a trailing sidebar both
    /// put them somewhere else. See `SidebarHeaderView.hostsTrafficLights`.
    var headerHostsTrafficLights: Bool {
        get { diaHeader.hostsTrafficLights }
        set { diaHeader.hostsTrafficLights = newValue }
    }
    private let pinnedTiles = PinnedTilesView()
    private let diaFooter = SidebarFooterView()
    private let nowPlayingView = SidebarNowPlayingView()
    /// The archive, shown in place of the pins and the tab list. Held rather
    /// than built on demand so its scroll position survives being left.
    private let archiveList = ArchiveListView()
    /// The footer's Archive button, so it can be shown as on while the archive
    /// is what the sidebar is displaying. Weak: the footer owns it, and rebuilds
    /// it whenever its actions are set.
    private weak var archiveButton: IconButton?
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    /// Never shown. It exists only to build the space menu, which
    /// `SidebarHeaderView`'s label button borrows.
    private let spaceMenuButton = NSPopUpButton(frame: .zero, pullsDown: true)

    /// Table view displaying tabs and groups.
    var tabListTableView: NSTableView { tableView }

    /// Told which space is in front, so the window can wash the strip beside
    /// the page card with its colour and draw its border as well. The sidebar
    /// is the only thing watching the session for this, and duplicating that
    /// subscription in the window controller would give two places to keep
    /// in step.
    var onShownSpaceChange: ((Space, TimeInterval) -> Void)?
    /// The strip has been dragged part-way towards this neighbouring space.
    /// The page card's strip and the window's rim follow the sidebar.
    var onShownSpaceBlend: ((Space?, CGFloat) -> Void)?
    /// The wash changed without the space changing: the page in front has a
    /// colour of its own, or stopped having one.
    var onWashChange: ((NSColor?) -> Void)?
    /// The active space's gradient wash, for the page strip to match the
    /// sidebar. Nil when the space has a solid wash.
    var onGradientChange: ((WashGradient?) -> Void)?

    /// The space's colour washed over the sidebar's material. Created with the
    /// view, so it is only nil before `loadView`.
    private var tint: TintView?
    private var material: NSVisualEffectView?

    /// The space whose look the window should wear: the one in front, or
    /// the one being previewed by a drag.
    var shownSpaceForLook: Space { shownSpace }

    /// All tabs currently selected in the sidebar table view (multi-selection).
    var selectedTabs: [Tab] {
        tableView.selectedRowIndexes.compactMap { index in
            guard rows.indices.contains(index), case .tab(let tab, _, _) = rows[index] else { return nil }
            return tab
        }
    }

    /// Stops the material showing the desktop through the window, for a
    /// space that wants full screen opaque. Blending within the window
    /// instead of behind it leaves the material on the window's own
    /// background, which is a plain colour.
    func setOpaque(_ opaque: Bool) {
        material?.blendingMode = opaque ? .withinWindow : .behindWindow
    }
    private var cancellables: Set<AnyCancellable> = []
    /// The sidebar list is no longer one row per tab: a collapsible group
    /// contributes a header row and, when open, its tabs. Flattening it once
    /// per reload keeps every index question -- selection, drag, refresh -- a
    /// lookup rather than a calculation.
    private var rows: [SidebarRow] = []
    /// The folder plate slices each row draws, rebuilt with `rows`.
    private var plates: [[FolderPlatePlan.Piece]] = []
    /// The same slices resolved with each group's colour and its place in the
    /// whole plate, so a themed group's gradient runs unbroken across its rows.
    private var slices: [[FolderPlateSlice]] = []
    /// Held while the group appearance editor is open, so it lives as long as
    /// the popover it drives.
    private var appearancePopover: NSPopover?
    private let settings = Settings.shared
    /// Advances the idle badges. Only the badges, and only the rows on screen;
    /// see `tickIdleBadges`.
    private var idleTimer: Timer?
    /// Once a second, so a badge counting seconds counts them. Above a minute
    /// the string stops changing on its own and the tick becomes a comparison
    /// that finds nothing, which is cheap enough to leave running rather than
    /// build a scheduler that would have to be re-armed on every scroll.
    private static let idleTickInterval: TimeInterval = 1

    /// One entry in the flattened sidebar list.
    ///
    /// New Tab is a row rather than a button in the header, which keeps the
    /// header to one label: the thing you are browsing as.
    private enum SidebarRow {
        case group(TabGroup, depth: Int, showsEscapedTab: Bool)
        case tab(Tab, depth: Int, isEscaping: Bool)
        case liveStatus(TabGroup, LiveFolderStatus, depth: Int)
        case newTab

        /// What makes a row *the same row* across a rebuild.
        ///
        /// Deliberately only the thing the row stands for, and none of what it
        /// currently looks like: a tab that moved into a folder, changed depth,
        /// started loading or was renamed is still the same tab, and a list
        /// that treated it as a different one would animate it out and back in
        /// for a title change. Depth and state are content, and content is
        /// refreshed rather than animated.
        enum Identity: Hashable {
            case group(TabGroup.ID)
            case tab(Tab.ID)
            case liveStatus(TabGroup.ID)
            case newTab
        }

        var identity: Identity {
            switch self {
            case .group(let group, _, _): .group(group.id)
            case .tab(let tab, _, _): .tab(tab.id)
            case .liveStatus(let group, _, _): .liveStatus(group.id)
            case .newTab: .newTab
            }
        }
    }

    /// Rows the next `viewFor` should spring into place rather than simply
    /// hand over.
    ///
    /// Keyed by identity rather than by row index because the table asks for
    /// its views part-way through applying the update, when an index means one
    /// thing before the batch and another after it.
    private var pendingEntrances: Set<SidebarRow.Identity> = []

    init(session: BrowserSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("SidebarViewController is created in code only")
    }

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        buildLayout()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        wireActions()
        subscribeToSession()
        reloadSpaces()
        reloadTabs()
        reloadArchive()
        syncActiveTab()
        refreshNowPlaying()
        startIdleTicking()
    }

    private func startIdleTicking() {
        guard idleTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.idleTickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickIdleBadges() }
        }
        // A badge one second stale is not worth waking a sleeping Mac for, so
        // the tick is entirely tolerant and coalesces with whatever else the
        // run loop was going to do anyway.
        timer.tolerance = Self.idleTickInterval
        idleTimer = timer
    }

    // MARK: - Layout

    private func buildLayout() {
        configureTableView()

        // The sidebar supplies its own material now. A split item created with
        // sidebar behaviour would supply it, but it also draws a one-point
        // separator down its trailing edge that neither `dividerColor` nor a
        // zero `dividerThickness` removes -- measured. A plain item plus this
        // view is the same look without the rule.
        let material = NSVisualEffectView()
        material.material = .sidebar
        material.blendingMode = .behindWindow
        material.state = .followsWindowActiveState
        material.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(material)
        self.material = material
        NSLayoutConstraint.activate([
            material.topAnchor.constraint(equalTo: view.topAnchor),
            material.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            material.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            material.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // The profile's colour goes on above the material so the sidebar says
        // which identity is in front before a single word is read.
        tint = TintView.install(over: material, in: view)

        // Stands in for the titlebar the window does not have: drag to move,
        // double-click to zoom. It sits behind everything else in the strip so
        // the buttons in that area still receive their own clicks.
        let titlebar = TitlebarDragView()
        titlebar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titlebar)
        NSLayoutConstraint.activate([
            titlebar.topAnchor.constraint(equalTo: view.topAnchor),
            titlebar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            titlebar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            titlebar.heightAnchor.constraint(equalToConstant: 34)
        ])

        diaHeader.spaceButton.menuProvider = { [weak self] in self?.spaceMenuButton.menu }

        pinnedTiles.onAdd = { [weak self] in self?.session.pinActiveTab() }
        pinnedTiles.onSelect = { [weak self] id in
            guard let self,
                  let site = self.session.activeSpace.pinnedSites.first(where: { $0.id.uuidString == id })
            else { return }
            self.session.openPinnedSite(site)
        }
        pinnedTiles.onRemove = { [weak self] id in
            guard let self,
                  let site = self.session.activeSpace.pinnedSites.first(where: { $0.id.uuidString == id })
            else { return }
            self.session.removePinnedSite(site)
        }

        diaFooter.onSelectPage = { [weak self] index in
            guard let self, self.session.spaces.indices.contains(index) else { return }
            self.session.selectSpace(self.session.spaces[index])
        }
        // One way to reach each thing. The dots switch spaces; everything
        // else about a space -- making, renaming, recolouring, deleting --
        // is the header menu's and Settings' job. The two standing buttons are
        // the browser-wide lists that outlive any tab or space, one in each
        // corner: Downloads for what came out of the web, Archive for what
        // left the sidebar. A foot-of-the-sidebar affordance is where the eye
        // looks for both.
        //
        // The Archive button is always there, including when the archive is
        // empty and when archiving is switched off. A control that appears only
        // once the feature has taken something away is a control nobody finds
        // until they are already looking for a tab they have lost. It toggles
        // the sidebar into the archive and lights up while the archive is what
        // the sidebar is showing; the archive's own empty state explains
        // itself, and says where the setting is.
        diaFooter.setLeadingActions([
            TopBarAction(symbolName: "arrow.down.circle", label: "Downloads") {
                DownloadManager.shared.showList()
            }
        ])
        diaFooter.setTrailingActions([
            TopBarAction(symbolName: "archivebox", label: "Archive") { [weak self] in
                self?.toggleArchive()
            }
        ])
        archiveButton = diaFooter.actionButton(labelled: "Archive") as? IconButton

        // The downloads list hangs off that button rather than opening a window
        // of its own, so the manager is told where to find it. A closure, not
        // the view: the footer rebuilds its buttons whenever its actions are
        // set, and the manager must not be left holding one that is gone.
        DownloadManager.shared.listAnchor = { [weak self] in
            self?.diaFooter.actionButton(labelled: "Downloads")
        }

        // The archive takes the pins' and the tab list's place in this stack
        // rather than sitting over it: the sidebar is one surface, and what it
        // is showing is what it draws.
        archiveList.isHidden = true
        archiveList.onRestore = { [weak self] record in self?.restoreFromArchive(record) }
        archiveList.onForget = { [weak self] record in self?.confirmForgetFromArchive(record) }
        archiveList.onClear = { [weak self] in self?.confirmClearArchive() }

        // Everything above the footer lives in one stack of its own, because a
        // space switch moves it as a unit. Transforming four sibling views in
        // step is four chances for them to drift apart, and AppKit will happily
        // recompute one of their opacities halfway through the animation.
        let contentStack = NSStackView(views: [diaHeader, pinnedTiles, scrollView, archiveList])
        contentStack.orientation = .vertical
        // The bands of the sidebar -- title, shortcuts, tabs -- are different
        // kinds of thing, so the space between them is the gutter rather than
        // the tighter rhythm the rows inside a band keep.
        contentStack.spacing = Style.Metrics.elementSeparation
        contentStack.alignment = .leading
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.wantsLayer = true
        switchingContent = contentStack

        nowPlayingView.isHidden = true
        nowPlayingView.onSelectTab = { [weak self] tab in
            guard let self else { return }
            if let space = self.session.spaces.first(where: { $0.tabs.contains(where: { $0.id == tab.id }) }) {
                if space.id != self.session.activeSpaceID {
                    self.session.selectSpace(space)
                }
                self.session.selectTab(tab)
            }
        }

        let stack = NSStackView(views: [contentStack, nowPlayingView, diaFooter])
        stack.orientation = .vertical
        stack.spacing = Style.Metrics.elementSeparation
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        // The header owns the traffic-light strip, so the stack starts at the
        // very top of the sidebar rather than below a reserved band.
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            // The sidebar's content stops short of its trailing edge by the
            // same inset it starts from on the leading one. Without it the
            // pinned tiles and the tab pills run straight into the boundary
            // with the page, which reads as a crop rather than as a layout.
            stack.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -Style.Metrics.sidebarInset
            ),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            nowPlayingView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            diaHeader.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            diaFooter.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            archiveList.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            pinnedTiles.leadingAnchor.constraint(
                equalTo: contentStack.leadingAnchor,
                constant: Style.Metrics.sidebarInset
            ),
            pinnedTiles.trailingAnchor.constraint(lessThanOrEqualTo: contentStack.trailingAnchor),
            view.widthAnchor.constraint(
                // The split item's own minimum, not a second one derived from
                // the resting width. This constraint was the real floor: it held
                // the sidebar at 260 no matter what `minimumThickness` said.
                greaterThanOrEqualToConstant: Style.Metrics.sidebarMinWidth
            )
        ])
    }

    private func configureTableView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tab"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .inset
        tableView.rowHeight = Style.Metrics.rowHeight
        // Rows carry their own margins in their height, and a folder's plate
        // is drawn in slices that have to meet edge to edge.
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        // The row draws its own pill, inset and rounded, which the table's own
        // highlight cannot be.
        tableView.style = .plain
        tableView.selectionHighlightStyle = .none
        // A row's shadow is allowed to fall on its neighbours. The scroll view
        // still clips at the list's own edges, which is right.
        tableView.clipsToBounds = false
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = true
        tableView.dataSource = self
        tableView.delegate = self
        // A secondary click on a tab row gets the tab's menu; anywhere else
        // in the sidebar -- a folder header, the space under the list, the
        // tile strip -- gets the sidebar's. One menu object, refilled
        // just before it opens, because the table only reports which row was
        // clicked once the menu has been asked for.
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu
        view.menu = menu
        // Rows from this list, and addresses from anywhere: a link dragged
        // off a page or out of the address bar becomes a tab where it lands.
        tableView.registerForDraggedTypes([Self.tabRowType, Self.groupRowType, .URL])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    private func wireActions() {
    }

    // MARK: - Session updates

    private func subscribeToSession() {
        session.changes
            .sink { [weak self] change in
                guard let self else { return }
                switch change {
                case .spaces:
                    self.reloadSpaces()
                    self.reloadTabs()
                    self.reloadArchive()
                    self.refreshNowPlaying()
                case .tabs:
                    self.reloadTabs()
                    self.refreshArchiveBadge()
                    self.refreshNowPlaying()
                case .activeTab:
                    self.syncActiveTab()
                    self.refreshWash()
                    self.refreshNowPlaying()
                case .tab(let tab):
                    self.refreshRow(for: tab)
                    if tab.id == self.shownSpace.activeTab?.id { self.refreshWash() }
                    self.refreshNowPlaying()
                case .structure:
                    self.reloadTabs()
                    // Archiving, putting back, forgetting and a space's own
                    // groups all arrive as structure; only the archive cares
                    // which of them it was.
                    self.reloadArchive()
                    self.refreshNowPlaying()
                case .bookmarks:
                    break
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            forName: .tabMediaStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshNowPlaying()
            }
        }

        // A new density means new row heights, so every row is rebuilt.
        NotificationCenter.default.addObserver(
            forName: .sidebarDensityDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tableView.rowHeight = Style.Metrics.rowHeight
                self.reloadTabs()
            }
        }
    }

    private func findActiveMediaTab() -> Tab? {
        let all = session.allTabs
        return all.first(where: { $0.id == session.activeTab?.id && ($0.isPlayingMedia || $0.isPlayingAudio) })
            ?? all.first(where: { $0.isPlayingMedia || $0.isPlayingAudio })
            ?? all.first(where: { $0.isInPictureInPicture })
    }

    private func refreshNowPlaying() {
        nowPlayingView.update(with: findActiveMediaTab())
    }

    // MARK: - Switching animation

    /// Everything above the footer, as one view.
    ///
    /// The footer stays put on purpose. Its dots are the indicator for the
    /// switch, and an indicator that slides away with the thing it is indexing
    /// tells the user nothing during the one moment they need it.
    private var switchingContent: NSView?

    /// The outgoing space, held on screen while it travels out.
    private var outgoingStill: SpaceStillView?

    /// The neighbouring space, shown beside the live content while the fingers
    /// are down. The strip is a filmstrip from the first point of the drag:
    /// the space being pulled in is already visible, sliding in as the current
    /// one slides away. Without it the drag shows one space moving into empty
    /// material and the other appearing only after the release, which is what
    /// "it just suddenly came" described.
    private var neighbourStill: SpaceStillView?
    /// Which way `neighbourStill` is previewing: +1 for the next space.
    private var neighbourOffset = 0

    /// The space the sidebar is drawing instead of the active one, for the one
    /// moment the neighbour is photographed. Nil almost always.
    private var previewSpace: Space?

    /// A switch is animating, so the content is meant to be away from rest.
    private var isSwitching = false

    /// A switch is animating. A drag that started now would fight it.
    var isSwitchInFlight: Bool { isSwitching }

    /// The space the sidebar is currently drawing.
    private var shownSpace: Space { previewSpace ?? session.activeSpace }

    /// When the fingers last moved the content. A drag that never gets its end
    /// event -- a gesture claimed twice, a tracking loop that stops early --
    /// would otherwise leave the sidebar parked half off the screen with no way
    /// back, which is a far worse failure than a swipe that does nothing.
    private var lastDragTime: TimeInterval = 0

    /// Fires if a drag stops arriving without ever ending.
    private var dragWatchdog: DispatchWorkItem?

    /// Reduce Motion is a request not to slide things across the screen. The
    /// switch still happens; it just arrives rather than travels.
    private var reducesMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// A switch from rest -- a click on a dot -- takes about a
    /// quarter of a second. A release after a drag takes only the remaining
    /// distance's share of that, with a floor so a release from nearly there
    /// still reads as movement rather than a cut. The release from most of the
    /// way across lands in four or five frames.
    static let switchDuration: TimeInterval = 0.25
    static let minimumSwitchDuration: TimeInterval = 0.08

    /// Live feedback while the fingers are still down.
    ///
    /// No fading. Content keeps full opacity all the way through a switch; a
    /// swipe is a move, not a dissolve. What does change with the drag is the
    /// colour: the wash moves from this profile's colour towards the
    /// neighbour's as the neighbour comes in.
    func applySwipe(translation: CGFloat, crossfade: CGFloat) {
        guard !reducesMotion, let content = switchingContent else { return }
        lastDragTime = ProcessInfo.processInfo.systemUptime
        content.wantsLayer = true
        content.layer?.removeAnimation(forKey: Self.slideKey)
        content.layer?.setAffineTransform(CGAffineTransform(translationX: translation, y: 0))

        // Content moving towards the leading edge is the next space coming in
        // from the trailing one.
        let direction = translation < 0 ? 1 : (translation > 0 ? -1 : 0)
        if direction != neighbourOffset {
            discardNeighbourStill()
            if direction != 0 {
                neighbourStill = makeNeighbourStill(offset: direction)
                neighbourOffset = neighbourStill == nil ? 0 : direction
            }
        }
        let width = max(view.bounds.width, 1)
        neighbourStill?.offsetX = translation + width * CGFloat(direction)
        let neighbour = neighbourSpace(offset: direction)
        tint?.blend(toward: neighbour?.wash(for: neighbour?.activeTab), fraction: crossfade)
        onShownSpaceBlend?(neighbour, crossfade)

        // A reload is not guaranteed to follow, and a sidebar parked half off
        // the screen with nothing coming to put it back is the worst state this
        // can end in. So the drag also watches itself.
        dragWatchdog?.cancel()
        let watchdog = DispatchWorkItem { [weak self] in self?.abandonStalledDrag() }
        dragWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: watchdog)
    }

    /// The fingers stopped moving the content and no end ever arrived. Put it
    /// back rather than leaving it where it stopped.
    private func abandonStalledDrag() {
        guard !isSwitching, outgoingStill == nil, let content = switchingContent,
              let layer = content.layer, layer.animation(forKey: Self.slideKey) == nil,
              layer.affineTransform().tx != 0
        else { return }
        springBack(content, from: layer.affineTransform().tx)
        lastDragTime = 0
    }

    /// Back to rest from a drag that is not going to switch, with the colour
    /// following the content home.
    private func springBack(_ content: NSView, from tx: CGFloat) {
        let width = max(view.bounds.width, 1)
        let duration = Self.releaseDuration(remaining: abs(tx), width: width)
        slide(content, fromX: tx, toX: 0, duration: duration)
        if let still = neighbourStill {
            slide(still, fromX: still.offsetX, toX: width * CGFloat(neighbourOffset), duration: duration)
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                guard let self, neighbourStill === still else { return }
                discardNeighbourStill()
            }
        }
        tint?.show(shownSpace.wash(for: shownSpace.activeTab), animatedOver: duration)
        syncSidebarGradient(shownSpace, animatedOver: duration)
        onShownSpaceChange?(shownSpace, duration)
    }

    /// Sets the sidebar tint's gradient to a space's, fading it over the same
    /// time the wash takes. The page strip follows through `onGradientChange`
    /// and `onShownSpaceChange`.
    private func syncSidebarGradient(_ space: Space, animatedOver duration: TimeInterval) {
        guard let tint else { return }
        tint.transitionDuration = duration
        tint.gradientWash = space.washGradient(for: space.activeTab)
        tint.transitionDuration = 0
    }

    /// How long the rest of a switch takes: the full duration for the full
    /// width, proportionally less for what is left after a drag.
    static func releaseDuration(remaining: CGFloat, width: CGFloat) -> TimeInterval {
        guard width > 0 else { return minimumSwitchDuration }
        let share = max(0, min(1, remaining / width))
        return max(minimumSwitchDuration, switchDuration * share)
    }

    /// The swipe was abandoned, or it ran off the end of the row. Spring back
    /// to where it started.
    func cancelSwipe() {
        guard !reducesMotion, let content = switchingContent else { return }
        lastDragTime = 0
        dragWatchdog?.cancel()
        dragWatchdog = nil
        discardStill()
        springBack(content, from: content.layer?.affineTransform().tx ?? 0)
    }

    /// Runs the carousel: the outgoing space leaves by one edge while the
    /// incoming one arrives from the other, both at full opacity and both on
    /// screen at once.
    ///
    /// The sidebar has only one header, one tile strip and one tab list, so the
    /// space that is leaving has to be a photograph of itself. `dataWithPDF`
    /// takes it. The two obvious alternatives do not:
    /// `cacheDisplay(in:to:)` returns only what already sits in a layer's
    /// contents, which loses every pill, and `CALayer.render(in:)` returns
    /// nothing at all.
    ///
    /// - Parameter offset: which way the switch is going. +1 is forward, which
    ///   sends the outgoing space out by the leading edge.
    func animateSwitch(offset: Int, changeSpace: @escaping () -> Void) {
        guard !reducesMotion, let content = switchingContent else {
            changeSpace()
            applyRestImmediately()
            return
        }
        let width = max(view.bounds.width, 1)
        let step = width * CGFloat(offset)
        // Where the drag left the content; 0 for a switch from a click.
        let start = content.layer?.affineTransform().tx ?? 0
        isSwitching = true
        lastDragTime = 0
        dragWatchdog?.cancel()
        dragWatchdog = nil

        // Photographed before the space changes, and left exactly where the
        // live content was -- including however far the fingers had dragged it.
        discardStill()
        let still = makeStill(of: content)
        outgoingStill = still
        // The live content takes over from the preview at the same spot, and
        // the two are the same drawing, so the swap is not visible.
        discardNeighbourStill()

        // The strip is contiguous: the incoming space sits exactly one width
        // beyond the outgoing one, wherever the outgoing one is. Starting it
        // from the far edge instead left a gap the size of the drag, which is
        // what made it arrive suddenly.
        let incomingStart = start + step
        let duration = Self.releaseDuration(remaining: abs(incomingStart), width: width)

        tint?.transitionDuration = duration
        themeTransitionDuration = duration
        changeSpace()
        tint?.transitionDuration = 0
        themeTransitionDuration = 0
        // The new content has to be laid out before it is moved, or it arrives
        // and then jumps as the table resolves its rows.
        view.layoutSubtreeIfNeeded()

        slide(content, fromX: incomingStart, toX: 0, duration: duration)
        if let still {
            still.offsetX = start
            slide(still, fromX: start, toX: start - incomingStart, duration: duration)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.02) { [weak self] in
            guard let self, outgoingStill === still else { return }
            isSwitching = false
            discardStill()
        }
    }

    /// How long the page card is given to follow a theme change. Non-zero only
    /// for the duration of `changeSpace()` inside a switch.
    private var themeTransitionDuration: TimeInterval = 0

    /// A photograph of the space one step away, taken by drawing it into the
    /// sidebar for an instant and drawing the active space back before
    /// anything reaches the screen. Both reloads happen inside one turn of the
    /// run loop, so the window is never flushed showing the wrong space.
    private func makeNeighbourStill(offset: Int) -> SpaceStillView? {
        guard let content = switchingContent, let space = neighbourSpace(offset: offset) else { return nil }
        previewSpace = space
        reloadSpaces()
        reloadTabs()
        view.layoutSubtreeIfNeeded()
        let still = makeStill(of: content)
        previewSpace = nil
        reloadSpaces()
        reloadTabs()
        view.layoutSubtreeIfNeeded()
        return still
    }

    private func neighbourSpace(offset: Int) -> Space? {
        guard offset != 0,
              let index = session.spaces.firstIndex(where: { $0.id == session.activeSpaceID }),
              session.spaces.indices.contains(index + offset)
        else { return nil }
        return session.spaces[index + offset]
    }

    private func discardNeighbourStill() {
        neighbourStill?.removeFromSuperview()
        neighbourStill = nil
        neighbourOffset = 0
    }

    /// Nothing may leave the sidebar parked off to one side.
    ///
    /// Called from every reload, which is the one thing guaranteed to happen
    /// after any switch. A drag that is still live is left alone; one that has
    /// not moved for half a second has lost its end event and is abandoned.
    private func ensureContentAtRest() {
        guard !isSwitching, outgoingStill == nil, let content = switchingContent,
              let layer = content.layer, layer.animation(forKey: Self.slideKey) == nil,
              layer.affineTransform().tx != 0
        else { return }

        let sinceDrag = ProcessInfo.processInfo.systemUptime - lastDragTime
        guard lastDragTime == 0 || sinceDrag > 0.5 else { return }
        applyRestImmediately()
    }

    /// A copy of the live content, laid over it at rest.
    ///
    /// `convert` ignores the live content's layer transform, so the still
    /// lands where the content would be at rest however far it has been
    /// dragged; the caller sets `offsetX` to put it where it belongs.
    private func makeStill(of source: NSView) -> SpaceStillView? {
        let bounds = source.bounds
        guard bounds.width > 1, bounds.height > 1 else { return nil }

        // Via PDF, which is the printing path and calls `draw(_:)` on every view
        // in the tree rather than reading back what a layer happens to hold.
        guard let image = NSImage(data: source.dataWithPDF(inside: bounds)) else { return nil }
        image.size = bounds.size

        let still = SpaceStillView(image: image, restFrame: source.convert(bounds, to: view))
        view.addSubview(still)
        return still
    }

    private func discardStill() {
        outgoingStill?.removeFromSuperview()
        outgoingStill = nil
    }

    /// Moves the live content sideways, explicitly.
    ///
    /// `NSAnimationContext` with `allowsImplicitAnimation` does not do this.
    /// AppKit turns implicit animation off on a layer-backed view's layer, so a
    /// transform assigned inside an animation group snaps to its final value.
    private func slide(_ view: NSView, fromX: CGFloat, toX: CGFloat, duration: TimeInterval) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        layer.removeAnimation(forKey: Self.slideKey)

        // The model value first: an animation only covers the journey, and
        // whatever is set here is where the view stays afterwards.
        layer.setAffineTransform(CGAffineTransform(translationX: toX, y: 0))

        let move = CABasicAnimation(keyPath: "transform")
        move.fromValue = CATransform3DMakeTranslation(fromX, 0, 0)
        move.toValue = CATransform3DMakeTranslation(toX, 0, 0)
        move.duration = duration
        move.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(move, forKey: Self.slideKey)
    }

    /// Moves a still sideways. The still is positioned by its frame, so the
    /// journey is on the layer's position rather than a transform.
    private func slide(_ still: SpaceStillView, fromX: CGFloat, toX: CGFloat, duration: TimeInterval) {
        still.offsetX = toX
        guard let layer = still.layer else { return }
        layer.removeAnimation(forKey: Self.slideKey)

        let move = CABasicAnimation(keyPath: "position.x")
        move.fromValue = layer.position.x - (toX - fromX)
        move.toValue = layer.position.x
        move.duration = duration
        move.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(move, forKey: Self.slideKey)
    }

    private static let slideKey = "kylmora.slide"

    private func applyRestImmediately() {
        discardStill()
        discardNeighbourStill()
        guard let content = switchingContent else { return }
        content.layer?.removeAnimation(forKey: Self.slideKey)
        content.layer?.setAffineTransform(.identity)
        content.alphaValue = 1
        tint?.show(shownSpace.wash(for: shownSpace.activeTab), animatedOver: 0)
        syncSidebarGradient(shownSpace, animatedOver: 0)
        onShownSpaceChange?(shownSpace, 0)
    }

    private func reloadSpaces() {
        // Everything outside the sliding content is left alone while the
        // neighbour is being photographed: the dots, the menu and the colour
        // belong to the space that is actually active.
        if previewSpace == nil {
            ensureContentAtRest()
            rebuildSpaceMenu()
            diaFooter.showPages(
                count: session.spaces.count,
                selected: session.spaces.firstIndex { $0.id == session.activeSpaceID } ?? 0
            )
        }
        // One label, one concept: the space is the identity.
        let space = shownSpace
        diaHeader.spaceButton.show(
            title: space.name,
            accessibilityLabel: "Space",
            tooltip: space.isPrivate
                ? "\(space.name). Private: nothing is written to disk."
                : "\(space.name). Its own cookies and logins."
        )
        if previewSpace == nil {
            tint?.wash = space.wash(for: space.activeTab)
            syncSidebarGradient(space, animatedOver: themeTransitionDuration)
            onShownSpaceChange?(space, themeTransitionDuration)
        }
        refreshPinnedTiles()
    }

    /// Rebuilt whenever the space or the visible page changes, because which
    /// tile is active depends on both.
    private func refreshPinnedTiles() {
        let space = shownSpace
        let activeID = space.activeTab?.id
        pinnedTiles.show(
            space.pinnedSites.map { site in
                PinnedTile(
                    id: site.id.uuidString,
                    title: site.title,
                    url: site.url,
                    // The tab the shortcut owns, not a URL comparison: the
                    // site navigates away from the pinned address immediately
                    // and the tile would stop recognising its own page.
                    isActive: activeID != nil && space.tab(forPin: site.id)?.id == activeID
                )
            },
            isPrivate: space.isPrivate
        )
    }

    /// The space menu under the sidebar's title: every space with its colour,
    /// and the ways to make another -- a profile menu, for the one concept
    /// this browser has.
    private func rebuildSpaceMenu() {
        let space = session.activeSpace
        let menu = NSMenu()

        // A pull-down menu shows its first item as the title.
        let title = NSMenuItem(title: space.name, action: nil, keyEquivalent: "")
        title.image = space.isPrivate
            ? NSImage(systemSymbolName: "eyeglasses", accessibilityDescription: nil)
            : space.dotImage()
        menu.addItem(title)

        for (index, candidate) in session.spaces.enumerated() {
            let item = NSMenuItem(title: candidate.name, action: #selector(chooseSpace(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = candidate
            item.state = candidate === space ? .on : .off
            // The colour, not a glyph. The dot here and the wash on the window
            // are the same colour, which is what lets the menu be read as "the
            // green one" rather than as a list of names.
            item.image = candidate.isPrivate
                ? NSImage(systemSymbolName: "eyeglasses", accessibilityDescription: nil)
                : candidate.dotImage()
            // Control rather than Command: Command-1 through Command-9 already
            // select tabs by position.
            if let key = SpaceTheme.shortcut(forIndex: index) {
                item.keyEquivalent = key
                item.keyEquivalentModifierMask = .control
            }
            menu.addItem(item)
        }

        menu.addItem(.separator())
        for (title, selector, symbol) in [
            ("New Space\u{2026}", #selector(newSpaceFromMenu), "plus"),
            ("New Private Space\u{2026}", #selector(newPrivateSpaceFromMenu), "eyeglasses")
        ] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }

        menu.addItem(.separator())
        // Renaming, recolouring and deleting live in Settings, which shows the
        // whole set of spaces at once -- what those operations are about.
        let settingsItem = NSMenuItem(
            title: "Space Settings\u{2026}",
            action: #selector(showSpaceSettings),
            keyEquivalent: ""
        )
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settingsItem)

        let clearDataItem = NSMenuItem(
            title: "Clear Space Data\u{2026}",
            action: #selector(clearCurrentSpaceDataFromMenu),
            keyEquivalent: ""
        )
        clearDataItem.target = self
        clearDataItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        menu.addItem(clearDataItem)

        spaceMenuButton.menu = menu
        spaceMenuButton.toolTip = space.isPrivate
            ? "\(space.name) — nothing is written to disk"
            : space.name
    }

    @objc private func clearCurrentSpaceDataFromMenu() {
        NSApp.sendAction(#selector(BrowserWindowController.clearCurrentSpaceData(_:)), to: nil, from: self)
    }

    /// Recomputed on every rebuild; cheap, tens of tabs.
    private var duplicateIDs: Set<Tab.ID> = []

    /// The space the rows on screen belong to, so the next rebuild can tell a
    /// list that changed from a different list altogether.
    private var shownRowsSpaceID: Space.ID?

    private func reloadTabs() {
        duplicateIDs = session.duplicateTabIDs(in: shownSpace)
        if previewSpace == nil { ensureContentAtRest() }

        // Row animations are only meaningful *within* one space's list. Moving
        // to another space does not close ten tabs and open eight others -- it
        // shows a different list, which happens to be made of rows too, and
        // animating that produces exactly the churn it looks like: every row
        // sliding out while unrelated ones slide in.
        //
        // It also has to be instant rather than merely tidy. Switching spaces
        // photographs the neighbouring space by drawing it into the sidebar and
        // drawing the real one back before the window is flushed, twice in one
        // turn of the run loop (`makeNeighbourStill`). An animation started
        // there outlives the turn it was started in, so it is still running --
        // and visible -- long after the frame it was supposed to be invisible
        // for. The still-image crossfade is the space switch's animation, and
        // it is the only one it should have.
        let sameSpace = shownRowsSpaceID == shownSpace.id
        shownRowsSpaceID = shownSpace.id

        let before = rows.map(\.identity)
        rebuildRows()

        if sameSpace {
            applyRowChanges(from: before, to: rows.map(\.identity))
        } else {
            pendingEntrances = []
            tableView.reloadData()
        }
        syncActiveTab()
    }

    /// Hands the rebuild to the table as the change it actually was.
    ///
    /// `reloadData` is correct and was what this did, but it throws every row
    /// away and builds them again, so opening a tab and closing one look
    /// exactly alike: the list simply is different now. Telling the table which
    /// rows arrived and which left instead lets it open and close the gaps
    /// itself, and gives the arriving row something to spring out of.
    ///
    /// It falls back to `reloadData` whenever the change is not expressible as
    /// insertions and removals -- a reorder, or the first fill -- because a
    /// table told a half-truth about its own contents raises rather than
    /// misdraws, and a dragged tab is a reorder.
    private func applyRowChanges(from before: [SidebarRow.Identity], to after: [SidebarRow.Identity]) {
        pendingEntrances = []

        let removed: IndexSet
        let inserted: IndexSet
        switch RowChangePlan.change(from: before, to: after) {
        case .reload:
            tableView.reloadData()
            return
        case .contentOnly:
            // Nothing came or went, so nothing should move. A plain reload is
            // what this has always done and is still the right answer: the
            // rows are in their places and only what is drawn inside them has
            // changed, so there is no animation to preserve by being cleverer.
            tableView.reloadData()
            return
        case .edits(let removals, let insertions):
            removed = removals
            inserted = insertions
        }

        pendingEntrances = Set(inserted.map { after[$0] })

        tableView.beginUpdates()
        // Leaving is a collapse and a fade, which is AppKit's own and is
        // already the right shape: the gap the row occupied closes behind it.
        tableView.removeRows(at: removed, withAnimation: [.effectFade, .slideUp])
        // Arriving is a fade while the gap opens; the travel is added by the
        // cell itself, in `viewFor`, because only a spring can overshoot and
        // `NSTableView.AnimationOptions` has no spring in it.
        tableView.insertRows(at: inserted, withAnimation: .effectFade)
        tableView.endUpdates()

        refreshRows(excluding: inserted)
    }

    /// Brings the rows that kept their views across the update back up to date.
    ///
    /// Those views can be stale in two ways that matter: a tab's own content
    /// may have changed in the same breath, and -- more easily missed -- a row
    /// that did not itself change can still need redrawing because its
    /// *neighbour* did. A folder plate's rounded bottom belongs to whichever
    /// row is currently last inside it, so closing a tab hands that corner to
    /// the row above.
    ///
    /// The rows that were just inserted are excluded by index rather than by
    /// consulting `pendingEntrances`, which by now is empty: the table asks for
    /// their views during `endUpdates`, and each ask takes its row out of that
    /// set. Reloading them here would hand them a second, fresh view and throw
    /// away the entrance the first one was in the middle of.
    private func refreshRows(excluding inserted: IndexSet) {
        let kept = IndexSet(integersIn: rows.indices).subtracting(inserted)
        guard !kept.isEmpty else { return }
        tableView.reloadData(forRowIndexes: kept, columnIndexes: IndexSet(integer: 0))
        // The plates live on the row view rather than the cell, so reloading
        // the cells does not reach them.
        tableView.enumerateAvailableRowViews { [weak self] rowView, index in
            guard let self, let plate = rowView as? FolderPlateRowView else { return }
            plate.slices = self.slices.indices.contains(index) ? self.slices[index] : []
        }
        tableView.noteHeightOfRows(withIndexesChanged: kept)
    }

    /// Groups first, each followed by its tabs when open, then everything that
    /// belongs to no group. Order inside a group is the Space's own tab order,
    /// so grouping never reorders anything.
    private func rebuildRows() {
        let space = shownSpace
        var flattened: [SidebarRow] = []
        for row in FolderRowPlan.rows(
            groups: space.groups,
            // A pinned shortcut is represented by its tile; listing its tab as
            // well shows the same site twice.
            tabs: space.listedTabs,
            activeTabID: space.activeTabID
        ) {
            switch row {
            case .folder(let group, let depth, let showsEscapedTab):
                flattened.append(.group(group, depth: depth, showsEscapedTab: showsEscapedTab))
                // A live folder with nothing to show says which kind of nothing.
                if group.isLive, !group.isCollapsed {
                    let count = space.tabs(in: group).count
                    let status = session.liveFolders.status(for: group.id, itemCount: count)
                    if status != .ready {
                        flattened.append(.liveStatus(group, status, depth: depth + 1))
                    }
                }
            case .tab(let tab, let depth, let isEscaping):
                flattened.append(.tab(tab, depth: depth, isEscaping: isEscaping))
            }
        }
        flattened.append(.newTab)
        rows = flattened
        plates = FolderPlatePlan.pieces(for: dropRows)
        slices = buildSlices()
    }

    /// Resolves each plate slice with its group's colour and its band in the
    /// whole plate. The geometry needs row heights, which is why it lives here
    /// rather than in the pure `FolderPlatePlan`.
    private func buildSlices() -> [[FolderPlateSlice]] {
        let gap = Style.Metrics.folderPlateGap
        let appearances = Dictionary(
            shownSpace.groups.map { ($0.id, $0.appearance) },
            uniquingKeysWith: { first, _ in first }
        )

        // The rows each group's plate covers, header first, and the top offset
        // and full height each of those rows needs for a continuous fill.
        var geometry: [TabGroup.ID: [Int: (plateTop: CGFloat, plateHeight: CGFloat)]] = [:]
        var rowsOf: [TabGroup.ID: [Int]] = [:]
        for (index, pieces) in plates.enumerated() {
            for piece in pieces {
                guard let id = piece.groupID else { continue }
                rowsOf[id, default: []].append(index)
            }
        }
        for (id, indices) in rowsOf {
            let heights = indices.map { tableView(tableView, heightOfRow: $0) }
            let below = indices.last.map { plateGapBelow(row: $0) } ?? 0
            let placed = FolderPlateGeometry.slices(rowHeights: heights, gap: gap, gapBelow: below)
            var map: [Int: (plateTop: CGFloat, plateHeight: CGFloat)] = [:]
            for (offset, index) in indices.enumerated() where placed.indices.contains(offset) {
                map[index] = placed[offset]
            }
            geometry[id] = map
        }

        return plates.enumerated().map { index, pieces in
            pieces.map { piece in
                let appearance = piece.groupID.flatMap { appearances[$0] } ?? .standard
                let place = piece.groupID.flatMap { geometry[$0]?[index] }
                return FolderPlateSlice(
                    segment: piece.segment,
                    depth: piece.depth,
                    appearance: appearance,
                    plateTop: place?.plateTop ?? 0,
                    plateHeight: place?.plateHeight ?? 0,
                    // Only the slice that closes the plate carries the space
                    // under it; the rows above it are plate top to bottom.
                    gapBelow: piece.segment == .bottom || piece.segment == .single
                        ? plateGapBelow(row: index)
                        : 0
                )
            }
        }
    }

    private func row(of tab: Tab) -> Int? {
        rows.firstIndex {
            if case .tab(let candidate, _, _) = $0 { return candidate.id == tab.id }
            return false
        }
    }

    private func syncActiveTab() {
        let space = shownSpace
        if let tab = space.activeTab, let index = row(of: tab) {
            if !tableView.selectedRowIndexes.contains(index) {
                tableView.selectRowIndexes([index], byExtendingSelection: false)
            }
            // Selection can move from a keyboard shortcut or a menu item, which
            // is no help if the row is scrolled out of sight.
            tableView.scrollRowToVisible(index)
        } else {
            tableView.deselectAll(nil)
        }
        // Rows draw their own selection, so every visible one has to be told.
        for index in rows.indices {
            let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? TabRowView
            cell?.isSelected = tableView.selectedRowIndexes.contains(index)
        }
        // Which tile is active depends on the visible page, so it moves with it.
        refreshPinnedTiles()
    }

    /// The wash can change without the space changing: a page in front
    /// declared a colour, or a different tab came to the front.
    private func refreshWash() {
        guard previewSpace == nil else { return }
        let space = shownSpace
        let wash = space.wash(for: space.activeTab)
        let gradient = space.washGradient(for: space.activeTab)
        guard tint?.wash != wash || tint?.gradientWash != gradient else { return }
        tint?.wash = wash
        tint?.gradientWash = gradient
        onWashChange?(wash)
        onGradientChange?(gradient)
    }

    private func refreshRow(for tab: Tab) {
        guard let index = row(of: tab),
              let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? TabRowView
        else { return }
        // The depth has to come back out of the row plan. Re-configuring with a
        // default of 0 was un-indenting whichever row refreshed -- in practice
        // the selected one, which refreshes on every title change -- so a tab
        // inside a folder drifted out to sit with the loose ones.
        configure(cell, with: tab, depth: depth(ofRow: index))
    }

    /// How long a tab has been idle, as the badge shows it, or `nil` when there
    /// is nothing worth showing.
    ///
    /// A tab that is on screen never carries one, whatever the setting says.
    /// `lastActiveAt` is stamped when a tab becomes visible and not again while
    /// it stays there, so the tab being read right now would otherwise wear a
    /// timer counting how long it has been read -- true of the clock, and a lie
    /// about what the badge means.
    private func idleText(for tab: Tab) -> String? {
        // A tab that reloads itself says so in the badge's place; so does one
        // that another tab duplicates.
        if tab.autoReloadInterval != nil { return "↻" }
        if duplicateIDs.contains(tab.id) { return "⧉" }
        guard settings.tabIdleBadgeMode.showsBadge(isAsleep: tab.isAsleep),
              !session.visibleTabIDs.contains(tab.id)
        else { return nil }
        return TabIdleLabel.text(for: tab.idleDuration())
    }

    private func idleSpoken(for tab: Tab) -> String? {
        if tab.autoReloadInterval != nil { return "reloads automatically" }
        if duplicateIDs.contains(tab.id) { return "another tab shows the same page" }
        guard idleText(for: tab) != nil else { return nil }
        return TabIdleLabel.spoken(for: tab.idleDuration())
    }

    /// Re-reads the timer on every row on screen.
    ///
    /// Only the badge, and only where the string actually changed: the rows
    /// themselves are untouched, so this cannot disturb a favicon, a selection
    /// or a row the user is dragging.
    private func tickIdleBadges() {
        guard settings.tabIdleBadgeMode != .never else { return }
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        for index in visible.lowerBound..<visible.upperBound {
            guard rows.indices.contains(index), case .tab(let tab, _, _) = rows[index],
                  let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? TabRowView
            else { continue }
            cell.updateIdle(text: idleText(for: tab), spoken: idleSpoken(for: tab))
        }
    }

    /// The nesting level a row is drawn at, or 0 for anything that is not a tab.
    private func depth(ofRow index: Int) -> Int {
        guard rows.indices.contains(index), case .tab(_, let depth, _) = rows[index] else { return 0 }
        return depth
    }

    /// The one place a `Tab` becomes the plain values a `TabRowView` takes.
    private func configure(_ cell: TabRowView, with tab: Tab, depth: Int) {
        // The same leading inset the group headers use, so a tab that belongs
        // to no folder lines up with a top-level folder rather than sitting
        // four points further out and running its pill into the sidebar edge.
        cell.indentation = Style.Metrics.sidebarInset + FolderTree.indent(forDepth: depth)
        cell.configure(TabRowContent(
            title: tab.displayTitle,
            address: tab.note.map { "\(tab.url.absoluteString)\n\($0)" } ?? tab.url.absoluteString,
            isLoading: tab.isLoading,
            isAsleep: tab.isAsleep,
            isFailed: tab.failure != nil,
            idleText: idleText(for: tab),
            idleSpoken: idleSpoken(for: tab),
            keepsAwake: tab.keepsAwake,
            keepsInSidebar: tab.keepsInSidebar,
            isLocked: tab.isLocked,
            isPlayingAudio: tab.isPlayingAudio,
            isMuted: tab.isMuted,
            colorTag: tab.colorTag,
            hasUnreadChange: tab.hasUnreadChange && !session.visibleTabIDs.contains(tab.id),
            emoji: tab.emoji
        ))
        cell.onToggleMute = { [weak tab] in
            tab?.toggleMute()
        }
        // `tab.url` deliberately, not `displayURL`: the latter follows a typed
        // address before it commits, which would swap one site's icon for
        // another's mid-keystroke.
        cell.favicon.show(for: tab.url, in: tab.currentWebView, isPrivate: tab.isPrivate)
        cell.onClose = { [weak self] in
            guard let self else { return }
            guard !tab.isLocked else { return session.reportCloseRefused(tab) }
            guard TabClosing.confirm(closing: tab) else { return }
            session.closeTab(tab)
        }
    }

    // MARK: - Archive

    /// Whether the sidebar is showing the archive instead of a space's tabs.
    private(set) var isShowingArchive = false

    /// Shows or hides the archive in place of the pins and the tab list.
    ///
    /// A mode rather than a window. The archive holds the rows that left the
    /// sidebar, so the place they left from is the place to look for them. The
    /// space's own list is kept up to date while the archive is in front of it,
    /// which is what makes leaving the mode instant, and what makes a tab put
    /// back land somewhere the user can see.
    func setArchiveVisible(_ visible: Bool) {
        guard visible != isShowingArchive else { return }
        isShowingArchive = visible
        pinnedTiles.isHidden = visible
        scrollView.isHidden = visible
        archiveList.isHidden = !visible
        archiveButton?.isActive = visible
        if visible { reloadArchive() }
    }

    func toggleArchive() { setArchiveVisible(!isShowingArchive) }

    @objc private func toggleArchiveFromMenu() { toggleArchive() }

    /// The archive of the space the sidebar is showing, newest first -- the
    /// order someone hunting for "the thing that just vanished" reads in.
    ///
    /// One space at a time, because that is what an archive in a sidebar means.
    /// A tab left a space's list; the place to look for it is the foot of that
    /// same list, and a Work tab showing up under Personal is the archive
    /// answering a question nobody asked. Switching space switches the archive
    /// with it, which is why a space change reloads this.
    ///
    /// The rows carry no space name for the same reason: every one of them is
    /// from the space whose sidebar they are being shown in.
    private func reloadArchive() {
        archiveList.show(
            session.archivedTabs(in: shownSpace)
                .map { ArchiveListView.Entry(record: $0, spaceName: nil) },
            isArchivingEnabled: settings.tabArchiveDelay != nil
        )
        refreshArchiveBadge()
    }

    /// The count on the footer's Archive button.
    ///
    /// The button carries it whether or not the archive is open: an archive is
    /// a drawer things disappear into, and the point of a number on the outside
    /// of a drawer is that you can see there is something in it without opening
    /// it.
    ///
    /// Separate from `reloadArchive` because it is also wanted on a plain tab
    /// change: putting one back through the toast's Undo arrives as `.tabs`,
    /// and the badge would otherwise sit there still counting a tab that is
    /// back in the sidebar.
    ///
    /// It counts this space's archive only, so it agrees with the list the
    /// button opens. A badge counting every space would send someone into an
    /// archive that turns out to be empty.
    private func refreshArchiveBadge() {
        archiveButton?.badgeCount = session.archivedTabs(in: shownSpace).count
    }

    /// Puts one back and goes to it: restoring a tab is an act of wanting to
    /// read the page. The list stays in the archive, so several can be put back
    /// without leaving the mode and coming back to it.
    private func restoreFromArchive(_ record: BrowserSession.ArchivedTab) {
        session.restoreArchived(record)
        reloadArchive()
    }

    /// Asks first. The archive is itself the undo for everything else, so
    /// forgetting is the one thing here that cannot be taken back.
    private func confirmForgetFromArchive(_ record: BrowserSession.ArchivedTab) {
        confirm(
            message: "Remove \u{201c}\(record.title)\u{201d} from the archive?",
            detail: "It will not come back. Put it back in the sidebar instead if you still want it.",
            action: "Remove"
        ) { [weak self] in
            self?.session.forgetArchived(record)
        }
    }

    private func confirmClearArchive() {
        let space = shownSpace
        let count = session.archivedTabs(in: space).count
        guard count > 0 else { return }
        // Named, because Clear under a list that shows one space's archive must
        // not read as though it empties the browser's.
        confirm(
            message: "Remove \(count) archived tab\(count == 1 ? "" : "s") from \(space.name)?",
            detail: "This clears this Space's archive. Other Spaces keep theirs. They will not come back.",
            action: "Remove"
        ) { [weak self] in
            self?.session.clearArchive(in: space)
        }
    }

    /// A confirmation, as a sheet when there is a window to hang it on and as a
    /// plain alert when there is not -- the same reading the group and space
    /// questions use.
    private func confirm(
        message: String,
        detail: String,
        action: String,
        then commit: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        if let window = view.window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { commit() }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            commit()
        }
    }

    // MARK: - Actions

    @objc private func newTab() {
        session.newTab()
    }

    @objc private func goBack() { session.activeTab?.goBack() }
    @objc private func goForward() { session.activeTab?.goForward() }
    /// One control, two jobs: stop while loading, reload otherwise.
    @objc private func reload() {
        guard let tab = session.activeTab else { return }
        if tab.isLoading {
            tab.stopLoading()
        } else {
            tab.reload()
        }
    }

    /// The responder chain does not reach the app delegate from a menu built
    /// here, so the target is named rather than left to `nil`.
    @objc private func showSpaceSettings() {
        NSApp.sendAction(#selector(AppDelegate.showSpaceSettings(_:)), to: NSApp.delegate, from: nil)
    }

    @objc private func chooseSpace(_ sender: NSMenuItem) {
        guard let space = sender.representedObject as? Space else { return }
        session.selectSpace(space)
    }

    @objc private func newSpaceFromMenu() { promptForNewSpace() }
    @objc private func newPrivateSpaceFromMenu() { promptForNewPrivateSpace() }

    private func promptForNewSpace() { presentNewSpaceSheet(initialPrivate: false) }
    private func promptForNewPrivateSpace() { presentNewSpaceSheet(initialPrivate: true) }

    /// The sheet that names a space and picks its colour -- solid or a gradient
    /// with a direction -- in one step, so a space is its colour from the moment
    /// it is made.
    private func presentNewSpaceSheet(initialPrivate: Bool) {
        let sheet = NewSpaceSheet(
            suggestedColor: session.nextUnusedTheme().color,
            initialPrivate: initialPrivate
        ) { [weak self] options in
            guard let self else { return }
            let space = session.addSpace(named: options.name, isPrivate: options.isPrivate)
            if options.keepsItsOwnColour {
                switch options.wash {
                case .solid(let colour):
                    session.setCustomColor(colour, for: space)
                case .gradient(let gradient):
                    session.setSpaceGradient(gradient, for: space)
                }
            } else {
                // A plain window, or one the page colours: the space carries no
                // colour of its own. Exactly what the Spaces pane does when you
                // choose anything but Customized.
                session.setTheme(.neutral, for: space)
            }
            // The rest of the sheet, applied in one go: appearance, how
            // strongly the colour washes, and whether the bookmarks bar shows.
            // The colour above went through the session's own setters because
            // each clears the other's fill; these are plain fields of the look.
            session.setLook(options.look(from: space.look), for: space)
        }
        presentAsSheet(sheet)
    }

    // MARK: - Context menu

    /// The sidebar menu, reached with a two-finger click on the sidebar.
    ///
    /// The window-level items -- new tab, reopen, hide sidebar, compact mode
    /// -- have no target and go up the responder chain, so they are the same
    /// items the menu bar has and are validated by the same code. The rest
    /// act on the sidebar's own session.
    func makeContextMenu() -> NSMenu {
        let menu = NSMenu()

        let newTab = NSMenuItem(title: "New Tab", action: #selector(BrowserWindowController.newTab(_:)), keyEquivalent: "t")
        newTab.image = NSImage(systemSymbolName: "plus.square", accessibilityDescription: nil)
        menu.addItem(newTab)
        let reopen = NSMenuItem(
            title: "Reopen Closed Tab",
            action: #selector(BrowserWindowController.reopenClosedTab(_:)),
            keyEquivalent: "t"
        )
        reopen.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(reopen)

        menu.addItem(.separator())
        let newGroup = NSMenuItem(title: "New Group", action: #selector(newGroupFromMenu), keyEquivalent: "")
        newGroup.target = self
        newGroup.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
        menu.addItem(newGroup)

        let live = NSMenuItem(title: "New Live Group", action: nil, keyEquivalent: "")
        let liveMenu = NSMenu()
        for (title, selector) in [
            ("RSS Feed\u{2026}", #selector(newRSSGroupFromMenu)),
            ("GitHub Pull Requests\u{2026}", #selector(newGitHubPullRequestsGroupFromMenu)),
            ("GitHub Issues\u{2026}", #selector(newGitHubIssuesGroupFromMenu))
        ] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            liveMenu.addItem(item)
        }
        live.submenu = liveMenu
        menu.addItem(live)

        menu.addItem(.separator())
        let newSpace = NSMenuItem(title: "New Space\u{2026}", action: #selector(newSpaceFromMenu), keyEquivalent: "")
        newSpace.target = self
        newSpace.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        menu.addItem(newSpace)

        menu.addItem(.separator())
        // Named with its count. An archive is easy to forget you have, and
        // "Archive (12)" is the only thing in this menu that answers a question
        // the user has not thought to ask yet.
        let archived = session.archivedTabs(in: shownSpace).count
        let archive = NSMenuItem(
            title: archived == 0 ? "Archive\u{2026}" : "Archive (\(archived))\u{2026}",
            action: #selector(toggleArchiveFromMenu),
            keyEquivalent: ""
        )
        archive.target = self
        archive.image = NSImage(systemSymbolName: "archivebox", accessibilityDescription: nil)
        menu.addItem(archive)

        menu.addItem(.separator())
        let bookmarkAll = NSMenuItem(title: "Bookmark All Tabs", action: #selector(bookmarkAllTabsFromMenu), keyEquivalent: "")
        bookmarkAll.target = self
        bookmarkAll.image = NSImage(systemSymbolName: "bookmark", accessibilityDescription: nil)
        menu.addItem(bookmarkAll)

        menu.addItem(.separator())
        let hideSidebar = NSMenuItem(
            title: "Hide Sidebar",
            action: #selector(BrowserWindowController.toggleKylmoraSidebar(_:)),
            keyEquivalent: "s"
        )
        hideSidebar.keyEquivalentModifierMask = [.command, .control]
        hideSidebar.image = NSImage(systemSymbolName: "sidebar.leading", accessibilityDescription: nil)
        menu.addItem(hideSidebar)
        let compact = NSMenuItem(
            title: "Compact Mode",
            action: #selector(BrowserWindowController.toggleCompactMode(_:)),
            keyEquivalent: "c"
        )
        compact.keyEquivalentModifierMask = [.command, .control]
        menu.addItem(compact)

        menu.addItem(.separator())
        let closeAll = NSMenuItem(title: "Close All Tabs in Space", action: #selector(closeAllTabsInSpaceFromMenu(_:)), keyEquivalent: "")
        closeAll.target = self
        closeAll.image = NSImage(systemSymbolName: "xmark.square", accessibilityDescription: nil)
        closeAll.isEnabled = !shownSpace.tabs.isEmpty
        menu.addItem(closeAll)

        return menu
    }

    /// The tab menu. Move to Window and Change Icon are not offered: Kylmora
    /// has one window, and a tab's icon is its site's.
    func makeTabMenu(for tab: Tab) -> NSMenu {
        let menu = NSMenu()
        let space = session.activeSpace
        func add(_ title: String, _ selector: Selector, symbol: String? = nil, key: String = "",
                 modifiers: NSEvent.ModifierFlags = .command, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = self
            item.representedObject = tab
            item.isEnabled = enabled
            if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            menu.addItem(item)
        }
        menu.autoenablesItems = false

        add("Pin", #selector(pinTabFromMenu(_:)), symbol: "pin", enabled: !session.isPinned(tab))
        menu.addItem(.separator())

        // The two locks and the two manual actions, in one block: they are the
        // whole of what a user can say about this tab's lifecycle, and finding
        // half of them here and half in Settings is how a feature becomes
        // folklore. Each lock reads as what it will do next, not as its state.
        add(tab.keepsAwake ? "Allow Sleeping" : "Keep Awake",
            #selector(toggleKeepAwakeFromMenu(_:)),
            symbol: tab.keepsAwake ? "moon" : "sun.max")
        add(tab.isLocked ? "Unlock" : "Lock",
            #selector(toggleLockedFromMenu(_:)),
            symbol: tab.isLocked ? "lock.open.fill" : "lock.fill")
        add(tab.keepsInSidebar ? "Allow Archiving" : "Keep in Sidebar",
            #selector(toggleKeepInSidebarFromMenu(_:)),
            symbol: tab.keepsInSidebar ? "clock" : "clock.badge.xmark",
            // Archiving off means there is nothing to be kept from, and an
            // enabled switch that guards against nothing is a puzzle.
            enabled: settings.tabArchiveDelay != nil)
        // Sleeping the tab you are looking at would blank it, so the one tab
        // that cannot be put to sleep is the visible one.
        add("Sleep Now", #selector(sleepTabFromMenu(_:)), symbol: "moon.zzz",
            enabled: tab.isLoaded && !session.visibleTabIDs.contains(tab.id))
        add("Archive Now", #selector(archiveTabFromMenu(_:)), symbol: "archivebox",
            enabled: !session.isPinned(tab) && !shownSpace.isPrivate)
        menu.addItem(.separator())
        add("Open as Split", #selector(splitTabFromMenu(_:)), symbol: "rectangle.split.2x1",
            enabled: space.tabs.count > 1)
        add("Duplicate", #selector(duplicateTabFromMenu(_:)), symbol: "plus.square.on.square")
        menu.addItem(.separator())
        add("New Group with Tab", #selector(newGroupWithTabFromMenu(_:)), symbol: "folder.badge.plus",
            key: "n", modifiers: [.control, .command])
        let move = NSMenuItem(title: "Move to Space", action: nil, keyEquivalent: "")
        move.image = NSImage(systemSymbolName: "square.stack", accessibilityDescription: nil)
        let spaces = NSMenu()
        for candidate in session.spaces where candidate !== space {
            let item = NSMenuItem(title: candidate.name, action: #selector(moveTabToSpaceFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [tab, candidate]
            item.image = candidate.isPrivate
                ? NSImage(systemSymbolName: "eyeglasses", accessibilityDescription: nil)
                : candidate.dotImage()
            spaces.addItem(item)
        }
        move.submenu = spaces
        move.isEnabled = !spaces.items.isEmpty
        menu.addItem(move)
        menu.addItem(.separator())
        add("Rename\u{2026}", #selector(renameTabFromMenu(_:)), symbol: "pencil")
        let colour = NSMenuItem(title: "Colour Tag", action: nil, keyEquivalent: "")
        colour.image = NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: nil)
        let colours = NSMenu()
        let none = NSMenuItem(title: "None", action: #selector(setTabColorFromMenu(_:)), keyEquivalent: "")
        none.target = self
        none.representedObject = [tab]
        none.state = tab.colorTag == nil ? .on : .off
        colours.addItem(none)
        for tag in TabColorTag.allCases {
            let item = NSMenuItem(title: tag.title, action: #selector(setTabColorFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [tab, tag.rawValue]
            item.image = tag.dotImage()
            item.state = tab.colorTag == tag ? .on : .off
            colours.addItem(item)
        }
        colour.submenu = colours
        menu.addItem(colour)
        let reloadItem = NSMenuItem(title: "Auto Reload", action: nil, keyEquivalent: "")
        reloadItem.image = NSImage(systemSymbolName: "arrow.clockwise.circle", accessibilityDescription: nil)
        let intervals = NSMenu()
        let off = NSMenuItem(title: "Off", action: #selector(setAutoReloadFromMenu(_:)), keyEquivalent: "")
        off.target = self
        off.representedObject = [tab]
        off.state = tab.autoReloadInterval == nil ? .on : .off
        intervals.addItem(off)
        for seconds in Tab.autoReloadChoices {
            let item = NSMenuItem(title: Self.autoReloadTitle(seconds), action: #selector(setAutoReloadFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [tab, seconds]
            item.state = tab.autoReloadInterval == seconds ? .on : .off
            intervals.addItem(item)
        }
        reloadItem.submenu = intervals
        menu.addItem(reloadItem)
        add(tab.note == nil ? "Add Note\u{2026}" : "Edit Note\u{2026}", #selector(editNoteFromMenu(_:)), symbol: "note.text")
        add(tab.emoji == nil ? "Set Emoji\u{2026}" : "Change Emoji\u{2026}", #selector(editEmojiFromMenu(_:)), symbol: "face.smiling")
        menu.addItem(.separator())
        // Greyed rather than hidden. A Close that has gone missing looks like
        // a bug in the menu; a Close that is there and cannot be pressed,
        // directly under an item that says "Unlock", explains itself.
        add("Close", #selector(closeTabFromMenu(_:)), symbol: "xmark", key: "w",
            enabled: !tab.isLocked)
        add("Close Other Tabs", #selector(closeOtherTabsFromMenu(_:)), enabled: space.tabs.count > 1)
        let isLast = space.index(of: tab).map { $0 == space.tabs.count - 1 } ?? true
        add("Close Tabs Below", #selector(closeTabsBelowFromMenu(_:)), enabled: !isLast)
        add("Close All Tabs in Space", #selector(closeAllTabsInSpaceFromMenu(_:)), symbol: "xmark.square")
        return menu
    }

    /// The right-click menu on a group header: rename, recolour, fold, remove.
    func makeGroupMenu(for group: TabGroup) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ selector: Selector, symbol: String? = nil) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            item.representedObject = group
            if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            menu.addItem(item)
        }
        if !group.isLive {
            add("Rename\u{2026}", #selector(renameGroupFromMenu(_:)), symbol: "pencil")
            add("Customize Appearance\u{2026}", #selector(customizeGroupFromMenu(_:)), symbol: "paintpalette")
            menu.addItem(.separator())
        }
        add(group.isCollapsed ? "Expand" : "Collapse",
            #selector(toggleGroupCollapsedFromMenu(_:)),
            symbol: group.isCollapsed ? "chevron.down" : "chevron.right")
        // A whole group can go to another space, the way a single tab can. A
        // live folder is provider-managed, so it stays where it was set up.
        if !group.isLive {
            let others = session.spaces.filter { $0.group(withID: group.id) == nil }
            let move = NSMenuItem(title: "Move to Space", action: nil, keyEquivalent: "")
            move.image = NSImage(systemSymbolName: "square.stack", accessibilityDescription: nil)
            let spaces = NSMenu()
            for candidate in others {
                let item = NSMenuItem(title: candidate.name, action: #selector(moveGroupToSpaceFromMenu(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = [group, candidate]
                item.image = candidate.isPrivate
                    ? NSImage(systemSymbolName: "eyeglasses", accessibilityDescription: nil)
                    : candidate.dotImage()
                spaces.addItem(item)
            }
            move.submenu = spaces
            move.isEnabled = !spaces.items.isEmpty
            menu.addItem(move)
        }
        menu.addItem(.separator())
        add(group.isLocked ? "Unlock Folder" : "Lock Folder",
            #selector(toggleGroupLockedFromMenu(_:)),
            symbol: group.isLocked ? "lock.open.fill" : "lock.fill")
        let remove = NSMenuItem(title: "Remove Group", action: #selector(removeGroupFromMenu(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = group
        remove.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        remove.isEnabled = !group.isLocked
        menu.addItem(remove)
        return menu
    }

    @objc private func moveGroupToSpaceFromMenu(_ sender: Any?) {
        guard let pair = (sender as? NSMenuItem)?.representedObject as? [Any],
              pair.count == 2, let group = pair[0] as? TabGroup, let space = pair[1] as? Space
        else { return }
        session.move(group, toSpace: space)
    }

    private func group(from sender: Any?) -> TabGroup? {
        (sender as? NSMenuItem)?.representedObject as? TabGroup
    }

    @objc private func renameGroupFromMenu(_ sender: Any?) {
        guard let group = group(from: sender),
              let name = prompt(title: "Rename Group", message: "Name this group.", initial: group.name)
        else { return }
        session.rename(group, to: name)
    }

    @objc private func customizeGroupFromMenu(_ sender: Any?) {
        guard let group = group(from: sender) else { return }
        openAppearanceEditor(for: group)
    }

    @objc private func toggleGroupCollapsedFromMenu(_ sender: Any?) {
        guard let group = group(from: sender) else { return }
        session.toggleCollapsed(group)
    }

    @objc private func removeGroupFromMenu(_ sender: Any?) {
        guard let group = group(from: sender) else { return }
        confirmRemoveGroup(group)
    }

    /// Confirms removing a group. The tabs move to the main list unless the
    /// user turns on "Delete all tabs in this group", which closes them too.
    private func confirmRemoveGroup(_ group: TabGroup) {
        let name = group.name.isEmpty ? "this group" : "\u{201c}\(group.name)\u{201d}"
        let alert = NSAlert()
        alert.messageText = "Delete the group \(name)?"
        alert.informativeText = "Its tabs move to the main list. Turn on the option below to close them instead."
        let closeTabs = NSButton(checkboxWithTitle: "Delete all tabs in this group", target: nil, action: nil)
        closeTabs.state = .off
        closeTabs.sizeToFit()
        closeTabs.frame = NSRect(x: 0, y: 0, width: max(closeTabs.frame.width, 260), height: closeTabs.frame.height)
        alert.accessoryView = closeTabs
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        let commit = { [weak self] (response: NSApplication.ModalResponse) in
            guard response == .alertFirstButtonReturn else { return }
            self?.session.removeGroup(group, closingTabs: closeTabs.state == .on)
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: commit)
        } else {
            commit(alert.runModal())
        }
    }

    /// Shows the appearance editor beside a group's header. Anchored to the
    /// table rather than the header cell, which `reloadData` throws away on
    /// every live change, so the popover stays put while the user drags a well.
    private func openAppearanceEditor(for group: TabGroup) {
        guard let row = groupRow(of: group) else { return }
        let editor = GroupAppearanceEditor(
            appearance: group.appearance,
            tint: group.tint,
            name: group.name
        ) { [weak self] appearance in
            self?.session.setAppearance(appearance, for: group)
        }
        let popover = NSPopover()
        popover.contentViewController = editor
        // Semitransient, not transient: the colour panel is another window, and
        // a transient popover would close the moment the user clicked into it.
        popover.behavior = .semitransient
        appearancePopover = popover
        popover.show(relativeTo: tableView.rect(ofRow: row), of: tableView, preferredEdge: .maxX)
    }

    private func groupRow(of group: TabGroup) -> Int? {
        rows.firstIndex {
            if case .group(let candidate, _, _) = $0 { return candidate.id == group.id }
            return false
        }
    }

    private func tab(from sender: Any?) -> Tab? {
        (sender as? NSMenuItem)?.representedObject as? Tab
    }

    @objc private func pinTabFromMenu(_ sender: Any?) {
        guard let tab = tab(from: sender) else { return }
        session.pin(tab)
    }

    /// Keeping a tab awake does not wake it. The switch says what happens from
    /// here, and reloading a page the user cannot see -- to honour a preference
    /// they set for later -- would spend memory to obey the letter of a setting
    /// against its point.
    @objc private func toggleKeepAwakeFromMenu(_ sender: Any?) {
        guard let tab = tab(from: sender) else { return }
        tab.setKeepsAwake(!tab.keepsAwake)
    }

    @objc private func toggleKeepInSidebarFromMenu(_ sender: Any?) {
        guard let tab = tab(from: sender) else { return }
        tab.setKeepsInSidebar(!tab.keepsInSidebar)
    }

    @objc private func toggleLockedFromMenu(_ sender: Any?) {
        guard let tab = tab(from: sender) else { return }
        tab.setLocked(!tab.isLocked)
    }

    @objc private func toggleGroupLockedFromMenu(_ sender: Any?) {
        guard let group = group(from: sender) else { return }
        session.setLocked(!group.isLocked, for: group)
    }

    /// Sleeps one tab by hand. Clearing "Keep Awake" first, because asking for
    /// this while the lock is on is the clearest possible statement that the
    /// lock is no longer wanted -- and silently doing nothing would look broken.
    @objc private func sleepTabFromMenu(_ sender: Any?) {
        guard let tab = tab(from: sender) else { return }
        tab.setKeepsAwake(false)
        session.suspend([tab])
    }

    /// Archives one tab by hand, with no threshold and no waiting. Same reading
    /// of an explicit request as above: the locks that exist to stop this
    /// happening *automatically* do not stop the user doing it deliberately.
    @objc private func archiveTabFromMenu(_ sender: Any?) {
        guard let tab = tab(from: sender) else { return }
        session.archive([tab])
    }

    /// The clicked tab beside the visible one; or, when it is the visible
    /// one, beside its neighbour, which is what the Split menu items do.
    @objc private func splitTabFromMenu(_ sender: Any?) {
        guard let tab = tab(from: sender) else { return }
        let tabs = session.activeSpace.tabs
        if let current = session.activeTab, current !== tab {
            session.splitTabs([current, tab], grid: .sideBySide)
            return
        }
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        let partner = tabs.indices.contains(index + 1) ? tabs[index + 1]
            : tabs.indices.contains(index - 1) ? tabs[index - 1]
            : nil
        guard let partner else { return }
        session.splitTabs([tab, partner], grid: .sideBySide)
    }

    @objc private func duplicateTabFromMenu(_ sender: Any?) {
        guard let tab = tab(from: sender) else { return }
        session.duplicate(tab)
    }

    @objc private func newGroupWithTabFromMenu(_ sender: Any?) {
        guard let tab = tab(from: sender),
              let name = prompt(title: "New Group", message: "Name this group.", initial: "")
        else { return }
        session.createGroup(named: name, containing: [tab])
    }

    @objc private func moveTabToSpaceFromMenu(_ sender: Any?) {
        guard let pair = (sender as? NSMenuItem)?.representedObject as? [Any],
              pair.count == 2, let tab = pair[0] as? Tab, let space = pair[1] as? Space
        else { return }
        session.move(tab, toSpace: space)
    }

    static func autoReloadTitle(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "Every \(Int(seconds)) seconds" : "Every \(Int(seconds / 60)) minute\(seconds == 60 ? "" : "s")"
    }

    @objc private func setAutoReloadFromMenu(_ sender: Any?) {
        guard let payload = (sender as? NSMenuItem)?.representedObject as? [Any],
              let tab = payload.first as? Tab else { return }
        let seconds = payload.count > 1 ? payload[1] as? TimeInterval : nil
        tab.setAutoReload(every: seconds)
        session.showToast?(Toast(
            symbolName: "arrow.clockwise.circle",
            message: seconds.map { "Reloading \(Self.autoReloadTitle($0).lowercased())" } ?? "Auto reload off",
            identity: "auto-reload"
        ))
    }

    @objc private func editEmojiFromMenu(_ sender: Any?) {
        guard let tab = tab(from: sender) else { return }
        guard let emoji = TextPrompt.ask(
            title: "Emoji for This Tab",
            message: "Shown in place of the favicon. Leave it empty to go back to the favicon.",
            initial: tab.emoji ?? "", placeholder: "🚀", confirm: "Set", width: 120
        ) else { return }
        tab.setEmoji(emoji)
    }

    @objc private func editNoteFromMenu(_ sender: Any?) {
        guard let tab = tab(from: sender) else { return }
        guard let note = TextPrompt.ask(
            title: tab.note == nil ? "Add a Note" : "Edit the Note",
            message: "Shown when you hover the tab. Leave it empty to remove the note.",
            initial: tab.note ?? "", placeholder: "Why this tab is open", confirm: "Save", width: 280
        ) else { return }
        tab.setNote(note)
    }

    @objc private func setTabColorFromMenu(_ sender: Any?) {
        guard let payload = (sender as? NSMenuItem)?.representedObject as? [Any],
              let tab = payload.first as? Tab else { return }
        let tag = (payload.count > 1 ? payload[1] as? String : nil).flatMap(TabColorTag.init(rawValue:))
        session.setColorTag(tag, for: tab)
    }

    @objc private func renameTabFromMenu(_ sender: Any?) {
        guard let tab = tab(from: sender) else { return }
        // The current custom name, or nothing: clearing the field puts the
        // page's own title back, so the prompt must not seed it with
        // a title the user never typed.
        guard let name = TextPrompt.ask(
            title: "Rename Tab",
            message: "Leave it empty to go back to the page's own title.",
            initial: tab.customName ?? "", placeholder: tab.displayTitle, width: 220
        ) else { return }
        session.rename(tab, to: name)
    }

    /// The deliberate, single-tab close. Refusal is reported here rather than
    /// swallowed, unlike the sweeps below, which step around a locked tab
    /// without comment because stepping around it is the point.
    @objc private func closeTabFromMenu(_ sender: Any?) {
        guard let tab = tab(from: sender) else { return }
        session.closeTab(tab)
    }

    @objc private func closeOtherTabsFromMenu(_ sender: Any?) {
        guard let tab = tab(from: sender) else { return }
        session.closeOtherTabs(than: tab)
    }

    @objc private func closeTabsBelowFromMenu(_ sender: Any?) {
        guard let tab = tab(from: sender) else { return }
        session.closeTabs(below: tab)
    }

    /// Context menu presented when multiple tabs are selected in the sidebar.
    func makeMultiTabMenu(for tabs: [Tab]) -> NSMenu {
        let menu = NSMenu()
        let space = session.activeSpace
        menu.autoenablesItems = false

        let count = tabs.count
        let reloadItem = NSMenuItem(title: "Reload \(count) Tabs", action: #selector(reloadSelectedTabsFromMenu(_:)), keyEquivalent: "r")
        reloadItem.target = self
        reloadItem.representedObject = tabs
        reloadItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        menu.addItem(reloadItem)

        let duplicateItem = NSMenuItem(title: "Duplicate \(count) Tabs", action: #selector(duplicateSelectedTabsFromMenu(_:)), keyEquivalent: "")
        duplicateItem.target = self
        duplicateItem.representedObject = tabs
        duplicateItem.image = NSImage(systemSymbolName: "plus.square.on.square", accessibilityDescription: nil)
        menu.addItem(duplicateItem)

        let allPinned = tabs.allSatisfy { session.isPinned($0) }
        let pinTitle = allPinned ? "Unpin \(count) Tabs" : "Pin \(count) Tabs"
        let pinItem = NSMenuItem(title: pinTitle, action: #selector(pinSelectedTabsFromMenu(_:)), keyEquivalent: "")
        pinItem.target = self
        pinItem.representedObject = tabs
        pinItem.image = NSImage(systemSymbolName: "pin", accessibilityDescription: nil)
        menu.addItem(pinItem)

        menu.addItem(.separator())

        let groupItem = NSMenuItem(title: "New Group with \(count) Tabs", action: #selector(newGroupWithSelectedTabsFromMenu(_:)), keyEquivalent: "")
        groupItem.target = self
        groupItem.representedObject = tabs
        groupItem.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
        menu.addItem(groupItem)

        let moveItem = NSMenuItem(title: "Move to Space", action: nil, keyEquivalent: "")
        moveItem.image = NSImage(systemSymbolName: "square.stack", accessibilityDescription: nil)
        let spacesMenu = NSMenu()
        for candidate in session.spaces where candidate !== space {
            let item = NSMenuItem(title: candidate.name, action: #selector(moveSelectedTabsToSpaceFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [tabs, candidate]
            item.image = candidate.isPrivate
                ? NSImage(systemSymbolName: "eyeglasses", accessibilityDescription: nil)
                : candidate.dotImage()
            spacesMenu.addItem(item)
        }
        moveItem.submenu = spacesMenu
        moveItem.isEnabled = !spacesMenu.items.isEmpty
        menu.addItem(moveItem)

        menu.addItem(.separator())

        let closeItem = NSMenuItem(title: "Close \(count) Tabs", action: #selector(closeSelectedTabsFromMenu(_:)), keyEquivalent: "w")
        closeItem.target = self
        closeItem.representedObject = tabs
        closeItem.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        menu.addItem(closeItem)

        let otherCount = shownSpace.tabs.filter { candidate in
            !tabs.contains(where: { $0.id == candidate.id }) && !session.isPinned(candidate)
        }.count
        let closeOthersItem = NSMenuItem(title: "Close Other Tabs", action: #selector(closeOtherThanSelectedTabsFromMenu(_:)), keyEquivalent: "")
        closeOthersItem.target = self
        closeOthersItem.representedObject = tabs
        closeOthersItem.isEnabled = otherCount > 0
        menu.addItem(closeOthersItem)

        let closeAllItem = NSMenuItem(title: "Close All Tabs in Space", action: #selector(closeAllTabsInSpaceFromMenu(_:)), keyEquivalent: "")
        closeAllItem.target = self
        closeAllItem.image = NSImage(systemSymbolName: "xmark.square", accessibilityDescription: nil)
        closeAllItem.isEnabled = !shownSpace.tabs.isEmpty
        menu.addItem(closeAllItem)

        return menu
    }

    @objc private func reloadSelectedTabsFromMenu(_ sender: Any?) {
        guard let tabs = (sender as? NSMenuItem)?.representedObject as? [Tab] else { return }
        session.reloadTabs(tabs)
    }

    @objc private func duplicateSelectedTabsFromMenu(_ sender: Any?) {
        guard let tabs = (sender as? NSMenuItem)?.representedObject as? [Tab] else { return }
        session.duplicateTabs(tabs)
    }

    @objc private func pinSelectedTabsFromMenu(_ sender: Any?) {
        guard let tabs = (sender as? NSMenuItem)?.representedObject as? [Tab] else { return }
        let allPinned = tabs.allSatisfy { session.isPinned($0) }
        for tab in tabs {
            if allPinned {
                session.unpin(tab)
            } else if !session.isPinned(tab) {
                session.pin(tab)
            }
        }
    }

    @objc private func newGroupWithSelectedTabsFromMenu(_ sender: Any?) {
        guard let tabs = (sender as? NSMenuItem)?.representedObject as? [Tab],
              let name = prompt(title: "New Group", message: "Name this group.", initial: "")
        else { return }
        session.createGroup(named: name, containing: tabs)
    }

    @objc private func moveSelectedTabsToSpaceFromMenu(_ sender: Any?) {
        guard let pair = (sender as? NSMenuItem)?.representedObject as? [Any],
              pair.count == 2, let tabs = pair[0] as? [Tab], let space = pair[1] as? Space
        else { return }
        session.moveTabs(tabs, toSpace: space)
    }

    @objc private func closeSelectedTabsFromMenu(_ sender: Any?) {
        guard let tabs = (sender as? NSMenuItem)?.representedObject as? [Tab] else { return }
        session.closeTabs(tabs)
    }

    @objc private func closeOtherThanSelectedTabsFromMenu(_ sender: Any?) {
        guard let tabs = (sender as? NSMenuItem)?.representedObject as? [Tab] else { return }
        let toClose = shownSpace.tabs.filter { candidate in
            !tabs.contains(where: { $0.id == candidate.id }) && !session.isPinned(candidate)
        }
        session.closeTabs(toClose)
    }

    @objc func closeAllTabsInSpaceFromMenu(_ sender: Any?) {
        session.closeAllTabs(in: shownSpace)
    }

    @objc private func newGroupFromMenu() {
        guard let name = prompt(title: "New Group", message: "Name this group.", initial: "") else { return }
        session.createGroup(named: name)
    }

    @objc private func newRSSGroupFromMenu() {
        guard let text = prompt(title: "New Live Group",
                                message: "The address of an RSS or Atom feed. The group is named after the feed once it loads.",
                                initial: "https://"),
              let url = URL(string: text), url.host() != nil
        else { return }
        session.createLiveGroup(source: .rss(RSSLiveFolderProvider.Configuration(feedURL: url)))
    }

    @objc private func newGitHubPullRequestsGroupFromMenu() { newGitHubGroup(scope: .pullRequests) }
    @objc private func newGitHubIssuesGroupFromMenu() { newGitHubGroup(scope: .issues) }

    private func newGitHubGroup(scope: GitHubLiveFolderProvider.Scope) {
        let noun = scope == .pullRequests ? "pull requests" : "issues"
        guard let login = prompt(title: "New Live Group",
                                 message: "The GitHub account whose \(noun) the group follows.",
                                 initial: "") else { return }
        session.createLiveGroup(source: .github(GitHubLiveFolderProvider.Configuration(login: login, scope: scope)))
    }

    @objc private func bookmarkAllTabsFromMenu() {
        session.bookmarkAllTabs()
    }

    /// Small modal text prompt. AppKit has no stock one-field input sheet, so an
    /// alert with an accessory field is the shortest honest version.
    private func prompt(title: String, message: String, initial: String) -> String? {
        guard let name = TextPrompt.ask(title: title, message: message, initial: initial, width: 220), !name.isEmpty else { return nil }
        return name
    }
}

// MARK: - AddressBarDelegate

// MARK: - Tab list

extension SidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        let clicked = tableView.clickedRow
        let source: NSMenu
        let selection = selectedTabs
        if selection.count > 1, clicked >= 0, tableView.selectedRowIndexes.contains(clicked) {
            source = makeMultiTabMenu(for: selection)
        } else if rows.indices.contains(clicked), case .tab(let tab, _, _) = rows[clicked] {
            source = makeTabMenu(for: tab)
        } else if rows.indices.contains(clicked), case .group(let group, _, _) = rows[clicked] {
            source = makeGroupMenu(for: group)
        } else {
            source = makeContextMenu()
        }
        // Items belong to one menu at a time, so they are moved rather than
        // shared.
        let items = source.items
        source.removeAllItems()
        menu.items = items
        menu.autoenablesItems = source.autoenablesItems
    }
}

extension SidebarViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    /// A folder's header row is taller by the gap its plate leaves above it,
    /// and the row that ends a plate by the space the plate leaves below its
    /// last pill, so the card has clearance at both ends.
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return Style.Metrics.rowHeight }
        if case .group = rows[row] {
            return Style.Metrics.groupHeaderHeight + Style.Metrics.folderPlateGap
                + plateGapBelow(row: row)
        }
        // The row that owns a plate's rounded bottom corners owns the padding
        // under them too. `plates` is rebuilt with `rows`, so it is already in
        // step by the time the table asks for a height -- including the asks
        // that come from `buildSlices`, which is why this reads `plates`
        // rather than the slices it is in the middle of computing.
        guard plates.indices.contains(row), plates[row].contains(where: { $0.segment == .bottom }) else {
            return Style.Metrics.rowHeight + plateGapBelow(row: row)
        }
        return Style.Metrics.rowHeight + Style.Metrics.folderPlateBottomPadding
            + plateGapBelow(row: row)
    }

    /// Clear space a card leaves under itself, before whatever comes next.
    ///
    /// A card is fenced off above by `folderPlateGap`, carried by its header's
    /// row. Nothing carried the same below it, so a card followed by a loose
    /// tab left three points between the card's edge and that tab's pill --
    /// less than the six two plain rows keep between each other. The card read
    /// as having caught the row underneath it.
    ///
    /// Nothing is added when the next row is another card's header, because
    /// that header already brings the gap with it, or when the next row is
    /// still inside a plate this row is also in, because that plate has not
    /// ended yet.
    private func plateGapBelow(row: Int) -> CGFloat {
        guard plates.indices.contains(row), !plates[row].isEmpty else { return 0 }
        let next = row + 1
        guard rows.indices.contains(next) else { return 0 }
        if case .group = rows[next] { return 0 }
        let mine = Set(plates[row].compactMap(\.groupID))
        let theirs = Set(plates.indices.contains(next) ? plates[next].compactMap(\.groupID) : [])
        guard mine.isDisjoint(with: theirs) else { return 0 }
        return Style.Metrics.folderPlateGap
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = tableView.makeView(
            withIdentifier: FolderPlateRowView.reuseIdentifier,
            owner: self
        ) as? FolderPlateRowView ?? {
            let view = FolderPlateRowView()
            view.identifier = FolderPlateRowView.reuseIdentifier
            return view
        }()
        view.slices = slices.indices.contains(row) ? slices[row] : []
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let cell = cellView(for: rows[row], row: row)
        // A row the table has just been told to insert springs in from the
        // leading edge. Done here rather than after the batch because this is
        // the one moment the view certainly exists: a row scrolled out of sight
        // is never built, and never needs an entrance either.
        if let cell, pendingEntrances.remove(rows[row].identity) != nil {
            SpringPresence.slideIn(cell, from: CGVector(dx: -Style.Motion.entrySlide, dy: 0))
        }
        return cell
    }

    private func cellView(for sidebarRow: SidebarRow, row: Int) -> NSView? {
        switch sidebarRow {
        case .group(let group, let depth, _):
            return groupHeaderCell(for: group, depth: depth)
        case .liveStatus(_, let status, let depth):
            return liveStatusCell(status, depth: depth)
        case .newTab:
            return newTabRowCell()
        case .tab(let tab, let depth, _):
            let cell = tableView.makeView(
                withIdentifier: TabRowView.reuseIdentifier,
                owner: self
            ) as? TabRowView ?? {
                let cell = TabRowView()
                cell.identifier = TabRowView.reuseIdentifier
                return cell
            }()
            configure(cell, with: tab, depth: depth)
            cell.isSelected = tableView.selectedRowIndexes.contains(row)
            // A row with plate slices sits on a group plate, where its pill
            // needs a matching trailing margin so it does not run flush into
            // the plate's rounded right edge.
            cell.isInGroupPlate = slices.indices.contains(row) && !slices[row].isEmpty
            return cell
        }
    }

    /// The header carries its own height, so it is placed inside the taller row
    /// rather than fighting the table's row height.
    private func groupHeaderCell(for group: TabGroup, depth: Int) -> NSView {
        let header = TabGroupHeaderView()
        header.show(
            emoji: group.emoji,
            name: group.name,
            isExpanded: !group.isCollapsed,
            isLocked: group.isLocked
        )
        header.onToggle = { [weak self] _ in self?.session.toggleCollapsed(group) }
        // The cross asks first, and by default keeps the tabs (they come back
        // out as loose rows); the confirmation offers to close them instead.
        header.onRemove = { [weak self] in self?.confirmRemoveGroup(group) }
        // A live folder is named and coloured by its provider, so it is not
        // offered the appearance editor.
        if !group.isLive {
            header.onCustomize = { [weak self] in self?.openAppearanceEditor(for: group) }
        }

        let container = NSView()
        container.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(
                equalTo: container.leadingAnchor,
                constant: Style.Metrics.sidebarInset + FolderTree.indent(forDepth: depth)
            ),
            // Full width, not hugging its text: the hover plate then covers the
            // same span as the pill on the tab rows underneath, which is what
            // makes a folder read as one block rather than as a caption with a
            // list beside it.
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            // Under the gap, measured from the top -- not centred, and not
            // pinned to the bottom. The header's row is taller than the header
            // by the gap above the plate, and, when the plate ends on this same
            // row, by the gap under it as well: an empty folder, or a collapsed
            // one, is a plate one row tall. Pinned to the bottom, the header
            // then sat in that lower gap, a clear ten points below the plate it
            // names -- a rounded card with the title hanging out underneath it.
            header.topAnchor.constraint(
                equalTo: container.topAnchor,
                constant: Style.Metrics.folderPlateGap
            )
        ])
        return container
    }

    /// Styled as a row so it reads as the end of the list rather than as a
    /// button parked next to it.
    private func newTabRowCell() -> NSView {
        let header = ActionRowView()
        header.show(symbolName: "plus", title: "New Tab")
        header.onPress = { [weak self] in self?.newTab() }

        let container = NSView()
        container.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(
                equalTo: container.leadingAnchor,
                constant: Style.Metrics.sidebarInset
            ),
            header.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            header.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        return container
    }

    /// A live folder that is fetching, empty or failed says so in a row of its
    /// own rather than looking like an ordinary empty folder.
    private func liveStatusCell(_ status: LiveFolderStatus, depth: Int) -> NSView {
        let view = LiveFolderStatusView()
        view.show(status, indent: FolderTree.indent(forDepth: depth))

        let container = NSView()
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(
                equalTo: container.leadingAnchor,
                constant: Style.Metrics.sidebarInset
            ),
            view.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            // At the top, not centred: a status row that ends a plate is taller
            // than its text, and the extra height belongs under the text, with
            // the plate's bottom edge, rather than under the row's top edge.
            view.topAnchor.constraint(equalTo: container.topAnchor)
        ])
        return container
    }

    /// A group header and the New Tab row are controls, not destinations;
    /// selecting either would give the list a selection that names no page.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard rows.indices.contains(row) else { return false }
        if case .tab = rows[row] { return true }
        return false
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // A click that lands on nothing selectable -- the empty space below the
        // list, a folder header, the New Tab row -- makes `NSTableView` clear
        // its selection. The tab in front has not changed, so the sidebar must
        // not stop saying which tab that is: the pill would vanish while the
        // page it names is still on screen, and nothing in the window would
        // answer "which of these am I looking at?".
        //
        // The table's selection is put back on the active tab rather than the
        // pill being drawn from somewhere else, so that the selection the rest
        // of this file reads -- the multi-tab menu, the keyboard, the drag --
        // stays the truth. Re-selecting posts this notification again, and the
        // second pass takes the ordinary path.
        if tableView.selectedRowIndexes.isEmpty,
           let active = shownSpace.activeTab, let index = row(of: active) {
            tableView.selectRowIndexes([index], byExtendingSelection: false)
            return
        }

        let selectedIndexes = tableView.selectedRowIndexes
        for index in rows.indices {
            let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? TabRowView
            cell?.isSelected = selectedIndexes.contains(index)
        }
        let targetRow = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        if rows.indices.contains(targetRow), case .tab(let tab, _, _) = rows[targetRow] {
            if session.activeTab?.id != tab.id {
                session.selectTab(tab)
            }
        }
    }

    // Drag reordering, using AppKit's own table-view drag machinery.

    /// The dragged payload is the tab's index in the Space, not the visual row:
    /// group headers make the two differ, and the Space is what a move acts on.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard rows.indices.contains(row) else { return nil }
        // A top-level group header is draggable to reorder the groups. Only a
        // root: a nested group is held in place by its parent, so dragging its
        // row would look like it moved while nothing changed.
        if case .group(let group, let depth, _) = rows[row], depth == 0 {
            let item = NSPasteboardItem()
            item.setString(group.id.uuidString, forType: Self.groupRowType)
            return item
        }
        guard case .tab(let tab, _, _) = rows[row],
              let index = session.activeSpace.index(of: tab) else {
            return nil
        }
        let item = NSPasteboardItem()
        item.setString(String(index), forType: Self.tabRowType)
        return item
    }

    /// What is being dragged, or nil for something this list does not take.
    private enum DropPayload {
        case tab(Tab, index: Int)
        case link(URL)
        case group(TabGroup)
    }

    private func dropPayload(from info: any NSDraggingInfo) -> DropPayload? {
        let pasteboard = info.draggingPasteboard
        if let id = pasteboard.pasteboardItems?
            .compactMap({ $0.string(forType: Self.groupRowType) })
            .compactMap(UUID.init(uuidString:))
            .first,
           let group = session.activeSpace.group(withID: id) {
            return .group(group)
        }
        if let index = pasteboard.pasteboardItems?
            .compactMap({ $0.string(forType: Self.tabRowType) })
            .compactMap(Int.init)
            .first {
            let tabs = session.activeSpace.tabs
            guard tabs.indices.contains(index) else { return nil }
            return .tab(tabs[index], index: index)
        }
        if let url = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first {
            return .link(url)
        }
        return nil
    }

    /// Where dropping the dragged group would put it: just before this root
    /// group, or nil to send it past the last one. The first root header at or
    /// below the drop row that is not the dragged group itself.
    private func groupReorderTarget(dropRow: Int, dragged: TabGroup) -> TabGroup? {
        for index in max(0, dropRow)..<rows.count {
            if case .group(let candidate, 0, _) = rows[index], candidate.id != dragged.id {
                return candidate
            }
        }
        return nil
    }

    /// The sidebar's rows in the shape the drop plan reads.
    private var dropRows: [TabDropPlan.Row] {
        rows.map { row in
            switch row {
            case .group(let group, let depth, _): return .folder(group, depth: depth)
            case .tab(let tab, let depth, let isEscaping): return .tab(tab, depth: depth, isEscaping: isEscaping)
            case .liveStatus(_, _, let depth): return .other(depth: depth)
            case .newTab: return .other(depth: 0)
            }
        }
    }

    /// Where a drop at this row would land, after the table has been told
    /// which row and operation to show. Nil refuses the drop.
    ///
    /// Shared by validation and acceptance, so what the indicator promised is
    /// what the drop does. A folder header is the one place the pointer's
    /// position within the row matters (`FolderDropZone`); everywhere else the
    /// drop is between rows, and a drop *on* a tab is treated as above it.
    private func dropDestination(
        _ info: any NSDraggingInfo,
        payload: DropPayload,
        row: Int,
        operation: NSTableView.DropOperation
    ) -> TabDropPlan.Destination? {
        let space = session.activeSpace
        if rows.indices.contains(row), case .group(let folder, _, _) = rows[row],
           let header = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) {
            let zonePayload: FolderDragPayload
            switch payload {
            case .tab(let tab, _): zonePayload = .tab(tab)
            case .link: zonePayload = .link
            // A dragged group reorders the groups; it is handled before this is
            // ever reached, and never files itself into a folder.
            case .group: return nil
            }
            let target = FolderDropZone.target(
                at: header.convert(info.draggingLocation, from: nil),
                in: header.bounds,
                isFlipped: header.isFlipped,
                folder: folder,
                tabCount: space.tabs(in: folder).count,
                payload: zonePayload,
                groups: space.groups
            )
            if case .afterFolder = target {
                let after = TabDropPlan.rowAfterBlock(of: row, rows: dropRows)
                tableView.setDropRow(after, dropOperation: .above)
                return TabDropPlan.onto(folder: folder, target: target, tabs: space.tabs, groups: space.groups)
            }
            guard target.highlightsFolder else { return nil }
            tableView.setDropRow(row, dropOperation: .on)
            return TabDropPlan.onto(folder: folder, target: target, tabs: space.tabs, groups: space.groups)
        }

        tableView.setDropRow(row, dropOperation: .above)
        return TabDropPlan.between(rows: dropRows, row: row, tabs: space.tabs, groups: space.groups)
    }

    private func isTabSplitDrop(row: Int, payload: DropPayload, operation: NSTableView.DropOperation) -> Bool {
        guard rows.indices.contains(row), case .tab(let targetTab, _, _) = rows[row] else { return false }
        switch payload {
        case .tab(let draggedTab, _):
            return draggedTab.id != targetTab.id && (operation == .on || NSEvent.modifierFlags.contains(.option))
        case .link:
            return operation == .on || NSEvent.modifierFlags.contains(.option)
        case .group:
            return false
        }
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: any NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard let payload = dropPayload(from: info) else { return [] }
        // A group drag reorders the top-level groups: the line goes between
        // rows and the move is always allowed (a drop on itself is a no-op).
        if case .group = payload {
            tableView.setDropRow(max(0, row), dropOperation: .above)
            return .move
        }
        if isTabSplitDrop(row: row, payload: payload, operation: dropOperation) {
            tableView.setDropRow(row, dropOperation: .on)
            return .move
        }
        guard dropDestination(info, payload: payload, row: row, operation: dropOperation) != nil
        else { return [] }
        if case .link = payload { return .copy }
        return .move
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: any NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let payload = dropPayload(from: info) else { return false }
        // A group drag reorders the top-level groups rather than moving a tab.
        if case .group(let dragged) = payload {
            session.moveGroup(dragged, before: groupReorderTarget(dropRow: row, dragged: dragged))
            return true
        }
        if dropOperation == .on, rows.indices.contains(row), case .tab(let targetTab, _, _) = rows[row] {
            switch payload {
            case .tab(let draggedTab, _):
                guard draggedTab.id != targetTab.id else { return false }
                session.splitTabs([targetTab, draggedTab], grid: .sideBySide)
                return true
            case .link(let url):
                let newTab = session.newTab(url: url, select: false)
                session.splitTabs([targetTab, newTab], grid: .sideBySide)
                return true
            case .group:
                break
            }
        }
        guard let destination = dropDestination(info, payload: payload, row: row, operation: dropOperation)
        else { return false }
        let space = session.activeSpace
        let group = destination.groupID.flatMap { space.group(withID: $0) }

        switch payload {
        case .tab(let tab, let index):
            session.moveTab(from: index, to: destination.tabIndex)
            session.move(tab, to: group)
        case .link(let url):
            // Made at the end and then moved, which is the one path every
            // new tab already takes, rather than a second way to insert one.
            let tab = session.newTab(url: url, select: false)
            if let index = space.index(of: tab) {
                session.moveTab(from: index, to: destination.tabIndex)
            }
            session.move(tab, to: group)
        case .group:
            // Handled above, before the tab destination is resolved.
            return true
        }
        return true
    }
}

/// A photograph of one space's sidebar content, placed by frame.
///
/// By frame and not by a layer transform, because AppKit owns the geometry of a
/// layer it backs a view with and puts the transform back to identity on the
/// next layout pass. Measured: a still given a translation of 91 points logged
/// that translation and drew at 0. The live content gets away with a transform
/// only because nothing lays it out again mid-drag.
@MainActor
private final class SpaceStillView: NSImageView {
    /// Where the content sits at rest, in the sidebar's coordinates.
    private let restFrame: NSRect

    /// How far from rest the still is, in points.
    var offsetX: CGFloat = 0 {
        didSet { frame = restFrame.offsetBy(dx: offsetX, dy: 0) }
    }

    init(image: NSImage, restFrame: NSRect) {
        self.restFrame = restFrame
        super.init(frame: restFrame)
        self.image = image
        imageScaling = .scaleNone
        autoresizingMask = []
        wantsLayer = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        fatalError("SpaceStillView is created in code only")
    }
}
