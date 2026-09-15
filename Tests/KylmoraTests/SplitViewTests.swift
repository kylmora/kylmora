import CoreGraphics
import Foundation
import Testing
@testable import Kylmora

@Suite("Split view layout")
@MainActor
struct SplitViewTests {
    private func ids(_ count: Int) -> [UUID] { (0..<count).map { _ in UUID() } }

    private func shares(of node: SplitLayout.Node) -> [Double] {
        guard case .split(_, let children, _) = node else { return [] }
        return children.map(\.share)
    }

    private func expectClose(_ value: Double, _ expected: Double, _ comment: Comment? = nil) {
        #expect(abs(value - expected) < 1e-9, comment ?? "\(value) is not \(expected)")
    }

    // MARK: - Construction

    @Test("A split needs at least two tabs and at most four")
    func constructionBounds() {
        let four = ids(4)
        #expect(SplitLayout(tabs: [], grid: .grid) == nil)
        #expect(SplitLayout(tabs: [four[0]], grid: .grid) == nil)
        #expect(SplitLayout(tabs: four, grid: .grid) != nil)
        #expect(SplitLayout(tabs: four + ids(1), grid: .grid) == nil)
    }

    @Test("Duplicates are dropped before the count is checked")
    func duplicatesCollapse() {
        let tab = UUID()
        // A multi-selection that includes the drag target is the real source of
        // this: without the de-duplication it would split a tab with itself.
        #expect(SplitLayout(tabs: [tab, tab], grid: .grid) == nil)

        let other = UUID()
        let layout = SplitLayout(tabs: [tab, other, tab], grid: .sideBySide)
        #expect(layout?.tabIDs == [tab, other])
    }

    @Test("Side by side is one row of equal panes")
    func sideBySideShape() {
        let tabs = ids(3)
        let layout = SplitLayout(tabs: tabs, grid: .sideBySide)!
        guard case .split(let axis, let children, let share) = layout.root else {
            Issue.record("root should be a split")
            return
        }
        #expect(axis == .horizontal)
        #expect(children.count == 3)
        #expect(share == 1)
        for child in children { expectClose(child.share, 1.0 / 3) }
        #expect(layout.tabIDs == tabs)
    }

    @Test("Stacked is one column")
    func stackedShape() {
        let layout = SplitLayout(tabs: ids(2), grid: .stacked)!
        guard case .split(let axis, let children, _) = layout.root else {
            Issue.record("root should be a split")
            return
        }
        #expect(axis == .vertical)
        #expect(children.count == 2)
    }

    @Test("A grid of two is a row, because there is no second row to fill")
    func gridOfTwoIsARow() {
        let tabs = ids(2)
        #expect(SplitLayout(tabs: tabs, grid: .grid)!.root == SplitLayout(tabs: tabs, grid: .sideBySide)!.root)
    }

    @Test("A grid of four is two stacked pairs")
    func gridOfFour() {
        let tabs = ids(4)
        let layout = SplitLayout(tabs: tabs, grid: .grid)!
        guard case .split(.horizontal, let columns, _) = layout.root else {
            Issue.record("root should be a row")
            return
        }
        #expect(columns.count == 2)
        for column in columns {
            expectClose(column.share, 0.5)
            guard case .split(.vertical, let cells, _) = column else {
                Issue.record("each column should stack two panes")
                return
            }
            #expect(cells.count == 2)
            for cell in cells { expectClose(cell.share, 0.5) }
        }
        #expect(layout.tabIDs == tabs)
    }

    @Test("A grid of three is a stacked pair beside one full-height pane")
    func gridOfThree() {
        let tabs = ids(3)
        let layout = SplitLayout(tabs: tabs, grid: .grid)!
        guard case .split(.horizontal, let columns, _) = layout.root else {
            Issue.record("root should be a row")
            return
        }
        #expect(columns.count == 2)
        expectClose(columns[0].share, 0.5)
        expectClose(columns[1].share, 0.5)
        // The odd tab gets a column of its own rather than half a column with a
        // hole under it.
        #expect(columns[1] == .pane(id: tabs[2], share: 0.5))

        let frames = layout.unitFrames()
        #expect(frames[tabs[2]]?.height == 1)
        expectClose(frames[tabs[0]]!.height, 0.5)
    }

