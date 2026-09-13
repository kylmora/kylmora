import AppKit
import Combine
import WebKit

/// The browser's model root: every Space, every Tab, and which of each is
/// showing. It is the only place the model is mutated, so it is also the only
/// place changes are announced, and the seam where persistence plugs in.
///
/// Views subscribe to `changes` and refresh the smallest thing they can. A
/// coarse `objectWillChange`-style signal would reload the whole sidebar on
/// every keystroke of a page title.
@MainActor
final class BrowserSession {
    enum Change {
        /// The set of spaces, or which space is active, changed.
        case spaces
        /// The active space's tab list changed (added, removed, reordered).
        case tabs
        /// A different tab became active.
        case activeTab
        /// One tab's displayed state changed.
        case tab(Tab)
        /// The bookmark list changed.
        case bookmarks
        /// A tab group or a pinned site changed. The sidebar's structure, not
        /// just its contents, has to be rebuilt.
        case structure
    }

    let changes = PassthroughSubject<Change, Never>()

    /// How the session tells the user something happened somewhere they are not
    /// looking. Set by the window; nil in tests and before a window exists, so
    /// a toast stays a side effect the model can do without.
    var showToast: ((Toast) -> Void)?

    /// Rules that decide which space a URL opens in. Loaded once; inert until
    /// the user writes a rule.
    let routing = SpaceRoutingService()

    /// Keeps live folders' contents up to date. Owned here because the sidebar
    /// draws its state and the application services its requests, and both need
    /// the same instance.
    let liveFolders = LiveFolderManager()

    private(set) var spaces: [Space] = []
    private(set) var activeSpaceID: Space.ID
    private(set) var bookmarks: [Bookmark] = []

    private let database: BrowserDatabase?
    private let sessionStore: SessionStore
    private let settings: Settings
    private var tabSubscriptions: [Tab.ID: AnyCancellable] = [:]
    /// The split shown in each space, if it has one. Keyed by space because a
    /// split is a property of a set of tabs, and tabs belong to a space.
    private var splitsBySpace: [Space.ID: SplitLayout] = [:]
    private var saveTask: Task<Void, Never>?

    /// Writing on every keystroke of a page title would be wasteful; a short
    /// delay collapses a burst of changes into one write.
    private static let saveDelay = Duration.seconds(1)

    init(database: BrowserDatabase?, sessionStore: SessionStore = SessionStore(), settings: Settings = .shared) {
        self.database = database
        self.sessionStore = sessionStore
        self.settings = settings

        let restored = settings.restoresSession ? sessionStore.load() : nil

        if let restored, let spaces = Self.spaces(from: restored), !spaces.isEmpty {
            self.spaces = spaces
            let index = min(max(restored.activeSpaceIndex, 0), spaces.count - 1)
            self.activeSpaceID = spaces[index].id
            // The archive is filed by space, and a snapshot names spaces by
            // position -- `spaces(from:)` maps one to one, so zipping is the
            // pairing, and a space that somehow did not come back takes its
            // archive with it rather than orphaning the records onto another.
            self.archivedTabs = zip(spaces, restored.spaces).flatMap { space, stored in
                (stored.archivedTabs ?? []).map {
                    ArchivedTab(snapshot: $0.tab, spaceID: space.id, archivedAt: $0.archivedAt)
                }
            }
            for space in spaces {
                for tab in space.tabs { adopt(tab) }
                // A private space is saved without its tabs, so it comes back
                // with one fresh one rather than as an empty list.
                if space.tabs.isEmpty {
                    insert(Tab(url: settings.newTabURL(isPrivate: space.isPrivate), identity: space.identity), into: space, at: 0, select: true)
                }
            }
        } else {
            // The first space keeps WebKit's default store, so anything browsed
            // before spaces had their own identity is still signed in.
            let personal = Space(name: "Personal", identity: .standard, theme: .blue)
            self.spaces = [personal]
            self.activeSpaceID = personal.id
            newTab()
        }

        liveFolders.delegate = self
        loadBookmarks()
    }

    // MARK: - Spaces

    var activeSpace: Space {
        spaces.first { $0.id == activeSpaceID } ?? spaces[0]
    }

    var activeTab: Tab? { activeSpace.activeTab }

    /// Adds a space with an identity of its own: fresh cookies, no logins.
    ///
    /// - Parameters:
    ///   - isPrivate: nothing the space browses is written to disk, and its
    ///     tabs are not saved.
    ///   - theme: the colour, or nil for the next one no space is using, so
    ///     two spaces made in a row are told apart without a visit to Settings.
    @discardableResult
    func addSpace(named name: String, isPrivate: Bool = false, theme: SpaceTheme? = nil) -> Space {
        let space = Space(
            name: name,
            identity: isPrivate ? .makeEphemeral() : .makeIsolated(),
            theme: theme ?? nextUnusedTheme()
        )
        spaces.append(space)
        activeSpaceID = space.id
        changes.send(.spaces)
        newTab()
        return space
    }

    /// The first colour in the palette that no space has, or the default when
    /// every one is taken. `neutral` is an opt-out rather than a colour, so it
    /// is never handed out.
    func nextUnusedTheme() -> SpaceTheme {
        let taken = Set(spaces.map(\.theme))
        return SpaceTheme.palette.first { $0 != .neutral && !taken.contains($0) } ?? .default
    }

    /// Recolours a space. Every window showing it repaints, which is the whole
    /// point of the setting, so this reports through `.spaces` exactly as a
    /// rename does.
    func setTheme(_ theme: SpaceTheme, for space: Space) {
        // Picking a solid swatch clears a gradient: they are the same setting,
        // and the swatch is the later word.
        let clearsGradient = space.look.gradient != nil
        guard theme != space.theme || clearsGradient else { return }
        space.theme = theme
        if clearsGradient {
            var look = space.look
            look.gradient = nil
            space.look = look
        }
        changes.send(.spaces)
        scheduleSave()
    }

    /// Changes the rim a space draws around the window. Reported the same
    /// way as a recolour, for the same reason.
    func setBorder(_ border: WindowBorder, for space: Space) {
        guard border != space.border else { return }
        space.border = border
        changes.send(.spaces)
        scheduleSave()
    }

    /// Changes how a space looks and behaves. A change of fonts reaches the
    /// space's open pages at once, and every page made for it from now on.
    func setLook(_ look: SpaceLook, for space: Space) {
        guard look != space.look else { return }
        let fontsChanged = look.fonts != space.look.fonts
        space.look = look
        if fontsChanged {
            WebEnvironment.shared.setFonts(look.fonts, for: space.identity)
            for tab in space.tabs { tab.applyFonts(look.fonts) }
        }
        changes.send(.spaces)
        scheduleSave()
    }

