import Foundation

/// Owns the routing rules and answers the one question the browser asks of
/// them: where should this new tab open?
///
/// The matching itself is in `SpaceRouter`, which knows nothing about files or
/// about when routing is allowed to apply. This type adds those two things and
/// nothing else, so the rules that decide a destination stay testable without a
/// disk.
@MainActor
final class SpaceRoutingService {
    /// Why a tab is being opened. Routing deliberately does not apply to all of
    /// them: a restored session must land exactly where it was saved, and a tab
    /// the user explicitly opened next to another one is a placement they chose.
    enum Context: Equatable {
        /// A URL opened from the command bar, a link, or a bookmark.
        case newTab(SpaceRouter.Origin)
        /// A tab being rebuilt from the session file.
        case restore
        /// A child tab from `window.open`, or a tab being filed into a group,
        /// where a placement has already been decided.
        case placed
    }

    private(set) var rules: SpaceRoutingRules
    private let store: SpaceRoutingStore

    init(store: SpaceRoutingStore = SpaceRoutingStore()) {
        self.store = store
        self.rules = store.load()
    }

    /// Nothing to match against and nowhere for an unmatched external link to
    /// go means every lookup can be skipped outright.
    var isActive: Bool { !rules.routes.isEmpty || rules.externalDefault != .mostRecentSpace }

    /// The destination for a tab about to be opened.
    func decision(
        for url: URL,
        context: Context,
        currentSpaceID: UUID,
        knownSpaceIDs: Set<UUID>
    ) -> SpaceRouter.Decision {
        guard isActive, case .newTab(let origin) = context else { return .stay }
        return SpaceRouter.decision(
            for: url,
            rules: rules,
            origin: origin,
            currentSpaceID: currentSpaceID,
            knownSpaceIDs: knownSpaceIDs
        )
    }

    // MARK: - Editing

    /// Replaces the whole rule set, which is what the rules editor commits on
    /// close. Rules are edited as a list, so a per-rule API would only ever be
    /// called in a loop.
    func replace(with rules: SpaceRoutingRules) {
        self.rules = rules.discardingEmptyRoutes()
        persist()
    }

    func add(_ route: SpaceRoute) {
        guard !route.isEmpty else { return }
        rules.routes.append(route)
        persist()
    }

    func remove(_ route: SpaceRoute) {
        rules.routes.removeAll { $0.id == route.id }
        persist()
    }

    /// Removes every rule pointing at a space that no longer exists.
    ///
    /// A dangling rule is already harmless -- `SpaceRouter` treats an unknown
    /// space as a miss -- but leaving it in the editor shows the user a rule
    /// with no destination and no explanation.
    func removeRoutes(toSpacesNotIn knownSpaceIDs: Set<UUID>) {
        let survivors = rules.routes.filter { route in
            guard case .space(let id) = route.destination else { return true }
            return knownSpaceIDs.contains(id)
        }
        guard survivors.count != rules.routes.count else { return }
        rules.routes = survivors
        if case .space(let id) = rules.externalDefault, !knownSpaceIDs.contains(id) {
            rules.externalDefault = .mostRecentSpace
        }
        persist()
    }

    private func persist() {
        try? store.save(rules)
    }
}

extension Toast {
    /// Raised when a tab was routed to another space in the background.
    ///
    /// A routed tab that switches space announces itself: the window changed.
    /// A routed tab opened in the background does not, and without this the
    /// user's link would appear to have gone nowhere -- which is exactly the
    /// complaint routing exists to avoid.
    static func routed(to spaceName: String, reveal: @escaping () -> Void) -> Toast {
        Toast(
            symbolName: "arrow.turn.down.right",
            message: "Opened in \(spaceName)",
            action: Action(title: "Show", handler: reveal),
            // One identity for all of them: five links opened into Work in a
            // row is one fact, not five.
            identity: "space-routing"
        )
    }
}