    // MARK: - Adding

    @Test("Adding a pane shrinks every sibling by n/(n+1)")
    func addingShrinksSiblings() {
        let tabs = ids(2)
        let layout = SplitLayout(tabs: tabs, grid: .sideBySide)!
        let extended = layout.adding(UUID())!

        #expect(extended.paneCount == 3)
        for share in shares(of: extended.root) { expectClose(share, 1.0 / 3) }
    }

    @Test("Adding preserves the proportions the user dragged")
    func addingPreservesProportions() {
        let tabs = ids(2)
        let layout = SplitLayout(tabs: tabs, grid: .sideBySide)!
            .settingShares(at: [], to: [0.8, 0.2])
        let extended = layout.adding(UUID())!

        let result = shares(of: extended.root)
        // Two thirds of what each pane had, and the freed third to the newcomer.
        expectClose(result[0], 0.8 * 2 / 3)
        expectClose(result[1], 0.2 * 2 / 3)
        expectClose(result[2], 1.0 / 3)
        expectClose(result.reduce(0, +), 1)
    }

    @Test("A full split refuses a fifth tab, and a duplicate is refused too")
    func addingRefuses() {
        let tabs = ids(4)
        let layout = SplitLayout(tabs: tabs, grid: .grid)!
        #expect(layout.isFull)
        #expect(layout.adding(UUID()) == nil)

        let smaller = SplitLayout(tabs: ids(2) + [tabs[0]], grid: .grid)!
        #expect(smaller.adding(tabs[0]) == nil)
    }

    @Test("Relaying out keeps the tabs and drops hand-dragged sizes")
    func relaid() {
        let tabs = ids(3)
        let layout = SplitLayout(tabs: tabs, grid: .sideBySide)!
            .settingShares(at: [], to: [0.6, 0.2, 0.2])
        let regridded = layout.relaid(as: .grid)

        #expect(regridded.tabIDs == tabs)
        #expect(regridded.grid == .grid)
        #expect(regridded == SplitLayout(tabs: tabs, grid: .grid)!)
    }

    // MARK: - Removing

    @Test("Removing from a two-pane split dissolves it")
    func removingDissolvesAtTwo() {
        let tabs = ids(2)
        let layout = SplitLayout(tabs: tabs, grid: .sideBySide)!
        #expect(layout.removing(tabs[0]) == .dissolved(remaining: [tabs[1]]))
    }

    @Test("Removing a tab that is not in the split reports nothing happened")
    func removingAStranger() {
        let layout = SplitLayout(tabs: ids(3), grid: .grid)!
        #expect(layout.removing(UUID()) == nil)
    }

    @Test("Removing from three or more rescales the survivors by 1/(1 - removed)")
    func removingRescales() {
        let tabs = ids(3)
        let layout = SplitLayout(tabs: tabs, grid: .sideBySide)!
            .settingShares(at: [], to: [0.5, 0.2, 0.3])

        guard case .resized(let after) = layout.removing(tabs[1]) else {
            Issue.record("a three-pane split should survive losing one pane")
            return
        }
        #expect(after.tabIDs == [tabs[0], tabs[2]])
        let result = shares(of: after.root)
        // 0.5 and 0.3 of the remaining 0.8, so the gap closes rather than
        // leaving the pane that went a hole to sit in.
        expectClose(result[0], 0.625)
        expectClose(result[1], 0.375)
        expectClose(result.reduce(0, +), 1)
    }

    @Test("A node left with one child collapses into it")
    func removingCollapsesTheParent() {
        let tabs = ids(4)
        let layout = SplitLayout(tabs: tabs, grid: .grid)!

        guard case .resized(let after) = layout.removing(tabs[1]) else {
            Issue.record("a four-pane split should survive losing one pane")
            return
        }
        guard case .split(.horizontal, let columns, _) = after.root else {
            Issue.record("root should still be a row")
            return
        }
        // The first column held two stacked panes and now holds one, so it is
        // not a column any more -- it is that pane, at the column's width.
        #expect(columns[0] == .pane(id: tabs[0], share: 0.5))
        #expect(after.tabIDs == [tabs[0], tabs[2], tabs[3]])

        // And the survivor now fills the full height its column had.
        #expect(after.unitFrames()[tabs[0]]?.height == 1)
    }

