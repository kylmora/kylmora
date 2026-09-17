import Foundation

/// Working out what a list rebuild actually did to a list.
///
/// A rebuild hands over a new set of rows and says nothing about how it differs
/// from the old one, so the cheap answer is to throw every row away and draw
/// them again. That is correct and it is what the sidebar used to do, and it is
/// also why opening a tab and closing one looked identical: the list simply was
/// different now. Nothing arrived and nothing left, because a list that is
/// rebuilt has no history to have arrived from.
///
/// This works out the history. It is a pure function of two lists of
/// identities, which is what makes it testable without a table, a window or a
/// session -- and a diff is exactly the sort of thing that should be, because
/// the failure mode is not a wrong picture but a raised exception: a table told
/// a half-truth about its own row count does not misdraw, it crashes.
enum RowChangePlan {

    /// What to tell the table.
    enum Change: Equatable {
        /// Rows came or went, at these positions. `removed` indexes the old
        /// list and `inserted` the new one, which is the order a table applies
        /// them in and the reason they cannot be one set.
        case edits(removed: IndexSet, inserted: IndexSet)
        /// Nothing came or went. The rows are the same rows in the same order,
        /// so whatever changed is content and no row should move.
        case contentOnly
        /// Not expressible as insertions and removals -- a reorder, or a first
        /// fill with nothing to compare against. The caller reloads.
        case reload
    }

    /// The change that turns `before` into `after`.
    ///
    /// Both lists are assumed to hold no duplicates, which is what "identity"
    /// means: two rows standing for the same thing are the same row. A list
    /// that broke that would get `.reload`, which is the safe answer anyway.
    static func change<ID: Hashable>(from before: [ID], to after: [ID]) -> Change {
        // Nothing to have come from. A first fill is not an arrival.
        guard !before.isEmpty else { return .reload }

        let beforeSet = Set(before)
        let afterSet = Set(after)
        guard beforeSet.count == before.count, afterSet.count == after.count else { return .reload }

        // The rows that survived, in the order each list has them. If those two
        // disagree then the survivors have changed places relative to each
        // other, which is a move: no combination of insertions and removals
        // produces it, so the whole list has to be redrawn.
        guard before.filter(afterSet.contains) == after.filter(beforeSet.contains) else {
            return .reload
        }

        let removed = IndexSet(before.indices.filter { !afterSet.contains(before[$0]) })
        let inserted = IndexSet(after.indices.filter { !beforeSet.contains(after[$0]) })
        guard !removed.isEmpty || !inserted.isEmpty else { return .contentOnly }
        return .edits(removed: removed, inserted: inserted)
    }
}