    /// Washes a space with a gradient, or clears it back to the solid theme.
    /// The gradient supersedes the theme colour wherever the chrome is washed.
    func setSpaceGradient(_ gradient: SpaceGradient?, for space: Space) {
        guard space.look.gradient != gradient else { return }
        var look = space.look
        look.gradient = gradient
        space.look = look
        changes.send(.spaces)
        scheduleSave()
    }

    /// A custom colour is a theme of its own; picking one selects it. A solid
    /// colour also clears any gradient, since the two are the same setting seen
    /// two ways and the last one picked is the one meant.
    func setCustomColor(_ color: NSColor, for space: Space) {
        var look = space.look
        look.customColor = color
        look.gradient = nil
        space.look = look
        space.theme = .custom
        changes.send(.spaces)
        scheduleSave()
    }

    func rename(_ space: Space, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != space.name else { return }
        space.name = trimmed
        changes.send(.spaces)
        scheduleSave()
    }

    /// Closing a space tears down its tabs and erases its website data: the
    /// space was the identity, and an identity with no space is nothing the
    /// user can see or sign out of. The last space cannot be removed.
    func removeSpace(_ space: Space) {
        guard spaces.count > 1, let index = spaces.firstIndex(where: { $0.id == space.id }) else { return }
        for tab in space.tabs { forget(tab) }
        spaces.remove(at: index)
        routing.removeRoutes(toSpacesNotIn: Set(spaces.map(\.id)))
        if activeSpaceID == space.id {
            activeSpaceID = spaces[min(index, spaces.count - 1)].id
        }

        // WebKit refuses to delete a store that is still in use. Forgetting
        // the tabs above already tore down their web views; dropping the
        // cached store releases the last reference we hold.
        WebEnvironment.shared.releaseDataStore(for: space.identity)
        let identity = space.identity
        Task { await WebEnvironment.removeStoredData(for: identity) }

        changes.send(.spaces)
        changes.send(.tabs)
        changes.send(.activeTab)
        scheduleSave()
    }

    func selectSpace(_ space: Space) {
        guard space.id != activeSpaceID, spaces.contains(where: { $0.id == space.id }) else { return }
        activeSpaceID = space.id
        changes.send(.spaces)
        changes.send(.tabs)
        changes.send(.activeTab)
        scheduleSave()
    }

    func selectSpace(offsetBy offset: Int) {
        guard spaces.count > 1,
              let index = spaces.firstIndex(where: { $0.id == activeSpaceID }) else { return }
        let wrapped = (index + offset % spaces.count + spaces.count) % spaces.count
        selectSpace(spaces[wrapped])
    }

    // MARK: - Tabs

    /// Creates a tab in the active space. The web view is not built until the
    /// tab is shown, so an unselected new tab costs a few hundred bytes.
    @discardableResult
    func newTab(url: URL? = nil, select: Bool = true, origin: SpaceRouter.Origin = .inBrowser) -> Tab {
        let target = url ?? settings.newTabURL(isPrivate: activeSpace.isPrivate)
        let space = routedSpace(for: target, origin: origin) ?? activeSpace
        let tab = Tab(url: target, identity: space.identity)
        insert(tab, into: space, at: space.tabs.count, select: select)

        guard space.id != activeSpaceID else { return tab }
        // A routed tab the user asked to see takes them to it; one opened in
        // the background says where it went instead.
        if select {
            selectSpace(space)
        } else {
            announceRouted(tab, to: space)
        }
        return tab
    }

    private func routedSpace(for url: URL, origin: SpaceRouter.Origin) -> Space? {
        guard case .route(let id) = routing.decision(
            for: url,
            context: .newTab(origin),
            currentSpaceID: activeSpaceID,
            knownSpaceIDs: Set(spaces.map(\.id))
        ) else { return nil }
        return spaces.first { $0.id == id }
    }

    private func announceRouted(_ tab: Tab, to space: Space) {
        guard ToastPreferences.shared.showsRoutedTabToast else { return }
        showToast?(Toast.routed(to: space.name) { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.selectSpace(space)
            self.selectTab(tab)
        })
    }

    /// Commits a rename from the sidebar's inline editor. An empty value clears
    /// the name and the tab falls back to its page title.
    func rename(_ tab: Tab, to name: String) {
        let outcome = TabNameStore.shared.rename(tab.id, to: name)
        guard outcome != .unchanged else { return }
        // The tab's own change signal drives both the sidebar row and the save.
        tab.didChange.send()
        if let toast = Toast.rename(outcome, restoredTitle: tab.displayTitle) {
            showToast?(toast)
        }
    }

    /// Adopts a web view WebKit created for `window.open`, placing it next to
    /// the tab that opened it.
    func adoptChildTab(of parent: Tab, configuration: WKWebViewConfiguration) -> Tab {
        let space = spaces.first { $0.index(of: parent) != nil } ?? activeSpace
        let webView = WebEnvironment.shared.makeWebView(configuration: configuration)
        let tab = Tab(adopting: webView, identity: space.identity)
        let index = space.index(of: parent).map { $0 + 1 } ?? space.tabs.count
        insert(tab, into: space, at: index, select: space.id == activeSpaceID)
        return tab
    }

    /// Adopts a web view a glance has already loaded, as a tab of its own.
    ///
    /// The page is live: nothing reloads, nothing is restored from
    /// `interactionState`, and the scroll position the user reached inside the
    /// glance is where the tab opens.
    @discardableResult
    func adoptGlancedTab(_ webView: WKWebView, after parent: Tab?) -> Tab {
        let space = parent.flatMap { tab in spaces.first { $0.index(of: tab) != nil } } ?? activeSpace
        let tab = Tab(adopting: webView, identity: space.identity)
        let index = parent.flatMap { space.index(of: $0) }.map { $0 + 1 } ?? space.tabs.count
        insert(tab, into: space, at: index, select: space.id == activeSpaceID)
        return tab
    }

    /// Whether an address is one of the active space's pinned sites. Glance's
    /// off-site rule asks this; it ships switched off.
    func isPinnedSite(_ url: URL) -> Bool {
        activeSpace.pinnedSites.contains { $0.matches(url) }
    }

    func closeTab(_ tab: Tab) {
        guard let space = spaces.first(where: { $0.index(of: tab) != nil }) else { return }
        remember(closing: tab, in: space)
        // A live folder must not offer the item again on its next poll.
        if let groupID = tab.groupID {
            liveFolders.tabWasRemoved(tab.id, fromFolder: groupID)
        }
        detach(tab, from: space)
    }