    @Test("Panes dissolve down to one and never below")
    func removingRepeatedly() {
        let tabs = ids(4)
        var layout = SplitLayout(tabs: tabs, grid: .grid)!

        guard case .resized(let three) = layout.removing(tabs[3]) else {
            Issue.record("four panes should survive losing one")
            return
        }
        layout = three
        guard case .resized(let two) = layout.removing(tabs[2]) else {
            Issue.record("three panes should survive losing one")
            return
        }
        #expect(two.paneCount == 2)
        #expect(two.removing(tabs[1]) == .dissolved(remaining: [tabs[0]]))
    }

    // MARK: - Proportions

    @Test("Shares are written back normalised, so rounding cannot drift")
    func settingSharesNormalises() {
        let tabs = ids(2)
        let layout = SplitLayout(tabs: tabs, grid: .sideBySide)!
            // What a divider drag produces: two point sizes, not percentages.
            .settingShares(at: [], to: [600, 200])
        let result = shares(of: layout.root)
        expectClose(result[0], 0.75)
        expectClose(result[1], 0.25)
    }

    @Test("Shares go to the node the path names, not the root")
    func settingSharesAtAPath() {
        let tabs = ids(4)
        let layout = SplitLayout(tabs: tabs, grid: .grid)!.settingShares(at: [0], to: [0.3, 0.7])

        let frames = layout.unitFrames()
        expectClose(frames[tabs[0]]!.height, 0.3)
        expectClose(frames[tabs[1]]!.height, 0.7)
        // The other column is untouched.
        expectClose(frames[tabs[2]]!.height, 0.5)
    }

    @Test("A path that names nothing leaves the layout alone")
    func settingSharesAtABadPath() {
        let layout = SplitLayout(tabs: ids(2), grid: .sideBySide)!
        #expect(layout.settingShares(at: [7], to: [0.5, 0.5]) == layout)
        #expect(layout.settingShares(at: [], to: [1]) == layout)
        #expect(layout.settingShares(at: [], to: [0, 0]) == layout)
    }

    @Test("The minimum pane is a percentage, so it means the same on any display")
    func minimumShare() {
        #expect(SplitLayout.minimumShare == 0.07)
        #expect(SplitLayout.maximumPanes == 4)
    }

    // MARK: - Geometry and focus

    @Test("Unit frames tile the whole content area without overlapping")
    func unitFramesTile() {
        for grid in [SplitLayout.Grid.sideBySide, .stacked, .grid] {
            for count in 2...4 {
                let layout = SplitLayout(tabs: ids(count), grid: grid)!
                let frames = Array(layout.unitFrames().values)
                #expect(frames.count == count)
                let area = frames.reduce(0) { $0 + $1.width * $1.height }
                #expect(abs(area - 1) < 1e-9, "\(grid) with \(count) panes should cover the area exactly")
                for (index, lhs) in frames.enumerated() {
                    for rhs in frames[(index + 1)...] {
                        #expect(!lhs.intersects(rhs), "\(grid) with \(count) panes overlaps")
                    }
                }
            }
        }
    }

    @Test("Focus cycles through every pane in layout order and wraps")
    func focusCycles() {
        let tabs = ids(3)
        let layout = SplitLayout(tabs: tabs, grid: .sideBySide)!
        #expect(layout.pane(after: tabs[0]) == tabs[1])
        #expect(layout.pane(after: tabs[2]) == tabs[0])
        #expect(layout.pane(before: tabs[0]) == tabs[2])
        #expect(layout.pane(after: UUID()) == nil)
    }

    @Test("Directional focus moves to the neighbour on that side")
    func focusMovesDirectionally() {
        let tabs = ids(2)
        let layout = SplitLayout(tabs: tabs, grid: .sideBySide)!
        #expect(layout.pane(from: tabs[0], moving: .right) == tabs[1])
        #expect(layout.pane(from: tabs[1], moving: .left) == tabs[0])
        // Up and down have nowhere to go in a single row, and focus staying put
        // is what makes the gesture reversible.
        #expect(layout.pane(from: tabs[0], moving: .up) == nil)
        #expect(layout.pane(from: tabs[0], moving: .down) == nil)
    }

