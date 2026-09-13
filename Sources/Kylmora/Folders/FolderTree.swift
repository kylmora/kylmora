import AppKit

/// The nesting rules for folders, over the Space's flat `[TabGroup]`.
///
/// Every question about the tree is answered here rather than on `TabGroup`,
/// because a single group can only see its own `parentID` and none of the
/// interesting answers -- depth, descendants, whether a move would make a cycle
/// -- are local. Keeping them in one enum is also what lets the three places
/// the depth cap must be enforced agree with each other by construction: the
/// "New Subfolder" menu item, the drop validator and the drag highlight all
/// call `canAcceptSubfolder` rather than each doing their own arithmetic.
///
/// Every walk here is bounded by the group count and carries a visited set.
/// A `parentID` chain comes off disk, and a corrupt or hand-edited session file
/// can contain a cycle; that must degrade to "treat it as a root" rather than
/// spin the main thread.
@MainActor
enum FolderTree {
    /// Levels 0 through 4. Read live rather than once at startup: there is no
    /// reason for changing the limit to need a relaunch.
    static let maximumDepth = 5

    /// One step per level, so a level-2 tab sits 28 points in.
    static let indentPerLevel: CGFloat = 14

    static func indent(forDepth depth: Int) -> CGFloat {
        CGFloat(max(depth, 0)) * indentPerLevel
    }

    // MARK: - Walking

    static func folder(withID id: TabGroup.ID?, in groups: [TabGroup]) -> TabGroup? {
        guard let id else { return nil }
        return groups.first { $0.id == id }
    }

    static func parent(of folder: TabGroup, in groups: [TabGroup]) -> TabGroup? {
        folder.parentID.flatMap { id in groups.first { $0.id == id } }
    }

    /// Nearest ancestor first.
    static func ancestors(of folder: TabGroup, in groups: [TabGroup]) -> [TabGroup] {
        var result: [TabGroup] = []
        var seen: Set<TabGroup.ID> = [folder.id]
        var current = parent(of: folder, in: groups)
        while let next = current, !seen.contains(next.id) {
            result.append(next)
            seen.insert(next.id)
            current = parent(of: next, in: groups)
        }
        return result
    }

    /// 0 for a root folder. A folder caught in a cycle reports 0, which makes it
    /// behave as a root rather than as an infinitely deep child.
    static func depth(of folder: TabGroup, in groups: [TabGroup]) -> Int {
        ancestors(of: folder, in: groups).count
    }

    /// Direct children, in the Space's own group order.
    static func children(of folder: TabGroup.ID?, in groups: [TabGroup]) -> [TabGroup] {
        groups.filter { $0.parentID == folder }
    }

    /// The whole subtree below a folder, excluding the folder itself.
    static func descendants(of folder: TabGroup, in groups: [TabGroup]) -> [TabGroup] {
        var result: [TabGroup] = []
        var frontier = children(of: folder.id, in: groups)
        var seen: Set<TabGroup.ID> = [folder.id]
        while let next = frontier.popLast() {
            guard seen.insert(next.id).inserted else { continue }
            result.append(next)
            frontier.append(contentsOf: children(of: next.id, in: groups))
        }
        return result
    }

    /// How many levels the folder's own subtree occupies: 1 for a leaf.
    /// A move must fit the whole subtree under the cap, not just the folder.
    static func subtreeHeight(of folder: TabGroup, in groups: [TabGroup]) -> Int {
        let base = depth(of: folder, in: groups)
        let deepest = descendants(of: folder, in: groups)
            .map { depth(of: $0, in: groups) }
            .max() ?? base
        return deepest - base + 1
    }

    static func isDescendant(_ candidate: TabGroup, of folder: TabGroup, in groups: [TabGroup]) -> Bool {
        ancestors(of: candidate, in: groups).contains { $0.id == folder.id }
    }

