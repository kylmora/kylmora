import Foundation

/// Decides which tabs should leave the sidebar.
///
/// The second stage of a two-stage lifecycle. Sleeping is reversible and
/// invisible -- the row stays, the memory comes back -- so it can be aggressive.
/// Archiving takes the row away, so it is deliberately not: a tab must already
/// be asleep, holding no page at all, before it is eligible.
///
/// Pure logic like `TabSuspension`, for the same reason: a rule about three days
/// of idleness is only trustworthy if it can be tested in a millisecond.
@MainActor
enum TabArchiving {
    /// Everything the policy decides from, for one tab.
    struct TabState: Equatable, Sendable {
        let id: Tab.ID
        /// Holding no web view -- the first stage, reached.
        ///
        /// Two kinds of tab qualify: one that was loaded and gave its page
        /// back, and one restored or opened in the background that never had a
        /// page at all. Both are archivable, because archiving keeps the whole
        /// snapshot and a never-opened tab's snapshot is everything it ever had
        /// -- its address and its title. A tab that has never been away from
        /// the user's attention is exactly the clutter this setting exists to
        /// clear, and the sidebar already calls it sleeping.
        let isAsleep: Bool
        let lastActiveAt: Date
        /// "Keep Awake". Such a tab never suspends, so it can never reach this
        /// stage; checked anyway so the guarantee does not depend on the other
        /// policy staying correct.
        let keepsAwake: Bool
        /// "Keep in Sidebar" -- may sleep, does not leave.
        let keepsInSidebar: Bool
        /// A pinned tab or an Essential. Pinning is already the user saying
        /// this one stays, so it is never archived and needs no second lock.
        let isPinned: Bool
        /// Sitting in a Live Folder, whose contents a provider maintains.
        /// Archiving one would start a fight: the sweep removes the row, the
        /// next poll puts it back, and the two take turns forever.
        let isProviderManaged: Bool

        init(
            id: Tab.ID,
            isAsleep: Bool,
            lastActiveAt: Date,
            keepsAwake: Bool = false,
            keepsInSidebar: Bool = false,
            isPinned: Bool = false,
            isProviderManaged: Bool = false
        ) {
            self.id = id
            self.isAsleep = isAsleep
            self.lastActiveAt = lastActiveAt
            self.keepsAwake = keepsAwake
            self.keepsInSidebar = keepsInSidebar
            self.isPinned = isPinned
            self.isProviderManaged = isProviderManaged
        }
    }

    /// The rule, over values.
    ///
    /// - Parameters:
    ///   - protectedIDs: tabs currently rendered. Belt and braces: a rendered
    ///     tab is not suspended, so it cannot qualify anyway.
    ///   - threshold: how long a suspended tab may sit before it is archived,
    ///     or `nil` when the user has archiving switched off -- which is the
    ///     default, because a browser that removes tabs you did not ask it to
    ///     remove has to be opted into.
    ///   - cohorts: the members of each split, which live and die together. A
    ///     split whose panes were archived one at a time would come back as
    ///     loose tabs, so a cohort is archived whole or not at all.
    static func candidateIDs(
        among tabs: [TabState],
        protecting protectedIDs: Set<Tab.ID> = [],
        threshold: TimeInterval?,
        cohorts: [Set<Tab.ID>] = [],
        now: Date = .now
    ) -> Set<Tab.ID> {
        guard let threshold else { return [] }

        let eligible = { (tab: TabState) -> Bool in
            guard tab.isAsleep, !protectedIDs.contains(tab.id) else { return false }
            guard !tab.keepsAwake, !tab.keepsInSidebar else { return false }
            guard !tab.isPinned, !tab.isProviderManaged else { return false }
            return now.timeIntervalSince(tab.lastActiveAt) >= threshold
        }

        let chosen = Set(tabs.lazy.filter(eligible).map(\.id))

        // All-or-nothing inside a split: unless every pane qualifies, none do.
        // The opposite escalation to suspension's, and for the opposite reason
        // -- there, keeping one pane loaded wasted memory for no benefit; here,
        // taking one pane away would silently dismantle an arrangement the user
        // built by hand.
        let byID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        var excluded: Set<Tab.ID> = []
        for cohort in cohorts where !cohort.isDisjoint(with: chosen) {
            let members = cohort.filter { byID[$0] != nil }
            if !members.allSatisfy(chosen.contains) { excluded.formUnion(cohort) }
        }

        return chosen.subtracting(excluded)
    }

    /// The same rule over live tabs.
    static func candidates(
        among tabs: [Tab],
        protecting protectedIDs: Set<Tab.ID> = [],
        threshold: TimeInterval?,
        isPinned: (Tab) -> Bool = { _ in false },
        isProviderManaged: (Tab) -> Bool = { _ in false },
        cohorts: [Set<Tab.ID>] = [],
        now: Date = .now
    ) -> [Tab] {
        let states = tabs.map { tab in
            TabState(
                id: tab.id,
                isAsleep: tab.isAsleep,
                lastActiveAt: tab.lastActiveAt,
                keepsAwake: tab.keepsAwake,
                keepsInSidebar: tab.keepsInSidebar,
                isPinned: isPinned(tab),
                isProviderManaged: isProviderManaged(tab)
            )
        }
        let chosen = candidateIDs(
            among: states,
            protecting: protectedIDs,
            threshold: threshold,
            cohorts: cohorts,
            now: now
        )
        return tabs.filter { chosen.contains($0.id) }
    }
}

extension Toast {
    /// Raised when the sweep archived something.
    ///
    /// Archiving is the only thing in Kylmora that takes a row out of the
    /// sidebar without the user doing anything, so it is the only thing that
    /// has to say so. Silently removing tabs is the complaint every browser
    /// with this feature has earned; a line and an Undo is the whole of the
    /// difference between "it tidied up" and "it lost my tabs".
    static func archived(count: Int, undo: @escaping () -> Void) -> Toast {
        Toast(
            symbolName: "archivebox",
            message: count == 1 ? "1 sleeping tab archived" : "\(count) sleeping tabs archived",
            action: Action(title: "Undo", handler: undo),
            // Longer than the default: this one reports something the user did
            // not ask for, and the button undoes it. Two seconds to notice a
            // tab has gone and decide is not enough.
            duration: 6,
            // One identity for all of them, like routing: three sweeps in a row
            // is one fact. The replacement carries the newer Undo, which is the
            // one that matches what is actually gone.
            identity: "tab-archiving"
        )
    }
}
