import Foundation

/// How essentials behave: how many there may be, whether they are shared, and
/// what a second click does.
struct EssentialsConfiguration: Sendable, Equatable {
    /// A cap rather than a scrollbar, because the strip wraps onto a second
    /// and third row long before anyone notices they have stopped
    /// recognising their own tiles.
    var maximumCount = 12

    /// Essentials are visible from every space.
    ///
    /// This is the whole point of an essential: it should show up everywhere,
    /// regardless of which space it was pinned in. Kylmora stores pins per
    /// space, though, so sharing is applied here, on the read side -- a pin
    /// still belongs to the space it was made in, and turning sharing off
    /// returns the strip to exactly what it showed before.
    var isSharedAcrossSpaces = true

    /// A second click resets the tile to its pinned address.
    ///
    /// A double-click is the affordance that needs no chrome of its own. It
    /// is deliberately *not* what a single click does -- see `activate`.
    var resetsOnDoubleClick = true

    init() {}
}

/// Everything the essentials strip needs to know about the browser, as a value.
///
/// A snapshot rather than a reference to the session: the behaviour below is
/// the part worth getting right and it is pure, so it is tested against
/// literals instead of against a live browser with a database behind it.
struct EssentialsSnapshot: Sendable {
    struct SpaceEntry: Sendable {
        let id: UUID
        let pinnedSites: [PinnedSite]

        init(id: UUID, pinnedSites: [PinnedSite]) {
            self.id = id
            self.pinnedSites = pinnedSites
        }
    }

    struct OpenTab: Sendable {
        let id: UUID
        let spaceID: UUID
        let url: URL

        init(id: UUID, spaceID: UUID, url: URL) {
            self.id = id
            self.spaceID = spaceID
            self.url = url
        }
    }

    let spaces: [SpaceEntry]
    let activeSpaceID: UUID
    let openTabs: [OpenTab]
    let activeTabID: UUID?

    init(
        spaces: [SpaceEntry],
        activeSpaceID: UUID,
        openTabs: [OpenTab] = [],
        activeTabID: UUID? = nil
    ) {
        self.spaces = spaces
        self.activeSpaceID = activeSpaceID
        self.openTabs = openTabs
        self.activeTabID = activeTabID
    }
}

/// What clicking a tile should make the browser do.
///
/// An enumeration rather than a call into the session, so that "what a click
/// means" can be decided in one place and tested, and "what the session does
/// about it" stays where the session is.
enum EssentialsAction: Sendable, Equatable {
    /// The site is already open here. Show that tab, unchanged.
    case selectTab(UUID)
    /// Nothing to do: it is already the tab you are looking at.
    case none
    /// Open it, in the active space.
    case openTab(URL)
    /// Put an existing tab back on the pinned address.
    case reset(tab: UUID, to: URL)
}

/// Why a tile could not be added.
enum EssentialsRejection: Sendable, Equatable {
    case alreadyEssential
    /// The strip is full. Reported rather than silently ignored, because the
    /// menu item shows the count and a user who has hit the cap should be told
    /// which one to remove.
    case atMaximum(Int)
}

/// What removing a tile implies.
///
/// Removing an essential does not just delete it: it is demoted into whichever
/// space you happen to be in, and never back to where it came from. That rule
/// is simple and, unlike "remember the origin", it has no wrong answer when the
/// original space has since been deleted.
struct EssentialsRemoval: Sendable, Equatable {
    /// The space whose pin list the site is removed from.
    let removeFrom: UUID
    /// The space it becomes an ordinary tab in.
    let demoteInto: UUID
    let url: URL
}

/// The behaviour of the essentials strip, with no view and no session in it.
///
/// Kylmora already draws the tiles (`PinnedTilesView`) and already stores them
/// (`PinnedSite`). What was missing is what they *do*: that a click on an
/// already-open essential shows the tab without resetting it, that
/// a second click is what resets it, that there is a limit, and that an
/// essential belongs to every space rather than to the one it was made in.
struct EssentialsController: Sendable {

    var configuration: EssentialsConfiguration

    init(configuration: EssentialsConfiguration = EssentialsConfiguration()) {
        self.configuration = configuration
    }

    // MARK: - What the strip shows

