import Foundation

/// Everything about a live folder that changes without the user touching it.
///
/// Split from the provider on purpose: the provider is what the user configured
/// and belongs with the session, this is a poll log that is rewritten every
/// half hour and belongs in its own file. Keeping them apart is also what stops
/// a refresh from dirtying the session snapshot.
struct LiveFolderState: Codable, Sendable, Equatable {
    /// The right default: a folder that polls faster than you look at it is
    /// a background tax.
    static let defaultInterval: TimeInterval = 30 * 60
    static let intervalChoices: [(seconds: TimeInterval, title: String)] = [
        (15 * 60, "Every 15 minutes"),
        (30 * 60, "Every 30 minutes"),
        (60 * 60, "Every hour"),
        (2 * 3600, "Every 2 hours"),
        (4 * 3600, "Every 4 hours"),
        (8 * 3600, "Every 8 hours")
    ]

    var interval: TimeInterval = defaultInterval
    var lastFetched: Date?
    /// Survives a relaunch, so a folder that was broken yesterday still says so
    /// this morning instead of looking empty until its first poll lands.
    var lastIssue: LiveFolderIssue?
    /// Item id -> the tab created for it. Kept here rather than on `Tab`
    /// because a tab has no business carrying a field that only one folder
    /// kind ever reads -- and because a tab the user dragged in simply is not
    /// in this map, which is exactly the "never prune what the user put
    /// there" rule, enforced by the shape of the data instead of by a check.
    var trackedTabs: [String: UUID] = [:]
    /// Items the user closed or dragged out. Suppressed until the source stops
    /// offering them.
    var dismissedItems: Set<String> = []
    /// Drives the backoff. Reset by any successful fetch.
    var consecutiveFailures: Int = 0

    /// What a fetch implies, before anything is done about it.
    struct Plan: Sendable, Equatable {
        /// Items with no tab yet and no dismissal.
        var additions: [LiveFolderItem]
        /// Tracked tabs whose item is gone from the source.
        var staleTabIDs: [UUID]
        /// Dismissals the source no longer offers, so they can be forgotten.
        var expiredDismissals: Set<String>

        var isEmpty: Bool {
            additions.isEmpty && staleTabIDs.isEmpty && expiredDismissals.isEmpty
        }
    }

    /// The reconciliation, as a pure function of state and a *successful* fetch.
    ///
    /// It takes `[LiveFolderItem]` and not `LiveFolderFetch` so that it is not
    /// even possible to call it with a failure. That is the whole safety
    /// argument: an error cannot prune because an error cannot reach the code
    /// that prunes.
    func plan(for items: [LiveFolderItem]) -> Plan {
        let fresh = Set(items.map(\.id))

        let additions = items.filter { item in
            trackedTabs[item.id] == nil && !dismissedItems.contains(item.id)
        }

        let stale = trackedTabs
            .filter { !fresh.contains($0.key) }
            .map(\.value)

        // Only prune dismissals when the source actually said something. A
        // feed that answers with an empty list for one poll must not wipe every
        // dismissal and bring back everything the user closed on the next.
        let expired = items.isEmpty ? [] : dismissedItems.subtracting(fresh)

        return Plan(additions: additions, staleTabIDs: stale, expiredDismissals: expired)
    }

    /// Records the outcome once the caller has actually opened and closed tabs.
    ///
    /// - Parameter openedTabs: item id -> the tab that was created for it.
    ///   Items the caller could not open are simply absent, and will be offered
    ///   again next poll rather than being marked as done.
    mutating func apply(_ plan: Plan, openedTabs: [String: UUID], at date: Date = .now) {
        for stale in plan.staleTabIDs {
            trackedTabs = trackedTabs.filter { $0.value != stale }
        }
        for (itemID, tabID) in openedTabs { trackedTabs[itemID] = tabID }
        dismissedItems.subtract(plan.expiredDismissals)
        lastFetched = date
        lastIssue = nil
        consecutiveFailures = 0
    }

    /// Records a failure. Touches `lastFetched` so the scheduler still measures
    /// its next delay from the last attempt rather than retrying in a tight
    /// loop, but touches nothing else -- no tab is added, removed or forgotten.
    mutating func noteIssue(_ issue: LiveFolderIssue, at date: Date = .now) {
        lastIssue = issue
        lastFetched = date
        consecutiveFailures += 1
    }

    /// The user closed a tracked tab, or dragged it out of the folder. Both are
    /// the same statement: stop showing me this one.
    mutating func dismiss(tabID: UUID) {
        guard let itemID = trackedTabs.first(where: { $0.value == tabID })?.key else { return }
        trackedTabs[itemID] = nil
        dismissedItems.insert(itemID)
    }

    /// Whether a tab is the provider's or the user's. The answer decides
    /// whether a refresh may ever close it.
    func isTracked(tabID: UUID) -> Bool {
        trackedTabs.values.contains(tabID)
    }

    /// When the next poll is due.
    ///
    /// Measured from the last attempt, so waking after a long sleep produces one
    /// catch-up fetch rather than one per interval that elapsed. A failure adds
    /// exponential backoff on top, capped, and a rate limit with a server-stated
    /// delay wins outright -- retrying inside a stated `Retry-After` is how a
    /// client earns a longer one.
    func nextFetchDelay(now: Date = .now) -> TimeInterval {
        if case .rateLimited(let retryAfter) = lastIssue, let retryAfter {
            return max(retryAfter, 60)
        }
        guard let lastFetched else { return 0 }
        let elapsed = now.timeIntervalSince(lastFetched)
        let backoff = consecutiveFailures > 0
            ? min(interval * pow(2, Double(min(consecutiveFailures, 4))), 4 * 3600)
            : 0
        return max(interval + backoff - elapsed, 0)
    }
}

/// A live folder as it is written to disk: which folder, what it polls, and
/// what happened last time.
struct LiveFolderRecord: Codable, Sendable, Equatable, Identifiable {
    /// The `TabGroup` this belongs to. The folder itself lives in the session
    /// snapshot; this is a side table keyed by it.
    let id: UUID
    var source: LiveFolderSource
    var state: LiveFolderState

    func makeProvider() -> any LiveFolderProvider { source.makeProvider() }
}