    /// Every tab in the space but this one.
    func closeOtherTabs(than tab: Tab) {
        for other in activeSpace.tabs where other !== tab { closeTab(other) }
    }

    /// Every tab after this one in the space's order.
    func closeTabs(below tab: Tab) {
        let space = activeSpace
        guard let index = space.index(of: tab) else { return }
        for other in space.tabs[(index + 1)...] { closeTab(other) }
    }

    /// Takes a tab out of its space and out of the window, tearing its page
    /// down. The half of closing that a move to another space shares.
    private func detach(_ tab: Tab, from space: Space) {
        guard let index = space.index(of: tab) else { return }

        // Closing a pane is first a removal from the split, so the 2 -> 1
        // dissolve and the sibling rescale happen exactly once.
        removeFromSplit(tab)

        let wasActive = space.activeTabID == tab.id
        forget(tab)
        space.remove(tab)

        if wasActive {
            let neighbour = space.tabs.indices.contains(index) ? space.tabs[index]
                : space.tabs.indices.contains(index - 1) ? space.tabs[index - 1]
                : nil
            space.setActiveTabID(neighbour?.id)
        }

        if space.id == activeSpaceID {
            changes.send(.tabs)
            if wasActive { changes.send(.activeTab) }
        }
        scheduleSave()
    }

    /// A second tab on the same page, right after the first, in the same
    /// folder, and selected. Made directly rather than through `newTab`, which
    /// may route an address to another space; a duplicate belongs beside its
    /// original by definition.
    @discardableResult
    func duplicate(_ tab: Tab) -> Tab? {
        let space = activeSpace
        guard let index = space.index(of: tab) else { return nil }
        let copy = Tab(url: tab.url, identity: space.identity)
        copy.setGroupID(tab.groupID)
        insert(copy, into: space, at: index + 1, select: true)
        return copy
    }

    /// Moves a tab to another space, which is another identity: the page is
    /// rebuilt there from its saved state, so history and scroll position
    /// travel and cookies do not. It lands loose and unselected; the user
    /// stays where they were.
    func move(_ tab: Tab, toSpace target: Space) {
        guard let source = spaces.first(where: { $0.index(of: tab) != nil }),
              source.id != target.id,
              spaces.contains(where: { $0.id == target.id })
        else { return }
        var snapshot = tab.snapshot()
        snapshot.groupID = nil
        snapshot.pinnedSiteID = nil
        detach(tab, from: source)
        let moved = Tab(restoring: snapshot, identity: target.identity)
        insert(moved, into: target, at: target.tabs.count, select: false)
    }

    /// Moves a whole group -- its nested subgroups and every tab filed under any
    /// of them -- to another space, keeping the structure intact. The group's
    /// own "Move to Space" menu, the counterpart of a tab's.
    func move(_ group: TabGroup, toSpace target: Space) {
        guard let source = spaces.first(where: { $0.group(withID: group.id) != nil }),
              source.id != target.id,
              spaces.contains(where: { $0.id == target.id })
        else { return }

        // The group and everything nested under it travel together.
        let moving = [group] + FolderTree.descendants(of: group, in: source.groups)
        let movingIDs = Set(moving.map(\.id))
        // Captured before any detach empties the source's tab list.
        let movingTabs = source.tabs.filter { $0.groupID.map(movingIDs.contains) ?? false }

        // If the moved root's parent stays behind, it becomes a root in the
        // target rather than pointing at a folder that is not there.
        if let parent = group.parentID, !movingIDs.contains(parent) {
            group.parentID = nil
        }

        // Carry the groups over first -- with the non-orphaning removal, so the
        // tabs still filed under them survive the trip -- then the tabs, each
        // rebuilt for the target's identity but keeping the group it belongs to.
        for moved in moving {
            source.detachGroup(moved)
            target.addGroup(moved)
        }
        for tab in movingTabs {
            var snapshot = tab.snapshot()
            snapshot.pinnedSiteID = nil
            detach(tab, from: source)
            let moved = Tab(restoring: snapshot, identity: target.identity)
            insert(moved, into: target, at: target.tabs.count, select: false)
        }

        changes.send(.structure)
        scheduleSave()
    }

    // MARK: - Closed tabs

    /// A closed tab, kept so it can come back: what it held and where it was.
    struct ClosedTab {
        let snapshot: SessionSnapshot.Tab
        let spaceID: Space.ID
    }

    /// Most recent last. In memory only: the list is gone at quit, which is
    /// what makes it safe to keep at all.
    private(set) var closedTabs: [ClosedTab] = []
    private static let closedTabLimit = 25

    var canReopenClosedTab: Bool { !closedTabs.isEmpty }

    /// Photographs a tab before it goes. A private space keeps nothing, not
    /// even this: reopening would bring back a page whose logins are gone,
    /// and remembering it contradicts what "private" promised.
    private func remember(closing tab: Tab, in space: Space) {
        guard !space.isPrivate else { return }
        closedTabs.append(ClosedTab(snapshot: tab.snapshot(), spaceID: space.id))
        if closedTabs.count > Self.closedTabLimit {
            closedTabs.removeFirst(closedTabs.count - Self.closedTabLimit)
        }
    }

    /// Brings the most recently closed tab back into the space it was closed
    /// from, or the active space if that one has gone, and selects it.
    @discardableResult
    func reopenClosedTab() -> Tab? {
        guard let closed = closedTabs.popLast() else { return nil }
        let space = spaces.first { $0.id == closed.spaceID } ?? activeSpace
        var snapshot = closed.snapshot
        // Its folder may have been deleted in the meantime; a tab pointing at
        // a group that no longer exists would be invisible in the sidebar.
        if let groupID = snapshot.groupID, space.group(withID: groupID) == nil {
            snapshot.groupID = nil
        }
        snapshot.pinnedSiteID = nil
        let tab = Tab(restoring: snapshot, identity: space.identity)
        if space.id != activeSpaceID { selectSpace(space) }
        insert(tab, into: space, at: space.tabs.count, select: true)
        return tab
    }

    // MARK: - Archived tabs

    /// A tab that left the sidebar on its own, and the space it left from.
    ///
    /// Saved, unlike `closedTabs`. Closing is something the user did and can
    /// remember doing; archiving happens while they are not looking, so a list
    /// that emptied at quit would mean tabs disappearing with nothing to point
    /// at afterwards. The identifier is the record's own: the `Tab` is gone,
    /// and what is left is a photograph of it.
    struct ArchivedTab: Identifiable {
        let id: UUID
        var snapshot: SessionSnapshot.Tab
        var spaceID: Space.ID
        var archivedAt: Date

