import CoreGraphics
import Foundation

/// The shape of one split: which tabs are on screen together, how they are
/// arranged, and how much of the content area each one gets.
///
/// Pure value logic with no AppKit in it, for the same reason `URLResolver` and
/// `TabSuspension` are: the rules that decide what happens when a pane is
/// dropped, added or dragged are the part with judgement in them, and they are
/// worth more as unit tests than as behaviour discovered by dragging a divider.
///
/// Sizes are **fractions of the parent node**, never points. That is what makes
/// a window resize free -- the proportions are already correct at the new size,
/// so nothing has to be recomputed -- and what makes the layout serialisable
/// without recording the window geometry it was captured at -- which is what
/// `Codable` here is for: the session store is where a split belongs,
/// not `NSSplitView`'s autosave, which would put per-tab-group state in
/// `UserDefaults` and restore it into whatever tabs happened to be there.
struct SplitLayout: Equatable, Codable, Sendable {

    /// Four panes, checked at every site that could add one.
    ///
    /// The cap is not arbitrary: the fifth pane in a
    /// 1440-point content area is narrower than a phone viewport, so every site
    /// in the split renders its mobile layout.
    static let maximumPanes = 4

    /// The smallest fraction a pane may be dragged down to, a floor of 7%.
    ///
    /// A minimum in points would behave differently on a laptop and on a large
    /// display; a minimum in percent keeps "how far can I squash this" the same
    /// gesture everywhere.
    static let minimumShare = 0.07

    /// Which way a node lays its children out.
    ///
    /// `horizontal` means the children sit beside each other and the divider
    /// between them is a vertical line -- the opposite of `NSSplitView.isVertical`,
    /// which names the divider rather than the flow. The mapping happens once,
    /// in `SplitContainerView`.
    enum Axis: Equatable, Codable, Sendable {
        case horizontal
        case vertical
    }

    /// The arrangement the user asked for, kept so a later "make it a grid"
    /// can rebuild the tree and so the choice survives a restart.
    enum Grid: Equatable, Codable, Sendable {
        /// Every pane in one row.
        case sideBySide
        /// Every pane in one column.
        case stacked
        /// Pairs stacked into columns. Identical to `sideBySide` at two panes.
        case grid
    }

    indirect enum Node: Equatable, Codable, Sendable {
        case pane(id: Tab.ID, share: Double)
        case split(axis: Axis, children: [Node], share: Double)

        var share: Double {
            get {
                switch self {
                case .pane(_, let share), .split(_, _, let share): return share
                }
            }
            set {
                switch self {
                case .pane(let id, _): self = .pane(id: id, share: newValue)
                case .split(let axis, let children, _): self = .split(axis: axis, children: children, share: newValue)
                }
            }
        }
    }

    /// What removing a tab did to the split.
    enum Removal: Equatable, Sendable {
        /// The split dropped below two panes and no longer exists. Dissolving
        /// at exactly this point rather than showing a one-pane split matters
        /// because a split of one is indistinguishable from a normal tab except
        /// for the state it leaves behind.
        case dissolved(remaining: [Tab.ID])
        case resized(SplitLayout)
    }

    /// Which way focus is being asked to move, in screen terms.
    enum Direction: Equatable, Sendable {
        case left, right, up, down
    }

    private(set) var root: Node
    private(set) var grid: Grid

    // MARK: - Construction

    /// Fails when the input cannot make a split: fewer than two distinct tabs,
    /// or more than `maximumPanes`. Duplicates are dropped first, because every
    /// caller that can produce them (a multi-selection, a drag that includes the
    /// target) would otherwise produce a split showing one tab twice.
    init?(tabs: [Tab.ID], grid: Grid) {
        var seen: Set<Tab.ID> = []
        let unique = tabs.filter { seen.insert($0).inserted }
        guard unique.count >= 2, unique.count <= Self.maximumPanes else { return nil }

        self.grid = grid
        self.root = Self.tree(for: unique, grid: grid)
    }

    private init(root: Node, grid: Grid) {
        self.root = root
        self.grid = grid
    }

