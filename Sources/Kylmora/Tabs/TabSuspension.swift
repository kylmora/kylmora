import Foundation

/// Decides which tabs should give their memory back.
///
/// Pure logic, separated from the timer and the memory-pressure source that
/// drive it, so every rule below is a unit test rather than a guess about what
/// the browser will do after ten minutes.
@MainActor
enum TabSuspension {
    enum Trigger: Equatable {
        /// A tab has simply been in the background too long.
        case idle
        /// The system is short on memory.
        case memoryWarning
        /// The system is critically short on memory.
        case memoryCritical
    }

    /// Everything the policy decides from, for one tab.
    ///
    /// The policy reads three facts and no more, so it is stated over those
    /// three facts. That is what lets the rules be tested with plain values
    /// instead of a window, a web view and a ten-minute wait.
    struct TabState: Equatable, Sendable {
        let id: Tab.ID
        let isLoaded: Bool
        let lastActiveAt: Date

        init(id: Tab.ID, isLoaded: Bool, lastActiveAt: Date) {
            self.id = id
            self.isLoaded = isLoaded
            self.lastActiveAt = lastActiveAt
        }

        @MainActor
        init(_ tab: Tab) {
            self.init(id: tab.id, isLoaded: tab.isLoaded, lastActiveAt: tab.lastActiveAt)
        }
    }

    /// How idle a tab must be before each trigger will unload it.
    ///
    /// Chrome's Memory Saver discards background tabs after roughly five
    /// minutes when memory is tight; Kylmora uses the same shape, with the idle
    /// threshold under the user's control and pressure tightening it rather
    /// than replacing it.
    static let warningThreshold: TimeInterval = 60

    /// - Parameters:
    ///   - protectedIDs: the tabs **currently rendered**, not the selected one.
    ///     They are the same set only while one page is on screen at a time;
    ///     a split puts two to four pages there and the unfocused panes are as
    ///     visible as the focused one. Suspending them would blank a pane the
    ///     user is looking at.
    ///   - cohorts: sets of tabs that must be loaded or unloaded together --
    ///     the members of each split. Unloading is all-or-nothing inside a
    ///     cohort: a split cannot render one pane while its sibling shows
    ///     nothing, so a cohort is either entirely protected or entirely fair
    ///     game, and a single discarded pane escalates to unloading the whole
    ///     group.
    static func candidates(
        among tabs: [Tab],
        protecting protectedIDs: Set<Tab.ID>,
        idleThreshold: TimeInterval?,
        trigger: Trigger,
        cohorts: [Set<Tab.ID>] = [],
        now: Date = .now
    ) -> [Tab] {
        let chosen = candidateIDs(
            among: tabs.map(TabState.init),
            protecting: protectedIDs,
            idleThreshold: idleThreshold,
            trigger: trigger,
            cohorts: cohorts,
            now: now
        )
        return tabs.filter { chosen.contains($0.id) }
    }

    /// The rule itself, over values.
    static func candidateIDs(
        among tabs: [TabState],
        protecting protectedIDs: Set<Tab.ID>,
        idleThreshold: TimeInterval?,
        trigger: Trigger,
        cohorts: [Set<Tab.ID>] = [],
        now: Date = .now
    ) -> Set<Tab.ID> {
        let minimumIdle: TimeInterval?
        switch trigger {
        case .idle:
            // Nothing to do when the user has turned suspension off.
            guard let idleThreshold else { return [] }
            minimumIdle = idleThreshold
        case .memoryWarning:
            minimumIdle = warningThreshold
        case .memoryCritical:
            // Anything not on screen is fair game.
            minimumIdle = nil
        }

        // A rendered tab protects everything it is split with. The caller should
        // already be reporting every pane, but a cohort whose panes disagree
        // about being visible is a bug that would blank a page, so the closure
        // is taken here rather than trusted upstream.
        var protected = protectedIDs
        for cohort in cohorts where !cohort.isDisjoint(with: protectedIDs) {
            protected.formUnion(cohort)
        }

        var chosen = Set(
            tabs.lazy
                .filter { tab in
                    guard tab.isLoaded, !protected.contains(tab.id) else { return false }
                    guard let minimumIdle else { return true }
                    return now.timeIntervalSince(tab.lastActiveAt) >= minimumIdle
                }
                .map(\.id)
        )

        // All-or-nothing: if one pane of an off-screen split has gone idle, its
        // siblings go with it. Leaving them loaded would hold most of the memory
        // for none of the benefit, since the group is restored as a unit anyway.
        let loaded = Set(tabs.lazy.filter(\.isLoaded).map(\.id))
        for cohort in cohorts where !cohort.isDisjoint(with: chosen) {
            chosen.formUnion(cohort.intersection(loaded).subtracting(protected))
        }

        return chosen
    }
}