        init(id: UUID = UUID(), snapshot: SessionSnapshot.Tab, spaceID: Space.ID, archivedAt: Date) {
            self.id = id
            self.snapshot = snapshot
            self.spaceID = spaceID
            self.archivedAt = archivedAt
        }

        /// What to call it in the archive list, preferring the name the user
        /// gave it over the one the page did.
        var title: String {
            if let custom = snapshot.customName, !custom.isEmpty { return custom }
            if let page = snapshot.title, !page.isEmpty { return page }
            return snapshot.url.host() ?? snapshot.url.absoluteString
        }
    }

    /// Oldest first. Bounded, because an archive that grows without limit is a
    /// session file that grows without limit; the cap is generous enough that
    /// reaching it means the setting is doing its job.
    private(set) var archivedTabs: [ArchivedTab] = []
    private static let archiveLimit = 500

    /// One space's archive, most recently archived first -- the order someone
    /// looking for "the thing that just vanished" reads in.
    func archivedTabs(in space: Space) -> [ArchivedTab] {
        archivedTabs
            .filter { $0.spaceID == space.id }
            .sorted { $0.archivedAt > $1.archivedAt }
    }

    /// Takes tabs out of the sidebar and into the archive, whole: the saved
    /// interaction state goes with them, so restoring one brings back its
    /// scroll position and its back-forward list rather than just an address.
    func archive(_ tabs: [Tab]) {
        var archived = 0
        for tab in tabs {
            guard let space = spaces.first(where: { $0.index(of: tab) != nil }) else { continue }
            // A private space keeps nothing that outlives it -- not even this.
            // Archiving there would write to disk exactly what "private"
            // promised would never be written, so a private tab is left alone.
            guard !space.isPrivate else { continue }
            archivedTabs.append(
                ArchivedTab(snapshot: tab.snapshot(), spaceID: space.id, archivedAt: .now)
            )
            if let groupID = tab.groupID {
                liveFolders.tabWasRemoved(tab.id, fromFolder: groupID)
            }
            detach(tab, from: space)
            archived += 1
        }
        guard archived > 0 else { return }
        if archivedTabs.count > Self.archiveLimit {
            archivedTabs.removeFirst(archivedTabs.count - Self.archiveLimit)
        }
        Metrics.log("archive count=\(tabs.count) total=\(archivedTabs.count)")
        changes.send(.structure)
        scheduleSave()
        showToast?(.archived(count: archived, undo: { [weak self] in self?.undoArchive(archived) }))
    }

    /// Puts back everything the last sweep took, for the toast's Undo.
    ///
    /// Archiving is the only thing in the browser that removes a row without
    /// the user touching anything, so it is the one thing that has to offer the
    /// undo up front rather than leave it to be found later in a window.
    private func undoArchive(_ count: Int) {
        // Copied out first: `restoreArchived` removes from the same array.
        let restorable = Array(archivedTabs.suffix(count))
        for record in restorable { restoreArchived(record) }
    }

    /// Brings one back, into the space it left from or the active space if that
    /// space has gone. It returns awake and selected: restoring a tab is an act
    /// of wanting to read it.
    @discardableResult
    func restoreArchived(_ archived: ArchivedTab) -> Tab? {
        guard let index = archivedTabs.firstIndex(where: { $0.id == archived.id }) else { return nil }
        let record = archivedTabs.remove(at: index)
        let space = spaces.first { $0.id == record.spaceID } ?? activeSpace
        var snapshot = record.snapshot
        // Its folder may have been deleted while it sat in the archive; a tab
        // pointing at a group that no longer exists would be invisible.
        if let groupID = snapshot.groupID, space.group(withID: groupID) == nil {
            snapshot.groupID = nil
        }
        snapshot.pinnedSiteID = nil
        // A fresh clock. Restoring a tab and having the sweep archive it again
        // on the next pass -- because its saved `lastActiveAt` is still days old
        // -- would be the single most infuriating bug this feature could have.
        snapshot.lastActiveAt = .now
        let tab = Tab(restoring: snapshot, identity: space.identity)
        if space.id != activeSpaceID { selectSpace(space) }
        insert(tab, into: space, at: space.tabs.count, select: true)
        scheduleSave()
        return tab
    }

    /// Drops one from the archive without bringing it back.
    func forgetArchived(_ archived: ArchivedTab) {
        guard let index = archivedTabs.firstIndex(where: { $0.id == archived.id }) else { return }
        archivedTabs.remove(at: index)
        changes.send(.structure)
        scheduleSave()
    }

    /// Empties the archive, every space's. One change rather than one per row:
    /// the sidebar's Clear has no space filter to narrow it and no reason to
    /// rebuild its list once per archived tab.
    func clearArchive() {
        guard !archivedTabs.isEmpty else { return }
        archivedTabs.removeAll()
        changes.send(.structure)
        scheduleSave()
    }

    func selectTab(_ tab: Tab) {
        let space = activeSpace
        guard space.index(of: tab) != nil, space.activeTabID != tab.id else { return }
        space.setActiveTabID(tab.id)
        changes.send(.activeTab)
        scheduleSave()
    }

    /// 1-based, to match the Cmd-1 ... Cmd-9 menu items. Cmd-9 is the last tab.
    /// Tab `number` as the sidebar counts them, so Cmd-3 is the third row
    /// the user can see; a pinned site's tab is not listed and not counted.
    /// Past the end, nine and above mean the last tab.
    func selectTab(number: Int) {
        let tabs = activeSpace.listedTabs
        guard !tabs.isEmpty else { return }
        let index = tabs.indices.contains(number - 1) ? number - 1
            : number >= 9 ? tabs.count - 1
            : -1
        guard tabs.indices.contains(index) else { return }
        selectTab(tabs[index])
    }

    func selectTab(offsetBy offset: Int) {
        let tabs = activeSpace.tabs
        guard tabs.count > 1,
              let current = activeSpace.activeTabID,
              let index = tabs.firstIndex(where: { $0.id == current }) else { return }
        let wrapped = (index + offset % tabs.count + tabs.count) % tabs.count
        selectTab(tabs[wrapped])
    }

    func moveTab(from source: Int, to destination: Int) {
        activeSpace.move(from: source, to: destination)
        changes.send(.tabs)
        scheduleSave()
    }