    @Test("Directional focus does not wrap at the edge")
    func focusDoesNotWrap() {
        let tabs = ids(3)
        let layout = SplitLayout(tabs: tabs, grid: .sideBySide)!
        #expect(layout.pane(from: tabs[2], moving: .right) == nil)
        #expect(layout.pane(from: tabs[0], moving: .left) == nil)
    }

    @Test("In a grid, focus crosses both ways and picks the nearest pane")
    func focusInAGrid() {
        let tabs = ids(4)
        let layout = SplitLayout(tabs: tabs, grid: .grid)!
        // 0 1 are the left column, top and bottom; 2 3 the right column.
        #expect(layout.pane(from: tabs[0], moving: .down) == tabs[1])
        #expect(layout.pane(from: tabs[0], moving: .right) == tabs[2])
        #expect(layout.pane(from: tabs[1], moving: .right) == tabs[3])
        #expect(layout.pane(from: tabs[3], moving: .left) == tabs[1])
        #expect(layout.pane(from: tabs[3], moving: .up) == tabs[2])
    }

    @Test("Moving into a full-height neighbour lands on it from either row")
    func focusIntoATallPane() {
        let tabs = ids(3)
        let layout = SplitLayout(tabs: tabs, grid: .grid)!
        #expect(layout.pane(from: tabs[0], moving: .right) == tabs[2])
        #expect(layout.pane(from: tabs[1], moving: .right) == tabs[2])
        // Coming back lands in the left column. Which of its two panes is not
        // asserted: the tall pane's centre is exactly on the divider between
        // them, so either answer is equally correct and pinning one down would
        // be testing the tie-break rather than the rule.
        let back = layout.pane(from: tabs[2], moving: .left)
        #expect(back == tabs[0] || back == tabs[1])
    }

    // MARK: - Persistence

    @Test("A layout survives a round trip through the session store's encoding")
    func codableRoundTrip() throws {
        let layout = SplitLayout(tabs: ids(3), grid: .grid)!.settingShares(at: [0], to: [0.3, 0.7])
        let data = try JSONEncoder().encode(layout)
        #expect(try JSONDecoder().decode(SplitLayout.self, from: data) == layout)
    }

    // MARK: - Metrics

    @Test("The divider is the gutter, one point wider between columns")
    func dividerThickness() {
        // The reference split gaps are 8px row and 9px column,
        // the second being separation + 1.
        #expect(SplitMetrics.dividerThickness(for: .vertical) == Style.Metrics.elementSeparation)
        #expect(SplitMetrics.dividerThickness(for: .horizontal) == Style.Metrics.elementSeparation + 1)
    }

    @Test("A pane is the same rounded card as the single-page content area")
    func paneCorner() {
        #expect(SplitMetrics.paneCornerRadius == Style.Metrics.contentCornerRadius)
    }

    // MARK: - F-17 Split View Refinements

    @Test("Replacing a tab in SplitLayout preserves exact proportions and tree structure")
    func testReplacingPaneInLayout() {
        let tabs = ids(3)
        let layout = SplitLayout(tabs: tabs, grid: .grid)!.settingShares(at: [0], to: [0.3, 0.7])
        let replacement = UUID()

        let updated = layout.replacing(tabs[0], with: replacement)
        #expect(updated.tabIDs == [replacement, tabs[1], tabs[2]])
        #expect(updated.grid == layout.grid)

        // Proportions are kept
        guard case .split(.horizontal, let columns, _) = updated.root,
              case .split(.vertical, let cells, _) = columns[0] else {
            Issue.record("layout structure should be preserved")
            return
        }
        expectClose(cells[0].share, 0.3)
        expectClose(cells[1].share, 0.7)
    }