    private static func tree(for tabs: [Tab.ID], grid: Grid) -> Node {
        switch grid {
        case .sideBySide:
            return balanced(tabs.map { .pane(id: $0, share: 0) }, axis: .horizontal, share: 1)
        case .stacked:
            return balanced(tabs.map { .pane(id: $0, share: 0) }, axis: .vertical, share: 1)
        case .grid:
            // Two panes have no second row to fill, so a grid of two is a row,
            // which is why `grid` is a safe default for a gesture that does not
            // say which way it meant.
            guard tabs.count > 2 else {
                return balanced(tabs.map { .pane(id: $0, share: 0) }, axis: .horizontal, share: 1)
            }
            let columnCount = (tabs.count + 1) / 2
            let columnShare = 1.0 / Double(columnCount)
            var columns: [Node] = []
            var index = 0
            while index < tabs.count {
                // The odd last tab gets a full-height column of its own at the
                // same width, rather than a half-height pane with a hole under it.
                if index + 1 < tabs.count {
                    columns.append(.split(
                        axis: .vertical,
                        children: [
                            .pane(id: tabs[index], share: 0.5),
                            .pane(id: tabs[index + 1], share: 0.5)
                        ],
                        share: columnShare
                    ))
                    index += 2
                } else {
                    columns.append(.pane(id: tabs[index], share: columnShare))
                    index += 1
                }
            }
            return .split(axis: .horizontal, children: columns, share: 1)
        }
    }

    private static func balanced(_ children: [Node], axis: Axis, share: Double) -> Node {
        let each = 1.0 / Double(children.count)
        return .split(axis: axis, children: children.map { child in
            var child = child
            child.share = each
            return child
        }, share: share)
    }

    // MARK: - Reading

    /// Every tab in the split, in layout order: left to right, then top to
    /// bottom. This is the order focus cycles in.
    var tabIDs: [Tab.ID] {
        var result: [Tab.ID] = []
        Self.walk(root) { result.append($0) }
        return result
    }

    var paneCount: Int { tabIDs.count }

    var isFull: Bool { paneCount >= Self.maximumPanes }

    func contains(_ id: Tab.ID) -> Bool { tabIDs.contains(id) }

    private static func walk(_ node: Node, _ body: (Tab.ID) -> Void) {
        switch node {
        case .pane(let id, _):
            body(id)
        case .split(_, let children, _):
            for child in children { walk(child, body) }
        }
    }

    /// The node at a path of child indices from the root, where the empty path
    /// is the root itself. Paths are how the view layer, which builds one
    /// `NSSplitView` per internal node, names the node a divider belongs to.
    func node(at path: [Int]) -> Node? {
        var current = root
        for index in path {
            guard case .split(_, let children, _) = current, children.indices.contains(index) else { return nil }
            current = children[index]
        }
        return current
    }

    // MARK: - Editing

    /// Adds a tab as a new pane of the root node, shrinking every existing
    /// sibling from `1/n` to `1/(n+1)` of what it had.
    ///
    /// Returns nil when the split is already full or already shows that tab, so
    /// the caller can say why nothing happened instead of silently no-op-ing.
    func adding(_ id: Tab.ID) -> SplitLayout? {
        guard !isFull, !contains(id) else { return nil }

        guard case .split(let axis, let children, let share) = root else {
            // A root that is a single pane cannot occur: a split always has two
            // or more. Kept total rather than trapping, because the only way
            // here would be a future construction path, and losing the layout is
            // better than losing the window.
            return nil
        }

        let scale = Double(children.count) / Double(children.count + 1)
        var scaled = children.map { child -> Node in
            var child = child
            child.share *= scale
            return child
        }
        scaled.append(.pane(id: id, share: 1.0 / Double(children.count + 1)))
        return SplitLayout(root: .split(axis: axis, children: scaled, share: share), grid: grid)
    }

    /// Rebuilds the tree for a different arrangement of the same tabs. Any
    /// hand-dragged proportions are deliberately discarded: the user asked for
    /// a named arrangement, and a grid built from four dragged sizes is not one.
    func relaid(as grid: Grid) -> SplitLayout {
        SplitLayout(root: Self.tree(for: tabIDs, grid: grid), grid: grid)
    }