    /// Reorders a top-level group, so dragging a group's header in the sidebar
    /// moves it. `before` is the group it should sit ahead of, or nil to send
    /// it past the last one.
    func moveGroup(_ group: TabGroup, before other: TabGroup?) {
        activeSpace.moveGroup(group, before: other)
        changes.send(.structure)
        scheduleSave()
    }

    // MARK: - Tab groups

    /// A folder whose contents a provider maintains: a feed, an account's
    /// pull requests. Named and iconed by the provider, so the user is not
    /// asked to name something they have not seen yet.
    @discardableResult
    func createLiveGroup(source: LiveFolderSource) -> TabGroup {
        let space = activeSpace
        let metadata = LiveFolderManager.metadata(for: source)
        let group = TabGroup(
            name: metadata.name,
            tint: space.color,
            symbolName: metadata.symbolName,
            isLive: true
        )
        space.addGroup(group)
        liveFolders.add(folderID: group.id, source: source)
        changes.send(.structure)
        scheduleSave()
        return group
    }

    @discardableResult
    func createGroup(named name: String, emoji: String? = nil, containing tabs: [Tab] = []) -> TabGroup {
        let space = activeSpace
        let group = TabGroup(name: name, emoji: emoji, tint: space.color)
        space.addGroup(group)
        for tab in tabs where space.index(of: tab) != nil {
            tab.setGroupID(group.id)
        }
        changes.send(.structure)
        scheduleSave()
        return group
    }

    func rename(_ group: TabGroup, to name: String, emoji: String? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        group.name = trimmed
        if let emoji { group.emoji = emoji.isEmpty ? nil : emoji }
        changes.send(.structure)
        scheduleSave()
    }

    func toggleCollapsed(_ group: TabGroup) {
        group.isCollapsed.toggle()
        changes.send(.structure)
        scheduleSave()
    }

    /// Repaints the plate behind a group: its fill, gradient and raised rim.
    func setAppearance(_ appearance: TabGroupAppearance, for group: TabGroup) {
        guard group.appearance != appearance else { return }
        group.appearance = appearance
        changes.send(.structure)
        scheduleSave()
    }

    /// Deleting a group frees its tabs rather than closing them.
    /// Removes a group. Its tabs move to the main list by default (they are
    /// only ungrouped); with `closingTabs` they are closed along with the group.
    func removeGroup(_ group: TabGroup, closingTabs: Bool = false) {
        if closingTabs {
            for tab in activeSpace.tabs.filter({ $0.groupID == group.id }) {
                closeTab(tab)
            }
        }
        activeSpace.removeGroup(group)
        changes.send(.structure)
        scheduleSave()
    }

    func move(_ tab: Tab, to group: TabGroup?) {
        let space = activeSpace
        guard space.index(of: tab) != nil else { return }
        guard group == nil || space.group(withID: group!.id) != nil else { return }
        tab.setGroupID(group?.id)
        changes.send(.structure)
        scheduleSave()
    }

    // MARK: - Pinned sites

    func pinActiveTab() {
        guard let tab = activeTab else { return }
        pin(tab)
    }

    /// Whether this tab, or its page, is already a tile.
    /// Whether a provider maintains this tab's folder. Such a tab is never
    /// archived: the folder would offer it again on its next poll.
    func isInLiveFolder(_ tab: Tab) -> Bool {
        guard let groupID = tab.groupID else { return false }
        return spaces.contains { $0.group(withID: groupID)?.isLive == true }
    }

    func isPinned(_ tab: Tab) -> Bool {
        tab.pinnedSiteID != nil || activeSpace.pinnedSites.contains { $0.matches(tab.url) }
    }

    /// Turns a tab into a tile. The tab becomes the tile's own, so it leaves
    /// the list rather than showing the same site twice.
    func pin(_ tab: Tab) {
        let space = activeSpace
        guard space.index(of: tab) != nil, !isPinned(tab) else { return }
        let site = PinnedSite(url: tab.url, title: tab.displayTitle)
        space.addPinnedSite(site)
        tab.setPinnedSiteID(site.id)
        changes.send(.structure)
        scheduleSave()
    }

    func removePinnedSite(_ site: PinnedSite) {
        // The tab outlives the shortcut and rejoins the list, rather than
        // disappearing with a tile the user only meant to unpin.
        activeSpace.tab(forPin: site.id)?.setPinnedSiteID(nil)
        activeSpace.removePinnedSite(site)
        changes.send(.structure)
        scheduleSave()
    }

    func movePinnedSite(from source: Int, to destination: Int) {
        activeSpace.movePinnedSite(from: source, to: destination)
        changes.send(.structure)
        scheduleSave()
    }

    /// Opening a pin reuses a tab already on that site rather than piling up
    /// near-duplicates, which is the whole reason a pin is not a tab.
    func openPinnedSite(_ site: PinnedSite) {
        let space = activeSpace
        if let existing = space.tab(forPin: site.id) {
            selectTab(existing)
            return
        }
        // An existing tab already on that site is adopted rather than
        // duplicated -- restoring a session, or pinning the page you are on.
        if let onSite = space.tabs.first(where: { $0.pinnedSiteID == nil && site.matches($0.url) }) {
            onSite.setPinnedSiteID(site.id)
            selectTab(onSite)
            changes.send(.structure)
            scheduleSave()
            return
        }
        let tab = newTab(url: site.url)
        tab.setPinnedSiteID(site.id)
        changes.send(.structure)
        scheduleSave()
    }

    // MARK: - Suspension

    var allTabs: [Tab] { spaces.flatMap(\.tabs) }

    /// The tabs actually rendered. With a split on screen that is every one of
    /// its panes, not just the focused one: they are equally visible and
    /// suspending them would blank a page the user is looking at.
    var visibleTabIDs: Set<Tab.ID> {
        if let split = activeSplit { return Set(split.tabIDs) }
        return Set([activeTab?.id].compactMap { $0 })
    }

    /// Lets only the tabs on screen play media and pauses every other one, so a
    /// video or song stops when its tab is switched away from and never plays
    /// on in the background. Called on every change to what is visible -- a tab,
    /// space or split switch -- from the content pane, which is the one place
    /// that knows the switch has actually landed.
    func updateMediaSuspension() {
        let visible = visibleTabIDs
        for tab in allTabs {
            tab.setMediaSuspended(!visible.contains(tab.id))
        }
    }

    /// Tabs that must be loaded and unloaded together: the members of each
    /// split, in every space.
    var splitCohorts: [Set<Tab.ID>] {
        splitsBySpace.values.map { Set($0.tabIDs) }
    }