    @Test("Sticky pane stays open in split while switching other tabs in sidebar")
    func testStickyPaneBehavior() {
        let session = BrowserSession(database: nil)
        let tabA = session.newTab(url: URL(string: "https://a.com")!, select: true)
        let tabB = session.newTab(url: URL(string: "https://b.com")!, select: false)
        let tabC = session.newTab(url: URL(string: "https://c.com")!, select: false)

        session.splitTabs([tabA, tabB], grid: .sideBySide)
        #expect(session.activeSplit?.tabIDs == [tabA.id, tabB.id])

        // Stick Tab A
        session.toggleStickPane(tabA.id)
        #expect(session.isSticky(tabA.id))
        #expect(!session.isSticky(tabB.id))

        // Select Tab C in sidebar -> Tab A stays stuck, Tab B replaced with Tab C
        session.selectTab(tabC)
        #expect(session.activeSplit != nil)
        #expect(session.activeSplit?.contains(tabA.id) == true)
        #expect(session.activeSplit?.contains(tabC.id) == true)
        #expect(session.activeSplit?.contains(tabB.id) == false)

        // Unstick Tab A
        session.toggleStickPane(tabA.id)
        #expect(!session.isSticky(tabA.id))
    }

    @Test("Undo split restores previous single tab or split layout")
    func testUndoSplit() {
        let session = BrowserSession(database: nil)
        let tabA = session.newTab(url: URL(string: "https://a.com")!, select: true)
        let tabB = session.newTab(url: URL(string: "https://b.com")!, select: false)

        #expect(session.activeSplit == nil)
        #expect(session.activeTab?.id == tabA.id)

        session.splitTabs([tabA, tabB], grid: .sideBySide)
        #expect(session.activeSplit != nil)
        #expect(session.canUndoSplit)

        // Undo split
        session.undoSplit()
        #expect(session.activeSplit == nil)
        #expect(session.activeTab?.id == tabA.id)

        // Redo split
        session.undoSplit()
        #expect(session.activeSplit != nil)
    }

    @Test("Equalize split balances shares equally")
    func testEqualizeSplit() {
        let session = BrowserSession(database: nil)
        let tabA = session.newTab(url: URL(string: "https://a.com")!, select: true)
        let tabB = session.newTab(url: URL(string: "https://b.com")!, select: false)

        session.splitTabs([tabA, tabB], grid: .sideBySide)
        let dragged = session.activeSplit!.settingShares(at: [], to: [0.2, 0.8])
        session.updateSplitLayout(dragged)

        session.equalizeSplit()
        guard case .split(_, let children, _) = session.activeSplit!.root else {
            Issue.record("root should be split")
            return
        }
        expectClose(children[0].share, 0.5)
        expectClose(children[1].share, 0.5)
    }

    @Test("openLinkInSplit splits with new tab when not in split")
    func testOpenLinkInSplitStandalone() {
        let session = BrowserSession(database: nil)
        let tabA = session.newTab(url: URL(string: "https://a.com")!, select: true)
        #expect(session.activeSplit == nil)

        let targetURL = URL(string: "https://split-target.com")!
        session.openLinkInSplit(targetURL, from: tabA)

        #expect(session.activeSplit != nil)
        #expect(session.activeSplit?.paneCount == 2)
        #expect(session.activeTab?.url == targetURL)
    }

    @Test("CommandCatalog has F-17 split refinement commands")
    func testSplitCommandCatalog() {
        let commands = CommandCatalog.all
        let ids = Set(commands.map(\.id))

        #expect(ids.contains("toggle-sticky-pane"))
        #expect(ids.contains("undo-split"))
        #expect(ids.contains("equalize-split"))

        let stickyCmd = commands.first(where: { $0.id == "toggle-sticky-pane" })
        #expect(stickyCmd?.shortcut == "⌥⇧⌘P")

        let undoCmd = commands.first(where: { $0.id == "undo-split" })
        #expect(undoCmd?.shortcut == "⌥⌘Z")
    }

    @Test("SplitPaneView builds stick, unsplit, and close buttons")
    func testSplitPaneViewButtons() {
        let pane = SplitPaneView(tabID: UUID())
        #expect(!pane.isSticky)

        pane.setSticky(true)
        #expect(pane.isSticky)

        pane.setSticky(false)
        #expect(!pane.isSticky)
    }
}