    /// Root folders first, each immediately followed by its own subtree, with
    /// the depth each row should be indented by. This is the order the sidebar
    /// draws and the order "move to folder" menus list.
    static func ordered(_ groups: [TabGroup]) -> [(folder: TabGroup, depth: Int)] {
        var result: [(folder: TabGroup, depth: Int)] = []
        var seen: Set<TabGroup.ID> = []

        func visit(_ folder: TabGroup, depth: Int) {
            guard seen.insert(folder.id).inserted else { return }
            result.append((folder, depth))
            for child in children(of: folder.id, in: groups) {
                visit(child, depth: depth + 1)
            }
        }

        let known = Set(groups.map(\.id))
        for folder in groups {
            // A folder whose parent was deleted, or which is caught in a cycle,
            // is drawn as a root rather than vanishing from the sidebar.
            let isRoot = folder.parentID.map { !known.contains($0) } ?? true
            if isRoot { visit(folder, depth: 0) }
        }
        for folder in groups where !seen.contains(folder.id) {
            visit(folder, depth: 0)
        }
        return result
    }

    // MARK: - Rules

    /// Whether a *new* subfolder may be created inside this one. Disabled at
    /// `level >= maximumDepth - 1`, so the deepest folder a user can make is
    /// level 4.
    static func canAcceptSubfolder(_ folder: TabGroup, in groups: [TabGroup]) -> Bool {
        depth(of: folder, in: groups) < maximumDepth - 1
    }

    /// Whether `folder` may be moved under `newParent` (`nil` meaning the root).
    ///
    /// Three refusals, and all three matter: a folder cannot be its own parent,
    /// cannot be filed inside its own subtree -- which would detach that whole
    /// subtree from the sidebar -- and cannot be moved somewhere its deepest
    /// descendant would land past the cap.
    static func canNest(_ folder: TabGroup, under newParent: TabGroup?, in groups: [TabGroup]) -> Bool {
        guard let newParent else { return true }
        if newParent.id == folder.id { return false }
        if isDescendant(newParent, of: folder, in: groups) { return false }
        let landingDepth = depth(of: newParent, in: groups) + 1
        return landingDepth + subtreeHeight(of: folder, in: groups) - 1 < maximumDepth
    }

    /// Whether a plain tab may be filed into this folder. Depth never blocks a
    /// tab: a tab is not a level, it is a leaf, so a level-4 folder still takes
    /// tabs even though it cannot take subfolders.
    static func canAcceptTab(_ folder: TabGroup, in groups: [TabGroup]) -> Bool {
        // A live folder's contents are the provider's to decide. Dropping into
        // one would create a tab the next refresh cannot account for, since it
        // carries no item id -- the reconciler would leave it forever.
        !folder.isLive
    }

    /// Reparents a folder if the move is legal, and reports whether it happened
    /// so a caller can leave the drag indicator alone when it did not.
    @discardableResult
    static func nest(_ folder: TabGroup, under newParent: TabGroup?, in groups: [TabGroup]) -> Bool {
        guard canNest(folder, under: newParent, in: groups) else { return false }
        folder.parentID = newParent?.id
        return true
    }

    /// Expands every ancestor of a folder, so that a newly created subfolder is
    /// visible where it was created rather than inside something closed.
    static func revealAncestors(of folder: TabGroup, in groups: [TabGroup]) {
        for ancestor in ancestors(of: folder, in: groups) { ancestor.isCollapsed = false }
    }

    /// The outermost collapsed folder above a row, which is the one a tab has
    /// to escape from to stay visible. `nil` when nothing above it is closed.
    static func rootMostCollapsedAncestor(of folder: TabGroup, in groups: [TabGroup]) -> TabGroup? {
        ancestors(of: folder, in: groups).last { $0.isCollapsed }
    }

    /// Whether a folder's own row is visible: it is, unless something above it
    /// is collapsed.
    static func isVisible(_ folder: TabGroup, in groups: [TabGroup]) -> Bool {
        !ancestors(of: folder, in: groups).contains { $0.isCollapsed }
    }
}