    // MARK: - Split view

    /// The split on screen, which is the one containing the selected tab. A
    /// split whose tabs are all in the background is kept but not shown.
    var activeSplit: SplitLayout? {
        guard let layout = splitsBySpace[activeSpaceID],
              let active = activeTab, layout.contains(active.id) else { return nil }
        return layout
    }

    func split(_ space: Space) -> SplitLayout? { splitsBySpace[space.id] }

    /// Puts these tabs on screen together, extending the active space's split if
    /// one of them is already in it.
    @discardableResult
    func splitTabs(_ tabs: [Tab], grid: SplitLayout.Grid = .grid) -> Bool {
        let ids = tabs.map(\.id)
        guard let first = tabs.first else { return false }

        if var layout = splitsBySpace[activeSpaceID], ids.contains(where: layout.contains) {
            for id in ids where !layout.contains(id) {
                guard let extended = layout.adding(id) else { return false }
                layout = extended
            }
            splitsBySpace[activeSpaceID] = layout
        } else {
            guard let layout = SplitLayout(tabs: ids, grid: grid) else { return false }
            splitsBySpace[activeSpaceID] = layout
        }

        // Focus has to land inside the split, or it would not be shown.
        if activeSplit == nil { selectTab(first) }
        changes.send(.structure)
        changes.send(.activeTab)
        scheduleSave()
        return true
    }

    /// Rebuilds the active split in a different arrangement.
    func relaySplit(as grid: SplitLayout.Grid) {
        guard let layout = splitsBySpace[activeSpaceID] else { return }
        splitsBySpace[activeSpaceID] = layout.relaid(as: grid)
        changes.send(.activeTab)
        scheduleSave()
    }

    /// Records new proportions after a divider drag.
    func updateSplitLayout(_ layout: SplitLayout) {
        guard splitsBySpace[activeSpaceID]?.tabIDs == layout.tabIDs else { return }
        splitsBySpace[activeSpaceID] = layout
        scheduleSave()
    }

    /// Takes a tab out of whatever split it is in, dissolving the split when
    /// that would leave one pane. The tab itself is untouched.
    func removeFromSplit(_ tab: Tab) {
        guard let spaceID = splitsBySpace.first(where: { $0.value.contains(tab.id) })?.key,
              let removal = splitsBySpace[spaceID]?.removing(tab.id) else { return }

        switch removal {
        case .dissolved(let remaining):
            splitsBySpace[spaceID] = nil
            if spaceID == activeSpaceID, activeTab?.id == tab.id,
               let survivor = activeSpace.tabs.first(where: { $0.id == remaining.first }) {
                selectTab(survivor)
            }
        case .resized(let layout):
            splitsBySpace[spaceID] = layout
            if spaceID == activeSpaceID, activeTab?.id == tab.id,
               let next = activeSpace.tabs.first(where: { $0.id == layout.tabIDs.first }) {
                selectTab(next)
            }
        }
        changes.send(.structure)
        changes.send(.activeTab)
        scheduleSave()
    }

    /// Dissolves the active split without closing anything.
    func unsplit() {
        guard splitsBySpace[activeSpaceID] != nil else { return }
        splitsBySpace[activeSpaceID] = nil
        changes.send(.structure)
        changes.send(.activeTab)
        scheduleSave()
    }

    /// Releases the web views of tabs that are not on screen. The tabs stay in
    /// the sidebar and come back exactly where they were when next shown.
    func suspend(_ tabs: [Tab]) {
        let protected = visibleTabIDs
        var suspended = 0
        for tab in tabs where !protected.contains(tab.id) {
            tab.unload()
            suspended += 1
        }
        Metrics.log("suspend asked=\(tabs.count) suspended=\(suspended) stillLoaded=\(allTabs.count { $0.isLoaded })")
    }

    // MARK: - History

    func historySuggestions(matching prefix: String, limit: Int = 8) async -> [HistoryEntry] {
        guard let database else { return [] }
        return (try? await database.suggestions(matching: prefix, limit: limit)) ?? []
    }

    func recentHistory(limit: Int = 100) async -> [HistoryEntry] {
        guard let database else { return [] }
        return (try? await database.recentHistory(limit: limit)) ?? []
    }

    func clearHistory() {
        guard let database else { return }
        Task { try? await database.clearHistory() }
    }

    // MARK: - Bookmarks

    var activeTabIsBookmarked: Bool {
        guard let url = activeTab?.url else { return false }
        return bookmarks.contains { $0.url == url }
    }

    func toggleBookmarkForActiveTab() {
        guard let database, let tab = activeTab else { return }
        let url = tab.url
        let title = tab.displayTitle
        let isBookmarked = activeTabIsBookmarked
        Task {
            if isBookmarked {
                try? await database.removeBookmark(url: url)
            } else {
                try? await database.addBookmark(url: url, title: title)
            }
            loadBookmarks()
        }
    }

    /// Pushes the Browsing pane's web preferences to every page already open.
    func applyWebPreferences() {
        for tab in allTabs {
            guard let preferences = tab.currentWebView?.configuration.preferences else { continue }
            preferences.minimumFontSize = settings.effectiveMinimumFontSize
            preferences.tabFocusesLinks = settings.tabFocusesLinks
        }
    }

    /// Removes history older than the retention setting, if there is one.
    func pruneHistory() {
        guard let database, let cutoff = settings.historyRetention.cutoff() else { return }
        Task { try? await database.deleteHistory(before: cutoff) }
    }

    /// Every space's identity that keeps data on disk.
    var storedIdentities: [Space.Identity] { spaces.map(\.identity) + [.standard] }

    /// Cookies gone from every space, on the schedule the user set.
    func deleteCookiesIfDue() {
        guard settings.cookieDeletion.isDue(lastDeletion: settings.lastCookieDeletion) else { return }
        let identities = storedIdentities
        Task {
            await WebsiteData.removeAll(types: WebsiteData.cookieTypes, for: identities)
            settings.lastCookieDeletion = .now
        }
    }

    /// Everything browsed: history, every space's website data, the closed
    /// tab list. Spaces, bookmarks and settings stay; they are the user's
    /// work, not the web's residue.
    func resetBrowsingData() async {
        closedTabs.removeAll()
        if let database { try? await database.clearHistory() }
        await WebsiteData.removeAll(for: storedIdentities)
        settings.lastCookieDeletion = .now
        for tab in allTabs where tab.isLoaded { tab.reload() }
    }

