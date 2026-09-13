import Foundation

/// The custom names tabs have been given.
///
/// One table, keyed by tab id, rather than a field each tab keeps for itself.
/// A `Tab` already carries everything WebKit tells it about a page; a name the
/// user chose is the opposite kind of fact, and keeping the two apart is what
/// makes "the page title changed" and "the user renamed this" different events
/// instead of one field two things write to.
///
/// Keyed by `UUID` rather than `Tab.ID` so the whole type can be exercised
/// without constructing a tab, which needs a session, a profile and a web
/// environment.
@MainActor
final class TabNameStore {
    /// The one every tab reads through. Tests make their own.
    static let shared = TabNameStore()

    /// What a rename did, which is what decides whether anything is announced.
    enum Outcome: Equatable {
        /// The tab now carries this name.
        case named(String)
        /// The field was emptied: the tab is back to its page title.
        case cleared
        /// Nothing changed -- the same name was typed again, or an empty field
        /// was committed on a tab that never had a name.
        case unchanged
    }

    private var names: [UUID: String] = [:]

    init() {}

    func name(for id: UUID) -> String? { names[id] }

    var isEmpty: Bool { names.isEmpty }

    /// Commits what the user typed.
    ///
    /// Clearing the field is a real operation, not a rejected one: an empty
    /// value is treated as "restore the real title", which is the only
    /// discoverable way to undo a rename -- there is no separate "remove name"
    /// command to find.
    @discardableResult
    func rename(_ id: UUID, to input: String) -> Outcome {
        guard let name = TabNaming.normalized(input) else {
            guard names.removeValue(forKey: id) != nil else { return .unchanged }
            return .cleared
        }
        guard names[id] != name else { return .unchanged }
        names[id] = name
        return .named(name)
    }

    /// Drops a name without going through the editor, for a tab being closed.
    /// Names are not reference-counted by anything, so a tab that leaves has to
    /// take its entry with it or the table grows for the life of the process.
    func forget(_ id: UUID) {
        names[id] = nil
    }

    /// Seeds a name read back from the session file. Restoring is not renaming:
    /// it must not normalise, cap or report an outcome, because whatever is in
    /// the file was already a valid name when it was written.
    func restore(_ name: String?, for id: UUID) {
        names[id] = name
    }
}

extension Toast {
    /// The confirmation shown after a rename.
    ///
    /// A rename changes one row in a list the user is already looking at, so
    /// the toast is not there to report the change -- it is there to say which
    /// of the two outcomes happened, since an emptied field and a name that
    /// failed to commit look identical in the sidebar.
    static func rename(_ outcome: TabNameStore.Outcome, restoredTitle: @autoclosure () -> String) -> Toast? {
        switch outcome {
        case .named(let name):
            return Toast(symbolName: "pencil", message: "Renamed to “\(name)”", identity: "tab-rename")
        case .cleared:
            return Toast(
                symbolName: "arrow.uturn.backward",
                message: "Name cleared — showing “\(restoredTitle())”",
                identity: "tab-rename"
            )
        case .unchanged:
            return nil
        }
    }
}
