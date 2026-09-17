import Foundation
import Testing
@testable import Kylmora

// The diff behind the sidebar's arrivals and departures. Pure values, no table:
// the point of pulling it out of the view controller was that a wrong answer
// here crashes a table rather than misdrawing it, so it is worth pinning down
// exactly.

@Suite("Row change plan")
struct RowChangePlanTests {

    @Test("A tab opened at the end is one insertion and nothing else")
    func insertAtEnd() {
        let change = RowChangePlan.change(from: ["a", "b", "new"], to: ["a", "b", "c", "new"])
        #expect(change == .edits(removed: IndexSet(), inserted: IndexSet(integer: 2)))
    }

    @Test("A tab closed in the middle is one removal at its old index")
    func removeFromMiddle() {
        let change = RowChangePlan.change(from: ["a", "b", "c"], to: ["a", "c"])
        #expect(change == .edits(removed: IndexSet(integer: 1), inserted: IndexSet()))
    }

    @Test("Removals index the old list and insertions the new one")
    func indicesAreInTheirOwnLists() {
        // "b" leaves and "z" arrives at the front: the removal is at 1 in the
        // old list, the insertion at 0 in the new one. Read against the wrong
        // list, either would point at the wrong row.
        let change = RowChangePlan.change(from: ["a", "b", "c"], to: ["z", "a", "c"])
        #expect(change == .edits(removed: IndexSet(integer: 1), inserted: IndexSet(integer: 0)))
    }

    @Test("A reorder is not expressible as edits, so the caller is told to reload")
    func reorderFallsBack() {
        #expect(RowChangePlan.change(from: ["a", "b", "c"], to: ["c", "b", "a"]) == .reload)
        // A drag of one row past another is the common case, and the one that
        // would otherwise be mistaken for an unrelated insert and remove.
        #expect(RowChangePlan.change(from: ["a", "b", "c"], to: ["b", "a", "c"]) == .reload)
    }

    @Test("An unchanged list is a content change, not a no-op and not a reload")
    func unchangedIsContentOnly() {
        #expect(RowChangePlan.change(from: ["a", "b"], to: ["a", "b"]) == .contentOnly)
    }

    @Test("A first fill has no history to have arrived from")
    func firstFillReloads() {
        #expect(RowChangePlan.change(from: [String](), to: ["a", "b"]) == .reload)
    }

    @Test("Emptying a list removes every row it had")
    func clearingRemovesEverything() {
        let change = RowChangePlan.change(from: ["a", "b"], to: [])
        #expect(change == .edits(removed: IndexSet(integersIn: 0..<2), inserted: IndexSet()))
    }

    @Test("Several tabs closed at once are one batch of removals")
    func multipleRemovals() {
        let change = RowChangePlan.change(from: ["a", "b", "c", "d"], to: ["b", "d"])
        #expect(change == .edits(removed: IndexSet([0, 2]), inserted: IndexSet()))
    }

    @Test("A swap of contents is both a removal and an insertion")
    func replacementIsBoth() {
        let change = RowChangePlan.change(from: ["a", "b"], to: ["a", "c"])
        #expect(change == .edits(removed: IndexSet(integer: 1), inserted: IndexSet(integer: 1)))
    }

    @Test("Duplicates are not identities, so the plan refuses to guess")
    func duplicatesReload() {
        #expect(RowChangePlan.change(from: ["a", "a"], to: ["a"]) == .reload)
        #expect(RowChangePlan.change(from: ["a"], to: ["a", "a"]) == .reload)
    }

    @Test("A list with nothing in common is a different list, not a mass swap")
    func wholesaleReplacementIsStillEdits() {
        // The plan itself will happily express this as "remove everything,
        // insert everything", which is arithmetically true and visually awful.
        // The plan is not where that is decided -- the sidebar refuses to diff
        // across a space change at all -- but the shape is pinned here so the
        // caller's reason for refusing stays legible.
        let change = RowChangePlan.change(from: ["a", "b"], to: ["x", "y"])
        #expect(change == .edits(removed: IndexSet(integersIn: 0..<2),
                                 inserted: IndexSet(integersIn: 0..<2)))
    }

    /// The property that actually keeps the table alive: applying the plan to
    /// the old list has to produce the new one exactly. A table is told the
    /// same thing, and checks it.
    @Test("Applying the plan to the old list always yields the new one")
    func planReconstructsTheNewList() {
        let cases: [([String], [String])] = [
            (["a", "b", "new"], ["a", "b", "c", "new"]),
            (["a", "b", "c"], ["a", "c"]),
            (["a", "b", "c"], ["z", "a", "c"]),
            (["a", "b", "c", "d"], ["b", "d"]),
            (["a", "b"], ["a", "c"]),
            (["a", "b"], []),
            (["a"], ["a", "b", "c"])
        ]
        for (before, after) in cases {
            guard case .edits(let removed, let inserted) =
                    RowChangePlan.change(from: before, to: after) else { continue }
            var rows = before
            for index in removed.reversed() { rows.remove(at: index) }
            for index in inserted { rows.insert(after[index], at: index) }
            #expect(rows == after, "rebuilding \(before) into \(after) produced \(rows)")
        }
    }
}