    /// Adds bookmarks read from another browser's file, keeping the folders
    /// they came in. Duplicates by address update the title and folder rather
    /// than doubling up.
    func importBookmarks(_ entries: [BookmarkImporter.Entry]) async -> Int {
        guard let database, !entries.isEmpty else { return 0 }
        // `bookmarks()` orders by `created_at` descending, so the first entry
        // is stamped latest and stays first; a millisecond step keeps a whole
        // export in source order without spreading it across real time.
        let base = Date()
        let items = entries.enumerated().map { index, entry in
            (url: entry.url,
             title: entry.title,
             folder: entry.folderPath.joined(separator: "/"),
             date: base.addingTimeInterval(-Double(index) * 0.001))
        }
        let added = (try? await database.importBookmarks(items)) ?? 0
        loadBookmarks()
        return added
    }

    /// Adds history read from another browser's file. The key each page is
    /// matched on is generated the same way a live visit's is, so imported
    /// pages surface in the omnibox exactly as browsed ones do. Returns how
    /// many pages were added.
    func importHistory(_ visits: [HistoryImporter.Visit]) async -> Int {
        guard let database, !visits.isEmpty else { return 0 }
        let items = visits.map { visit in
            (url: visit.url,
             title: visit.title,
             key: AddressFormatter.display(visit.url),
             date: visit.lastVisited)
        }
        return (try? await database.importVisits(items)) ?? 0
    }

    /// Opens the tabs another browser had, gathered into one new group in the
    /// active space. They are inserted straight into that space rather than
    /// through `newTab`, so routing rules do not scatter an import across
    /// spaces, and none is selected -- an import should not yank the user to a
    /// page. Restored (not fresh) tabs carry their title before they load, the
    /// way a relaunch does. Returns how many tabs were opened.
    @discardableResult
    func importTabs(_ imported: [TabSessionImporter.Tab], groupName: String) -> Int {
        guard !imported.isEmpty else { return 0 }
        let space = activeSpace
        var opened: [Tab] = []
        for item in imported {
            let snapshot = SessionSnapshot.Tab(
                url: item.url,
                title: item.title.isEmpty ? nil : item.title,
                groupID: nil,
                customName: nil,
                pinnedSiteID: nil,
                interactionState: nil
            )
            let tab = Tab(restoring: snapshot, identity: space.identity)
            insert(tab, into: space, at: space.tabs.count, select: false)
            opened.append(tab)
        }
        createGroup(named: groupName, containing: opened)
        return opened.count
    }

    /// Injects cookies read from another browser into the active space's own
    /// store, so the sites the user was signed into there are signed in here.
    /// The space's loaded pages reload so they pick the session up. Returns how
    /// many cookies were set. Cookies are per space, so an import lands in the
    /// space in front, not across all of them.
    func importCookies(_ cookies: [CookieImporter.Cookie]) async -> Int {
        let store = WebEnvironment.shared.dataStore(for: activeSpace.identity).httpCookieStore
        var count = 0
        for cookie in cookies {
            guard let httpCookie = Self.httpCookie(from: cookie) else { continue }
            await withCheckedContinuation { continuation in
                store.setCookie(httpCookie) { continuation.resume() }
            }
            count += 1
        }
        for tab in activeSpace.tabs where tab.isLoaded { tab.reload() }
        return count
    }

