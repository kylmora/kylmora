import AppKit

/// Where a drag hovering over a folder header would land.
@MainActor
enum FolderDropTarget: Equatable {
    /// Into the folder, as its first child. The top strip of the header.
    case intoFolderAtStart(TabGroup.ID)
    /// Into the folder, appended after whatever it already holds.
    case intoFolderAtEnd(TabGroup.ID)
    /// Past the folder entirely: a sibling below it, at the folder's own level.
    case afterFolder(TabGroup.ID)
    /// The drag is legal but not here -- draw nothing, accept nothing.
    case rejected

    var folderID: TabGroup.ID? {
        switch self {
        case .intoFolderAtStart(let id), .intoFolderAtEnd(let id), .afterFolder(let id): return id
        case .rejected: return nil
        }
    }

    /// Whether the folder header should be highlighted as a container. Only the
    /// two "into" answers light the folder up; a sibling drop draws the ordinary
    /// insertion line instead, and a rejection draws nothing at all.
    var highlightsFolder: Bool {
        switch self {
        case .intoFolderAtStart, .intoFolderAtEnd: return true
        case .afterFolder, .rejected: return false
        }
    }
}

/// What the dragged thing is, from the drop validator's point of view.
@MainActor
enum FolderDragPayload {
    case tab(Tab)
    case folder(TabGroup)
    /// An address dragged in from outside: a link on a page, the address bar.
    /// It becomes a new tab wherever it lands.
    case link
}

/// The asymmetric drop zone over a folder header.
///
/// A folder header is a 40-point row and it has two jobs that compete for the
/// same pixels: it is the biggest, most obvious target for "put this in here",
/// and it is also the only thing between the row above it and the folder's
/// first child. Splitting it evenly in three -- before / into / after, the
/// conventional outline-view rule -- gives the "before" strip pixels it does
/// not need, because the row *above* the header already ends in an insertion
/// zone that means exactly that. So there is no "before" strip here at all:
///
/// - **Top 20%** is always *into, at the start*. It is the only way to say "make
///   this the folder's first tab" without expanding the folder first.
/// - **Bottom 20%** is *after the folder* -- a sibling -- but only when the
///   folder is open and already holds something. An open folder with children
///   draws its first child directly underneath, and that row carries its own
///   insertion zone, so the header can afford to give its last 8 points to the
///   sibling case. A **collapsed** folder has no such row beneath it, and a
///   **nearly empty** one has nothing worth threading between, so for those two
///   the bottom strip stays *into, at the end*: the whole header is a target.
/// - **The middle 60%** is always *into*.
///
/// The asymmetry is the point. Dropping onto a folder means filing, and filing
/// should be the easy thing to hit; escaping to a sibling position is the rarer
/// intent and is given the edge that is cheapest to give away.
@MainActor
enum FolderDropZone {
    /// Fractions of the header height, measured from its top edge.
    static let intoStartFraction: CGFloat = 0.2
    static let siblingFraction: CGFloat = 0.2

    /// At or below this many tabs a folder counts as "nearly empty" and keeps
    /// its bottom strip as a drop target. One tab, because a folder holding a
    /// single row is still mostly header, and aiming for the 8 points under it
    /// is not a gesture anyone should have to make.
    static let nearlyEmptyTabCount = 1

    /// - Parameters:
    ///   - point: in the header view's own coordinates.
    ///   - bounds: the header view's bounds.
    ///   - isFlipped: pass the view's `isFlipped`, so callers do not have to
    ///     convert; AppKit views are not flipped by default and a sidebar row
    ///     may be either.
    static func target(
        at point: NSPoint,
        in bounds: NSRect,
        isFlipped: Bool,
        folder: TabGroup,
        tabCount: Int,
        payload: FolderDragPayload,
        groups: [TabGroup]
    ) -> FolderDropTarget {
        guard bounds.height > 0 else { return .rejected }
        let fromTop = isFlipped ? point.y - bounds.minY : bounds.maxY - point.y
        return target(
            fractionFromTop: fromTop / bounds.height,
            folder: folder,
            tabCount: tabCount,
            payload: payload,
            groups: groups
        )
    }

    /// The rule itself, in fractions, so it can be tested without a view.
    static func target(
        fractionFromTop: CGFloat,
        folder: TabGroup,
        tabCount: Int,
        payload: FolderDragPayload,
        groups: [TabGroup]
    ) -> FolderDropTarget {
        let fraction = min(max(fractionFromTop, 0), 1)
        let sibling = FolderDropTarget.afterFolder(folder.id)

        guard accepts(payload, folder: folder, groups: groups) else {
            // A refused container still lets the drag past it: landing below an
            // unsuitable folder is a legitimate thing to want, and refusing the
            // whole row would make the sidebar feel broken rather than strict.
            return isInSiblingStrip(fraction, folder: folder, tabCount: tabCount) ? sibling : .rejected
        }

        if fraction < intoStartFraction { return .intoFolderAtStart(folder.id) }
        if isInSiblingStrip(fraction, folder: folder, tabCount: tabCount) { return sibling }
        return .intoFolderAtEnd(folder.id)
    }

    /// The bottom strip only means "sibling" when there is a child row below the
    /// header to take over the precise-insertion job.
    private static func isInSiblingStrip(
        _ fraction: CGFloat,
        folder: TabGroup,
        tabCount: Int
    ) -> Bool {
        guard fraction > 1 - siblingFraction else { return false }
        if folder.isCollapsed { return false }
        return tabCount > nearlyEmptyTabCount
    }

    /// Whether this folder can take this payload at all. The depth cap is
    /// enforced here, which is the same call `FolderTree.canNest` backs, so the
    /// drop validator and the disabled "New Subfolder" menu item cannot drift.
    static func accepts(
        _ payload: FolderDragPayload,
        folder: TabGroup,
        groups: [TabGroup]
    ) -> Bool {
        switch payload {
        case .tab(let tab):
            guard FolderTree.canAcceptTab(folder, in: groups) else { return false }
            // Dropping a tab onto the folder it is already in is not a move.
            return tab.groupID != folder.id
        case .link:
            return FolderTree.canAcceptTab(folder, in: groups)
        case .folder(let dragged):
            guard !folder.isLive, !dragged.isLive else { return false }
            guard dragged.id != folder.id else { return false }
            guard dragged.parentID != folder.id else { return false }
            return FolderTree.canNest(dragged, under: folder, in: groups)
        }
    }
}
