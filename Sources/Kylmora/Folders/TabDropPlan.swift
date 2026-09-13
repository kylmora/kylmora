import Foundation

/// Where a tab dropped on the sidebar ends up: which folder, and at what
/// position in the space's own tab order.
///
/// A pure function of the rows the sidebar is showing, so the rule can be
/// tested without a table view. The sidebar's drag used to reorder tabs and
/// never change their folder; this is what lets a tab be filed into a folder,
/// threaded between a folder's children, or pulled back out to the top level
/// by dropping it there.
@MainActor
enum TabDropPlan {
    /// The sidebar's rows, reduced to what the plan needs to know.
    enum Row: Equatable {
        case folder(TabGroup, depth: Int)
        /// `isEscaping`: drawn under a collapsed folder because it is selected.
        case tab(Tab, depth: Int, isEscaping: Bool)
        /// A status line or the New Tab row: something at this depth that a
        /// drop lands before, never in.
        case other(depth: Int)

        var depth: Int {
            switch self {
            case .folder(_, let depth), .tab(_, let depth, _), .other(let depth): return depth
            }
        }

        static func == (lhs: Row, rhs: Row) -> Bool {
            switch (lhs, rhs) {
            case let (.folder(a, ad), .folder(b, bd)): return a.id == b.id && ad == bd
            case let (.tab(a, ad, ae), .tab(b, bd, be)): return a.id == b.id && ad == bd && ae == be
            case let (.other(a), .other(b)): return a == b
            default: return false
            }
        }
    }

    struct Destination: Equatable {
        /// Nil is the top level: out of every folder.
        let groupID: TabGroup.ID?
        /// A pre-removal insertion index into the space's tabs, the same
        /// convention `Space.move(from:to:)` uses.
        let tabIndex: Int
    }

    /// A drop between two rows: above `row`, or at the end when `row` is the
    /// row count. Nil when the landing folder cannot take a tab.
    ///
    /// The folder is read off the row the drop lands above: above a tab means
    /// beside that tab, in whatever it is in; above a folder header means at
    /// the header's own level, which is its parent's. A tab escaping a
    /// collapsed folder counts as the folder it pokes out of, so a drop above
    /// it lands at the folder's level rather than inside a folder that is shut.
    static func between(
        rows: [Row],
        row: Int,
        tabs: [Tab],
        groups: [TabGroup]
    ) -> Destination? {
        guard rows.indices.contains(row) else {
            return Destination(groupID: nil, tabIndex: tabs.count)
        }
        let groupID: TabGroup.ID?
        switch rows[row] {
        case .tab(let tab, _, let isEscaping):
            if isEscaping {
                groupID = FolderTree.folder(withID: tab.groupID, in: groups)?.parentID
            } else {
                groupID = tab.groupID
            }
        case .folder(let folder, _):
            groupID = folder.parentID
        case .other(let depth):
            // A status line sits under a live folder's header; the New Tab
            // row sits at the root. Either way the folder is the nearest
            // header above at a shallower depth.
            groupID = enclosingFolder(above: row, depth: depth, rows: rows)?.id
        }
        if let groupID, let folder = FolderTree.folder(withID: groupID, in: groups),
           !FolderTree.canAcceptTab(folder, in: groups) {
            return nil
        }
        return Destination(groupID: groupID, tabIndex: firstTabIndex(atOrAfter: row, rows: rows, tabs: tabs))
    }

    /// A drop on a folder header, resolved by `FolderDropZone`.
    static func onto(
        folder: TabGroup,
        target: FolderDropTarget,
        tabs: [Tab],
        groups: [TabGroup]
    ) -> Destination? {
        let own = tabs.indices.filter { tabs[$0].groupID == folder.id }
        switch target {
        case .intoFolderAtStart:
            return Destination(groupID: folder.id, tabIndex: own.first ?? tabs.count)
        case .intoFolderAtEnd:
            return Destination(groupID: folder.id, tabIndex: own.last.map { $0 + 1 } ?? tabs.count)
        case .afterFolder:
            // Past the whole subtree, not just the folder's own tabs.
            var subtree: Set<TabGroup.ID> = [folder.id]
            subtree.formUnion(FolderTree.descendants(of: folder, in: groups).map(\.id))
            let last = tabs.indices.last { tabs[$0].groupID.map(subtree.contains) ?? false }
            return Destination(groupID: folder.parentID, tabIndex: last.map { $0 + 1 } ?? tabs.count)
        case .rejected:
            return nil
        }
    }

    /// The row a drop "after this folder" lands above: the first row past the
    /// folder's block, which is the next row no deeper than the header.
    static func rowAfterBlock(of headerRow: Int, rows: [Row]) -> Int {
        guard rows.indices.contains(headerRow) else { return rows.count }
        let depth = rows[headerRow].depth
        var row = headerRow + 1
        while row < rows.count, rows[row].depth > depth { row += 1 }
        return row
    }

    private static func firstTabIndex(atOrAfter row: Int, rows: [Row], tabs: [Tab]) -> Int {
        for entry in rows[min(row, rows.count)...] {
            if case .tab(let tab, _, _) = entry, let index = tabs.firstIndex(where: { $0.id == tab.id }) {
                return index
            }
        }
        return tabs.count
    }

    private static func enclosingFolder(above row: Int, depth: Int, rows: [Row]) -> TabGroup? {
        guard depth > 0 else { return nil }
        for entry in rows[..<row].reversed() {
            if case .folder(let folder, let folderDepth) = entry, folderDepth < depth { return folder }
        }
        return nil
    }
}