    /// Removes a tab from the split.
    ///
    /// Returns nil when the tab is not in this split, `.dissolved` when taking
    /// it out would leave one pane, and otherwise a layout where the removed
    /// pane's share has been handed back to its siblings in proportion -- a
    /// rescale that is the difference between a split that closes up and one
    /// that leaves a hole.
    func removing(_ id: Tab.ID) -> Removal? {
        guard contains(id) else { return nil }
        guard paneCount > 2 else {
            return .dissolved(remaining: tabIDs.filter { $0 != id })
        }
        guard let root = Self.removing(id, from: root) else { return nil }
        return .resized(SplitLayout(root: root, grid: grid))
    }

    /// Replaces one tab with another, preserving the exact tree position, axis, and share.
    func replacing(_ oldID: Tab.ID, with newID: Tab.ID) -> SplitLayout {
        guard contains(oldID), !contains(newID) else { return self }
        let newRoot = Self.replacing(oldID, with: newID, in: root)
        return SplitLayout(root: newRoot, grid: grid)
    }

    private static func replacing(_ oldID: Tab.ID, with newID: Tab.ID, in node: Node) -> Node {
        switch node {
        case .pane(let id, let share):
            return id == oldID ? .pane(id: newID, share: share) : node
        case .split(let axis, let children, let share):
            let newChildren = children.map { replacing(oldID, with: newID, in: $0) }
            return .split(axis: axis, children: newChildren, share: share)
        }
    }

    /// Returns nil when the node itself was the pane being removed.
    private static func removing(_ id: Tab.ID, from node: Node) -> Node? {
        switch node {
        case .pane(let paneID, _):
            return paneID == id ? nil : node

        case .split(let axis, let children, let share):
            guard let index = children.firstIndex(where: { contains(id, in: $0) }) else { return node }

            var remaining = children
            if let replacement = removing(id, from: children[index]) {
                remaining[index] = replacement
            } else {
                let freed = children[index].share
                remaining.remove(at: index)
                // 1 - freed is never zero here: a node with one child does not
                // survive this function, so there is always a sibling left.
                let scale = 1 / max(1 - freed, .ulpOfOne)
                remaining = remaining.map { child in
                    var child = child
                    child.share *= scale
                    return child
                }
            }

            // A row or column with one child is not a split any more; collapsing
            // it is what stops a four-pane layout that lost two panes from
            // keeping a tree three levels deep for two tabs.
            if remaining.count == 1 {
                var only = remaining[0]
                only.share = share
                return only
            }
            return .split(axis: axis, children: remaining, share: share)
        }
    }

    private static func contains(_ id: Tab.ID, in node: Node) -> Bool {
        var found = false
        walk(node) { if $0 == id { found = true } }
        return found
    }

    /// Writes the children of one node back at new proportions.
    ///
    /// The view layer computes these from real divider positions after a drag
    /// rather than the model computing points, because `NSSplitView` has already
    /// done the pointer maths, the clamping and the cascade to the next
    /// sibling.
    func settingShares(at path: [Int], to shares: [Double]) -> SplitLayout {
        guard let root = Self.settingShares(in: root, path: path[...], to: shares) else { return self }
        return SplitLayout(root: root, grid: grid)
    }

    private static func settingShares(in node: Node, path: ArraySlice<Int>, to shares: [Double]) -> Node? {
        guard case .split(let axis, var children, let share) = node else { return nil }

        if let index = path.first {
            guard children.indices.contains(index) else { return nil }
            guard let updated = settingShares(in: children[index], path: path.dropFirst(), to: shares) else { return nil }
            children[index] = updated
            return .split(axis: axis, children: children, share: share)
        }

        guard shares.count == children.count else { return nil }
        let total = shares.reduce(0, +)
        guard total > 0 else { return nil }
        for index in children.indices {
            children[index].share = shares[index] / total
        }
        return .split(axis: axis, children: children, share: share)
    }

    // MARK: - Geometry and focus

    /// Each pane's rectangle in a unit square whose origin is its top-left, so
    /// `y` grows downward exactly as the panes are stacked on screen.
    ///
    /// The divider gaps are not modelled here: they are a fixed number of points
    /// and this is a proportional space. That is fine for what this is for --
    /// deciding which pane is above or beside which -- and wrong for drawing,
    /// which is `NSSplitView`'s job anyway.
    func unitFrames() -> [Tab.ID: CGRect] {
        var frames: [Tab.ID: CGRect] = [:]
        Self.collect(root, in: CGRect(x: 0, y: 0, width: 1, height: 1), into: &frames)
        return frames
    }