    private static func httpCookie(from cookie: CookieImporter.Cookie) -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: cookie.name,
            .value: cookie.value,
            .domain: cookie.domain,
            .path: cookie.path
        ]
        if let expires = cookie.expires { properties[.expires] = expires }
        if cookie.isSecure { properties[.secure] = "TRUE" }
        return HTTPCookie(properties: properties)
    }

    /// The space links from other apps land in when the General pane says
    /// "Default space": the chosen one, else the first.
    var defaultSpace: Space {
        spaces.first { $0.id == settings.defaultSpaceID } ?? spaces[0]
    }

    /// Bookmarks every tab in the active space that is not bookmarked already.
    func bookmarkAllTabs() {
        guard let database else { return }
        let known = Set(bookmarks.map(\.url))
        let pages = activeSpace.tabs
            .filter { !known.contains($0.url) }
            .map { ($0.url, $0.displayTitle) }
        guard !pages.isEmpty else { return }
        Task {
            for (url, title) in pages {
                try? await database.addBookmark(url: url, title: title)
            }
            loadBookmarks()
        }
    }

    func removeBookmark(_ bookmark: Bookmark) {
        guard let database else { return }
        Task {
            try? await database.removeBookmark(url: bookmark.url)
            loadBookmarks()
        }
    }

    private func loadBookmarks() {
        guard let database else { return }
        Task {
            let loaded = (try? await database.bookmarks()) ?? []
            guard loaded != bookmarks else { return }
            bookmarks = loaded
            changes.send(.bookmarks)
        }
    }

    // MARK: - Persistence

    /// Writes the session after a short delay, collapsing bursts of changes.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Writes immediately. Called on quit, where a delayed write would be lost.
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        try? sessionStore.save(snapshot())
    }

    func snapshot() -> SessionSnapshot {
        SessionSnapshot(
            spaces: spaces.map { space in
                SessionSnapshot.Space(
                    name: space.name,
                    // A private space keeps its name and its colour, and
                    // nothing it browsed: "not written to disk" includes the
                    // list of what was open.
                    tabs: space.isPrivate ? [] : space.tabs.map { $0.snapshot() },
                    activeTabIndex: space.isPrivate ? nil : space.activeTab.flatMap { space.index(of: $0) },
                    identity: space.identity,
                    theme: space.theme.rawValue,
                    border: space.border,
                    look: space.look,
                    groups: space.groups.map {
                        SessionSnapshot.Group(
                            id: $0.id,
                            name: $0.name,
                            emoji: $0.emoji,
                            tint: $0.tint.hexString,
                            appearance: $0.appearance.isStandard ? nil : $0.appearance,
                            isCollapsed: $0.isCollapsed,
                            parentID: $0.parentID,
                            symbolName: $0.symbolName,
                            isLive: $0.isLive ? true : nil
                        )
                    },
                    pinnedSites: space.pinnedSites.map {
                        SessionSnapshot.Pinned(id: $0.id, url: $0.url, title: $0.title)
                    },
                    archiveHours: space.archiveHours,
                    // Written in the order archived, so the list restores the
                    // way it was built; the reading order is applied on the way
                    // out, in `archivedTabs(in:)`.
                    archivedTabs: space.isPrivate ? nil : archivedTabs
                        .filter { $0.spaceID == space.id }
                        .map { SessionSnapshot.Archived(tab: $0.snapshot, archivedAt: $0.archivedAt) }
                )
            },
            activeSpaceIndex: spaces.firstIndex { $0.id == activeSpaceID } ?? 0
        )
    }

    /// Restores the spaces, migrating a session written while profiles were
    /// separate from spaces.
    ///
    /// Back then several spaces could share one profile, and one data store.
    /// A data store can belong to only one space now, so the first space that
    /// used a profile keeps its store -- and its logins -- and any other space
    /// that shared it starts signed out with a store of its own. A space whose
    /// profile was private or is missing takes the default store if no space
    /// has it yet, which is where that space's pages were loading from before.
    private static func spaces(from snapshot: SessionSnapshot) -> [Space]? {
        let legacyProfiles = snapshot.profiles ?? []
        var claimed: Set<Space.Identity> = []

        func migratedIdentity(for stored: SessionSnapshot.Space) -> Space.Identity {
            let profile = legacyProfiles.first { $0.id == stored.profileID }
            let inherited: Space.Identity = switch profile?.kind {
            case .isolated(let identifier): .isolated(identifier)
            case .standard, .ephemeral, nil: .standard
            }
            return claimed.insert(inherited).inserted ? inherited : .makeIsolated()
        }

        let spaces = snapshot.spaces.map { stored -> Space in
            let identity = stored.identity ?? migratedIdentity(for: stored)
            let legacyTheme = legacyProfiles.first { $0.id == stored.profileID }?.theme
            let space = Space(
                name: stored.name,
                identity: identity,
                theme: SpaceTheme(storedValue: stored.theme ?? legacyTheme),
                border: stored.border ?? .none,
                look: stored.look ?? SpaceLook(),
                archiveHours: stored.archiveHours
            )
            WebEnvironment.shared.setFonts(space.look.fonts, for: space.identity)
            let groups = (stored.groups ?? []).map {
                TabGroup(
                    id: $0.id,
                    name: $0.name,
                    emoji: $0.emoji,
                    tint: NSColor(hexString: $0.tint) ?? .controlAccentColor,
                    appearance: $0.appearance ?? .standard,
                    isCollapsed: $0.isCollapsed,
                    parentID: $0.parentID,
                    symbolName: $0.symbolName,
                    isLive: $0.isLive ?? false
                )
            }
            space.restore(
                groups: groups,
                pinnedSites: (stored.pinnedSites ?? []).map {
                    PinnedSite(id: $0.id, url: $0.url, title: $0.title)
                }
            )

            // A parent that did not survive the restore leaves a root folder
            // rather than an invisible one.
            let knownGroupIDs = Set(groups.map(\.id))
            for group in groups where group.parentID.map({ !knownGroupIDs.contains($0) }) ?? false {
                group.parentID = nil
            }
            for tab in stored.tabs {
                var tab = tab
                // A tab whose group is gone becomes ungrouped rather than
                // invisible in the sidebar.
                if let id = tab.groupID, !knownGroupIDs.contains(id) { tab.groupID = nil }
                space.insert(Tab(restoring: tab, identity: identity), at: space.tabs.count)
            }
            if let index = stored.activeTabIndex, space.tabs.indices.contains(index) {
                space.setActiveTabID(space.tabs[index].id)
            } else {
                space.setActiveTabID(space.tabs.first?.id)
            }
            return space
        }
        return spaces.isEmpty ? nil : spaces
    }

    // MARK: - Bookkeeping

    private func insert(_ tab: Tab, into space: Space, at index: Int, select: Bool) {
        adopt(tab)
        space.insert(tab, at: index)
        if select || space.activeTabID == nil {
            space.setActiveTabID(tab.id)
        }

        if space.id == activeSpaceID {
            changes.send(.tabs)
            if space.activeTabID == tab.id { changes.send(.activeTab) }
        }
        scheduleSave()
    }

    private func adopt(_ tab: Tab) {
        tab.delegate = self
        tabSubscriptions[tab.id] = tab.didChange.sink { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.changes.send(.tab(tab))
            self.scheduleSave()
        }
    }

    /// Releases everything a tab holds: its WebKit content process first, then
    /// our subscription to it.
    private func forget(_ tab: Tab) {
        tab.unload()
        tab.delegate = nil
        tabSubscriptions[tab.id] = nil
        TabNameStore.shared.forget(tab.id)
    }
}

extension BrowserSession: TabDelegate {
    func tab(_ tab: Tab, requestsNewTabWith configuration: WKWebViewConfiguration) -> Tab {
        adoptChildTab(of: tab, configuration: configuration)
    }

    func tab(_ tab: Tab, didVisit url: URL, title: String) {
        guard let database, !settings.historyDisabled, !tab.isPrivate else { return }
        let key = AddressFormatter.display(url)
        Task { try? await database.recordVisit(url: url, title: title, key: key) }
    }

    func tab(_ tab: Tab, didRetitle url: URL, to title: String) {
        guard let database, !settings.historyDisabled, !tab.isPrivate else { return }
        Task { try? await database.updateLatestVisitTitle(url: url, title: title) }
    }
}

// MARK: - Live folders

/// The manager owns no tabs (D-LF, `LiveFolderManager`); this is where its
/// requests become tabs in the folder's own space.
extension BrowserSession: LiveFolderManagerDelegate {
    func liveFolderManager(
        _ manager: LiveFolderManager,
        openTabFor item: LiveFolderItem,
        inFolder folderID: TabGroup.ID
    ) -> Tab.ID? {
        // The folder's space, not the active one: a poll lands whenever it
        // lands, and the user may be looking somewhere else entirely.
        guard let space = spaces.first(where: { $0.group(withID: folderID) != nil }) else { return nil }
        // Restored rather than made from the URL alone, so the row carries the
        // item's title before the page has loaded -- or without it ever
        // loading, since a background tab builds no web view.
        let snapshot = SessionSnapshot.Tab(url: item.url, title: item.title, groupID: folderID)
        let tab = Tab(restoring: snapshot, identity: space.identity)
        insert(tab, into: space, at: space.tabs.count, select: false)
        return tab.id
    }

    func liveFolderManager(
        _ manager: LiveFolderManager,
        closeTabs tabIDs: [Tab.ID],
        inFolder folderID: TabGroup.ID
    ) {
        let gone = Set(tabIDs)
        for tab in allTabs where gone.contains(tab.id) && tab.groupID == folderID {
            closeTab(tab)
        }
    }

    func liveFolderManager(_ manager: LiveFolderManager, didChange folderID: TabGroup.ID) {
        changes.send(.structure)
    }
}