    /// The tiles to show while `snapshot.activeSpaceID` is active.
    ///
    /// When sharing is on this is every space's pins, the active space's first
    /// and the rest in space order, deduplicated by the same host-and-path rule
    /// that decides whether a pin is already open. Two spaces that pinned the
    /// same site show one tile, not two identical ones.
    func essentials(in snapshot: EssentialsSnapshot) -> [PinnedSite] {
        guard configuration.isSharedAcrossSpaces else {
            return snapshot.spaces.first { $0.id == snapshot.activeSpaceID }?.pinnedSites ?? []
        }
        // Partitioned rather than sorted: "the active one first" is not a
        // strict ordering, and `sorted` on a predicate that is not one is
        // allowed to produce anything at all.
        let ordered = snapshot.spaces.filter { $0.id == snapshot.activeSpaceID }
            + snapshot.spaces.filter { $0.id != snapshot.activeSpaceID }
        var result: [PinnedSite] = []
        for space in ordered {
            for site in space.pinnedSites where !result.contains(where: { $0.matches(site.url) }) {
                result.append(site)
            }
        }
        return result
    }

    /// `used/limit`, for the menu item that adds one.
    ///
    /// Shown on the item even when it is enabled: a count that only appears
    /// once it is too late is a count nobody reads.
    func badge(in snapshot: EssentialsSnapshot) -> String {
        "\(essentials(in: snapshot).count)/\(configuration.maximumCount)"
    }

    // MARK: - Adding and removing

    /// Nil when the site may be added, otherwise why not.
    ///
    /// The caller disables the menu item rather than hiding it: an item that
    /// vanishes at the limit reads as a bug, and an item that is visibly
    /// disabled with `12/12` beside it explains itself.
    func rejection(forAdding url: URL, in snapshot: EssentialsSnapshot) -> EssentialsRejection? {
        let current = essentials(in: snapshot)
        if current.contains(where: { $0.matches(url) }) { return .alreadyEssential }
        if current.count >= configuration.maximumCount {
            return .atMaximum(configuration.maximumCount)
        }
        return nil
    }

    func canAdd(_ url: URL, in snapshot: EssentialsSnapshot) -> Bool {
        rejection(forAdding: url, in: snapshot) == nil
    }

    /// Which space loses the pin, and which one gains a tab.
    func removal(of site: PinnedSite, in snapshot: EssentialsSnapshot) -> EssentialsRemoval? {
        guard let owner = snapshot.spaces.first(where: { space in
            space.pinnedSites.contains { $0.id == site.id }
        }) else { return nil }
        return EssentialsRemoval(
            removeFrom: owner.id,
            demoteInto: snapshot.activeSpaceID,
            url: site.url
        )
    }

    // MARK: - Clicking

    /// What a click on a tile means.
    ///
    /// The three rules, in the order they matter:
    ///
    /// 1. A single click on an essential that is already open **selects its tab
    ///    and changes nothing else**, even when that tab has navigated away
    ///    from the pinned address. This is the rule people expect to be broken
    ///    and are annoyed when it is: a pinned mail tab that snaps back to the
    ///    inbox every time you click it loses the message you were reading.
    /// 2. Clicking the tile whose tab is already in front does nothing at all,
    ///    rather than reloading it.
    /// 3. A double click is the reset, and only when there is something to
    ///    reset to.
    ///
    /// - Parameter clickCount: `NSEvent.clickCount`, passed in rather than read
    ///   from the current event so the rule can be tested.
    func activate(
        _ site: PinnedSite,
        clickCount: Int,
        in snapshot: EssentialsSnapshot
    ) -> EssentialsAction {
        let existing = openTab(matching: site, in: snapshot)
        let wantsReset = clickCount >= 2 && configuration.resetsOnDoubleClick

        guard let existing else { return .openTab(site.url) }
        if wantsReset {
            return existing.url == site.url ? .none : .reset(tab: existing.id, to: site.url)
        }
        return existing.id == snapshot.activeTabID ? .none : .selectTab(existing.id)
    }

    /// The tab a pinned site is already showing in, if any.
    ///
    /// Matched on the pin's own host-and-path rule first and on the **host**
    /// second. The host fallback is what makes rule 1 above mean anything: a
    /// pinned inbox that has been navigated to a single message is still that
    /// tile's tab, and `PinnedSite.matches` -- which compares the path -- says
    /// it is a different site. Trying the exact rule first keeps two pins on
    /// the same host pointing at their own tabs.
    ///
    /// Only the active space is searched. A shared essential can be open in
    /// several spaces at once, and jumping the user to a different space
    /// because that is where a matching tab happens to live is a context switch
    /// they did not ask for -- selecting an essential should never switch
    /// space on its own.
    private func openTab(
        matching site: PinnedSite,
        in snapshot: EssentialsSnapshot
    ) -> EssentialsSnapshot.OpenTab? {
        let here = snapshot.openTabs.filter { $0.spaceID == snapshot.activeSpaceID }
        if let exact = here.first(where: { site.matches($0.url) }) { return exact }
        guard let host = site.url.host?.lowercased() else { return nil }
        return here.first { $0.url.host?.lowercased() == host }
    }
}