    private static func collect(_ node: Node, in rect: CGRect, into frames: inout [Tab.ID: CGRect]) {
        switch node {
        case .pane(let id, _):
            frames[id] = rect
        case .split(let axis, let children, _):
            var offset = 0.0
            for child in children {
                let childRect: CGRect
                switch axis {
                case .horizontal:
                    childRect = CGRect(
                        x: rect.minX + offset * rect.width,
                        y: rect.minY,
                        width: child.share * rect.width,
                        height: rect.height
                    )
                case .vertical:
                    childRect = CGRect(
                        x: rect.minX,
                        y: rect.minY + offset * rect.height,
                        width: rect.width,
                        height: child.share * rect.height
                    )
                }
                collect(child, in: childRect, into: &frames)
                offset += child.share
            }
        }
    }

    /// The next pane in layout order, wrapping. This is what a "cycle panes"
    /// command moves through, and it is deliberately not geometric: cycling
    /// must reach every pane exactly once, which a directional walk cannot
    /// promise in an L-shaped three-pane layout.
    func pane(after id: Tab.ID) -> Tab.ID? {
        let ids = tabIDs
        guard let index = ids.firstIndex(of: id) else { return nil }
        return ids[(index + 1) % ids.count]
    }

    func pane(before id: Tab.ID) -> Tab.ID? {
        let ids = tabIDs
        guard let index = ids.firstIndex(of: id) else { return nil }
        return ids[(index + ids.count - 1) % ids.count]
    }

    /// The pane a directional focus move lands on, or nil at the edge.
    ///
    /// Arrow-key focus does not wrap: running out of panes to the right should
    /// leave focus where it is rather than jumping to the far edge, which is how
    /// every other pane-based macOS UI behaves and the only way the gesture is
    /// reversible.
    func pane(from id: Tab.ID, moving direction: Direction) -> Tab.ID? {
        let frames = unitFrames()
        guard let origin = frames[id] else { return nil }

        // A generous epsilon: two panes that share a divider have coordinates
        // that agree to within floating-point noise, not exactly.
        let epsilon = 1e-6

        let candidates = frames.filter { candidate in
            guard candidate.key != id else { return false }
            let rect = candidate.value
            switch direction {
            case .left:
                return rect.maxX <= origin.minX + epsilon && rect.maxY > origin.minY + epsilon && rect.minY < origin.maxY - epsilon
            case .right:
                return rect.minX >= origin.maxX - epsilon && rect.maxY > origin.minY + epsilon && rect.minY < origin.maxY - epsilon
            case .up:
                return rect.maxY <= origin.minY + epsilon && rect.maxX > origin.minX + epsilon && rect.minX < origin.maxX - epsilon
            case .down:
                return rect.minY >= origin.maxY - epsilon && rect.maxX > origin.minX + epsilon && rect.minX < origin.maxX - epsilon
            }
        }

        // Nearest along the direction of travel first, then nearest across it,
        // so a move right out of a tall pane lands on the neighbour whose centre
        // is closest rather than on whichever one the dictionary happened to
        // enumerate first.
        return candidates.min { lhs, rhs in
            let lhsKey = distance(from: origin, to: lhs.value, direction: direction)
            let rhsKey = distance(from: origin, to: rhs.value, direction: direction)
            if lhsKey.along != rhsKey.along { return lhsKey.along < rhsKey.along }
            return lhsKey.across < rhsKey.across
        }?.key
    }

    private func distance(
        from origin: CGRect,
        to rect: CGRect,
        direction: Direction
    ) -> (along: Double, across: Double) {
        switch direction {
        case .left:
            return (origin.minX - rect.maxX, abs(rect.midY - origin.midY))
        case .right:
            return (rect.minX - origin.maxX, abs(rect.midY - origin.midY))
        case .up:
            return (origin.minY - rect.maxY, abs(rect.midX - origin.midX))
        case .down:
            return (rect.minY - origin.maxY, abs(rect.midX - origin.midX))
        }
    }
}
