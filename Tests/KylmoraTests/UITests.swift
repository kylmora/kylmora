import AppKit
import Testing
@testable import Kylmora

// These views are plain AppKit with no session behind them, which is the whole
// point of the UI layer: everything below is exercised with values, not with
// a running browser.

@Suite("Sidebar chrome metrics")
@MainActor
struct StyleTests {
    @Test("The selection pill fits inside the row it is drawn in")
    func pillFitsRow() {
        #expect(Style.Metrics.rowPillHeight < Style.Metrics.rowHeight)
        // An odd difference would put the pill half a point off centre.
        let slack = Style.Metrics.rowHeight - Style.Metrics.rowPillHeight
        #expect(slack > 0)
    }

    @Test("A tab row's favicon slot matches the one the existing sidebar uses")
    func faviconSlotsAgree() {
        #expect(Style.Metrics.faviconSide == FaviconImageView.side)
    }

    @Test("The corner radius never exceeds half the shape it rounds")
    func radiiAreDrawable() {
        #expect(Style.Metrics.rowCornerRadius <= Style.Metrics.rowPillHeight / 2)
        #expect(Style.Metrics.tileCornerRadius <= Style.Metrics.tileHeight / 2)
    }

    @Test("The traffic lights are clear of everything else on the titlebar row")
    func trafficLightsHaveRoom() {
        // Measured centre of the green button plus its radius, in points.
        #expect(Style.Metrics.trafficLightWidth > 71)
        #expect(Style.Metrics.trafficLightWidth < Style.Metrics.sidebarWidth / 2)
    }
}

@Suite("Breadcrumb")
@MainActor
struct BreadcrumbTests {
    @Test("A site and a title are joined; the address stays reachable")
    func showsSiteAndTitle() {
        let view = BreadcrumbView()
        view.show(site: "Example", title: "Welcome", address: "https://example.com/")
        #expect(view.toolTip == "https://example.com/")
        #expect(view.accessibilityValue() as? String == "https://example.com/")
        #expect(view.isEnabled)
    }

    @Test("A missing site name takes the separator with it")
    func omitsSeparatorWithoutSite() {
        let view = BreadcrumbView()
        view.show(site: nil, title: "Welcome", address: "https://example.com/")
        let text = (view.subviews.compactMap { $0 as? NSTextField }.first?.stringValue) ?? ""
        #expect(text == "Welcome")
        #expect(!text.contains("/"))
    }

    @Test("With no address there is nothing to disclose, so the control is inert")
    func inertWithoutAddress() {
        let view = BreadcrumbView()
        var activated = false
        view.onActivate = { activated = true }
        view.show(site: nil, title: "New Tab", address: nil)
        #expect(!view.isEnabled)
        #expect(view.accessibilityPerformPress() == false)
        #expect(!activated)
    }

    @Test("Activating the breadcrumb is what reveals the real address")
    func activatesWhenAddressed() {
        let view = BreadcrumbView()
        var activated = false
        view.onActivate = { activated = true }
        view.show(site: "Example", title: "Welcome", address: "https://example.com/")
        #expect(view.accessibilityPerformPress())
        #expect(activated)
    }
}

@Suite("Content top bar")
@MainActor
struct ContentTopBarTests {
    @Test("Reload becomes stop while loading, in symbol and in label together")
    func reloadBecomesStop() {
        let bar = ContentTopBar()
        bar.update(canGoBack: false, canGoForward: false, isLoading: true, hasPage: true)
        #expect(bar.reloadButton.accessibilityLabel() == "Stop Loading")
        #expect(bar.reloadButton.toolTip == "Stop Loading")

        bar.update(canGoBack: false, canGoForward: false, isLoading: false, hasPage: true)
        #expect(bar.reloadButton.accessibilityLabel() == "Reload")
    }

    @Test("History buttons follow the page, not the pointer")
    func historyButtonsFollowState() {
        let bar = ContentTopBar()
        bar.update(canGoBack: true, canGoForward: false, isLoading: false, hasPage: true)
        #expect(bar.backButton.isEnabled)
        #expect(!bar.forwardButton.isEnabled)
    }

    @Test("With no page, nothing on the bar pretends to be actionable")
    func disabledWithoutPage() {
        let bar = ContentTopBar()
        bar.update(canGoBack: false, canGoForward: false, isLoading: false, hasPage: false)
        #expect(!bar.reloadButton.isEnabled)
        #expect(!bar.backButton.isEnabled)
    }

    @Test("Trailing actions are the caller's, and an empty set is a valid one")
    func trailingActionsAreReplaceable() {
        let bar = ContentTopBar()
        var shared = 0
        bar.setActions([
            TopBarAction(symbolName: "square.and.arrow.up", label: "Share") { shared += 1 }
        ])
        let share = UITestSupport.buttons(in: bar).first { $0.accessibilityLabel() == "Share" }
        #expect(share != nil)
        // Invoked directly rather than through `sendAction`, which routes via
        // `NSApplication`. Tests run in parallel, so whether the shared
        // application exists yet depends on which suite got there first, and a
        // test that passes or fails on that ordering is worse than no test.
        if let share, let target = share.target, let action = share.action {
            _ = target.perform(action, with: share)
        }
        #expect(shared == 1)

        bar.setActions([])
        #expect(UITestSupport.buttons(in: bar).allSatisfy { $0.accessibilityLabel() != "Share" })
    }

    @Test("The actions hold the trailing edge and the breadcrumb takes the slack")
    func actionsAreTrailingAligned() {
        let bar = ContentTopBar()
        bar.setActions([
            TopBarAction(symbolName: "square.and.arrow.up", label: "Share") {}
        ])
        let narrow = UITestSupport.laidOut(bar, width: 600)
        let wide = UITestSupport.laidOut(bar, width: 1400)

        // The breadcrumb starts in the same place at both widths: the extra
        // width goes to the gap after it, not in front of it.
        #expect(narrow.breadcrumb.minX == wide.breadcrumb.minX)
        // And the action sits against the trailing edge at both.
        #expect(abs(600 - narrow.share.maxX - Style.Metrics.topBarTrailingInset) < 1)
        #expect(abs(1400 - wide.share.maxX - Style.Metrics.topBarTrailingInset) < 1)
        // Which is only meaningful if the two are actually far apart.
        #expect(wide.share.minX - wide.breadcrumb.maxX > 400)
    }
}

@Suite("Pinned tiles")
@MainActor
struct PinnedTilesTests {
    /// The dashed slot is the only subview announced as "Pin a Shortcut".
    private func emptySlot(in strip: PinnedTilesView) -> NSView? {
        UITestSupport.descendants(of: strip).first { $0.accessibilityLabel() == "Pin a Shortcut" }
    }

    @Test("The dashed slot is shown when nothing is pinned")
    func emptySlotShownWhenEmpty() {
        let strip = PinnedTilesView()
        strip.show([])
        #expect(strip.tileCount == 0)
        #expect(emptySlot(in: strip)?.isHidden == false)
    }

    @Test("The dashed slot disappears once the first pin is added")
    func emptySlotHiddenOncePinned() {
        let strip = PinnedTilesView()
        strip.show([PinnedTile(id: "a", title: "Mail")])
        #expect(strip.tileCount == 1)
        // The slot view still exists, but hidden it neither draws nor takes a
        // grid cell, so there is no trailing blank square after the tiles.
        #expect(emptySlot(in: strip)?.isHidden == true)
    }

    @Test("Removing the last pin brings the dashed slot back")
    func emptySlotReturnsWhenEmptied() {
        let strip = PinnedTilesView()
        strip.show([PinnedTile(id: "a", title: "Mail")])
        strip.show([])
        #expect(emptySlot(in: strip)?.isHidden == false)
    }

    @Test("Tiles are shown in order")
    func tilesInOrder() {
        let strip = PinnedTilesView()
        strip.show([
            PinnedTile(id: "a", title: "Mail"),
            PinnedTile(id: "b", title: "Calendar")
        ])
        #expect(strip.tileCount == 2)
        let labels = UITestSupport.accessibilityLabels(in: strip)
        #expect(labels.firstIndex(of: "Mail")! < labels.firstIndex(of: "Calendar")!)
    }

    @Test("Re-showing replaces the tiles instead of stacking new ones on top")
    func showReplaces() {
        let strip = PinnedTilesView()
        strip.show([PinnedTile(id: "a", title: "Mail")])
        strip.show([PinnedTile(id: "b", title: "Calendar")])
        #expect(strip.tileCount == 1)
        let labels = UITestSupport.accessibilityLabels(in: strip)
        #expect(!labels.contains("Mail"))
    }

    @Test("A pinned site's icon comes from the favicon layer, not a second fetcher")
    func tilesUseTheFaviconView() {
        let strip = PinnedTilesView()
        strip.show(
            // .invalid is reserved and resolves nowhere, so the fetch this
            // starts dies in DNS rather than reaching a real host from a test.
            [PinnedTile(id: "a", title: "Mail", url: URL(string: "https://mail.example.invalid/"))],
            isPrivate: true
        )
        let icons = UITestSupport.descendants(of: strip).compactMap { $0 as? FaviconImageView }
        #expect(icons.count == 1)
        #expect(Style.Metrics.tileIconSide == FaviconImageView.side)
    }

    @Test("A pin with no fetchable address still renders, as a placeholder")
    func tileWithoutURLStillRenders() {
        let strip = PinnedTilesView()
        strip.show([PinnedTile(id: "a", title: "Mail")])
        #expect(strip.tileCount == 1)
        #expect(UITestSupport.accessibilityLabels(in: strip).contains("Mail"))
    }
}

@Suite("Tab group header")
@MainActor
struct TabGroupHeaderTests {
    @Test("Pressing the header flips it and reports the state it moved to")
    func togglesAndReports() {
        let header = TabGroupHeaderView()
        var reported: [Bool] = []
        header.onToggle = { reported.append($0) }
        header.show(emoji: "\u{1F44B}", name: "Welcome", isExpanded: true)

        #expect(header.accessibilityPerformPress())
        #expect(!header.isExpanded)
        #expect(reported == [false])

        #expect(header.accessibilityPerformPress())
        #expect(header.isExpanded)
        #expect(reported == [false, true])
    }

    @Test("The header is announced by its name, not by its emoji")
    func announcedByName() {
        let header = TabGroupHeaderView()
        header.show(emoji: "\u{1F44B}", name: "Welcome", isExpanded: true)
        #expect(header.accessibilityLabel() == "Welcome")
        #expect(header.accessibilityValue() as? Bool == true)
    }

    @Test("A folder's children start exactly one indent step in from its header")
    func childrenNestUnderHeader() {
        let header = TabGroupHeaderView()
        header.show(emoji: "\u{1F44B}", name: "Welcome", isExpanded: true)
        let headerHost = UITestSupport.host(header, width: 280, height: Style.Metrics.groupHeaderHeight)
        // The label's frame is wider than the glyph it draws -- Auto Layout
        // positions a text field by its alignment rect -- so the comparison has
        // to be against that rect, which is what the eye actually sees.
        let emoji = UITestSupport.textFields(in: header).first { !$0.stringValue.isEmpty }
        let emojiX = emoji.map { label -> CGFloat in
            let inHost = label.convert(label.bounds, to: headerHost).minX
            let bearing = label.alignmentRect(forFrame: label.bounds).minX - label.bounds.minX
            return inHost + bearing
        } ?? 0

        // The header sits at the folder's own indent and the row one level in,
        // so the difference between their content is one step and nothing else.
        let row = TabRowView()
        row.indentation = FolderTree.indentPerLevel
        row.frame = NSRect(x: 0, y: 0, width: 280, height: Style.Metrics.rowHeight)
        row.layoutSubtreeIfNeeded()

        #expect(row.favicon.frame.minX - emojiX == FolderTree.indentPerLevel)
    }

    @Test("The header spans the whole sidebar, so its hover plate matches a row")
    func headerFillsWidth() {
        let header = TabGroupHeaderView()
        header.show(emoji: nil, name: "Research", isExpanded: true)
        let host = UITestSupport.host(header, width: 280, height: Style.Metrics.groupHeaderHeight)
        #expect(header.frame.width == host.frame.width)
    }

    @Test("A sidebar too narrow for the name still draws the header")
    func survivesNarrowSidebar() {
        // The sidebar's own cell: a plain autoresized container of a fixed
        // width, with the header pinned inside it. A header that keeps its
        // height in a hand-built host can still lose it here, which is exactly
        // how it vanished from a narrow sidebar.
        let header = TabGroupHeaderView()
        header.show(emoji: "\u{1F44B}", name: "Welcome to Kylmora", isExpanded: true)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 150, height: Style.Metrics.rowHeight))
        container.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(
                equalTo: container.leadingAnchor,
                constant: Style.Metrics.sidebarInset
            ),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            header.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        container.layoutSubtreeIfNeeded()

        #expect(header.frame.height == Style.Metrics.groupHeaderHeight)
        #expect(header.frame.width == container.frame.width - Style.Metrics.sidebarInset)
    }

    @Test("A group with no emoji leaves no gap where one would have been")
    func hidesEmptyEmoji() {
        let header = TabGroupHeaderView()
        header.show(emoji: nil, name: "Research", isExpanded: true)
        let emoji = UITestSupport.textFields(in: header).first { $0.stringValue.isEmpty }
        #expect(emoji?.isHidden == true)
    }
}

@Suite("Tab row")
@MainActor
struct TabRowTests {
    @Test("A row carries no page thumbnail")
    func noThumbnail() {
        // Some browsers show a page preview on the selected row's trailing
        // edge. That was built here and removed at the user's request, so the
        // only images in a row are its favicon and the badge icons -- and the
        // badge icons are hidden unless the row has something to report.
        let row = TabRowView()
        row.configure(TabRowContent(title: "Start", address: "https://example.com/"))
        row.isSelected = true
        let others = UITestSupport.imageViews(in: row)
            .filter { !($0 is FaviconImageView) && !$0.isHidden }
        #expect(others.isEmpty)
    }

    @Test("A sleeping row shows a moon, and an ordinary one shows nothing")
    func sleepingRowShowsAMoon() {
        // The dimmed title says "suspended" only to someone comparing it with
        // the row above. The moon says it on its own.
        let asleep = TabRowView()
        asleep.configure(TabRowContent(title: "Start", isAsleep: true))
        let moons = UITestSupport.imageViews(in: asleep)
            .filter { !($0 is FaviconImageView) && !$0.isHidden }
        #expect(moons.count == 1)

        let awake = TabRowView()
        awake.configure(TabRowContent(title: "Start"))
        #expect(UITestSupport.imageViews(in: awake)
            .filter { !($0 is FaviconImageView) && !$0.isHidden }
            .isEmpty)
    }

    @Test("The locks are visible on the row, not only in the menu that set them")
    func locksAreVisible() {
        let row = TabRowView()
        row.configure(TabRowContent(title: "Start", keepsAwake: true, keepsInSidebar: true))
        let icons = UITestSupport.imageViews(in: row)
            .filter { !($0 is FaviconImageView) && !$0.isHidden }
        #expect(icons.count == 2)
    }

    @Test("The close button takes the trailing slot back from the badge")
    func closeButtonWinsTheSlot() {
        // Reaching for close should not mean aiming past a moon.
        let row = TabRowView()
        row.onClose = {}
        row.configure(TabRowContent(title: "Start", isAsleep: true, idleText: "2h"))
        row.isSelected = true
        let visible = UITestSupport.imageViews(in: row)
            .filter { !($0 is FaviconImageView) && !$0.isHidden }
        #expect(visible.isEmpty)
    }

    @Test("Visual-only state is spoken as well as shown", arguments: [
        (true, false, false, "Start, failed to load"),
        (false, true, false, "Start, sleeping"),
        (false, false, true, "Start, loading"),
        (false, false, false, "Start")
    ])
    func statesAreSpoken(failed: Bool, suspended: Bool, loading: Bool, expected: String) {
        let row = TabRowView()
        row.configure(TabRowContent(
            title: "Start",
            isLoading: loading,
            isAsleep: suspended,
            isFailed: failed
        ))
        #expect(row.accessibilityLabel() == expected)
    }

    @Test("The selected row shows its close button without being hovered")
    func selectedRowShowsClose() {
        let row = TabRowView()
        row.onClose = {}
        row.configure(TabRowContent(title: "Start"))
        let close = UITestSupport.descendants(of: row).first { $0.accessibilityLabel() == "Close Start" }
        #expect(close?.isHidden == true)
        row.isSelected = true
        #expect(close?.isHidden == false)
    }

    @Test("A recycled row keeps nothing from the tab it used to show")
    func reuseClearsState() {
        let row = TabRowView()
        row.onClose = {}
        row.configure(TabRowContent(title: "Start", address: "https://example.com/"))
        row.isSelected = true

        row.prepareForReuse()
        #expect(row.onClose == nil)
        #expect(!row.isSelected)
        #expect(row.toolTip == nil)
    }

    @Test("An indented row's pill starts at the indent, not at the cell edge")
    func pillFollowsIndent() {
        let row = TabRowView()
        row.frame = NSRect(x: 0, y: 0, width: 280, height: Style.Metrics.rowHeight)

        row.indentation = 0
        let flush = row.pillRect
        row.indentation = FolderTree.indentPerLevel
        let nested = row.pillRect

        #expect(nested.minX - flush.minX == FolderTree.indentPerLevel)
        // The trailing edge does not move, so the pill is shortened rather
        // than slid sideways off the row.
        #expect(nested.maxX == flush.maxX)
    }

    @Test("A row on a group plate is inset from the plate's trailing edge too")
    func pillInsetInsideGroupPlate() {
        let row = TabRowView()
        row.frame = NSRect(x: 0, y: 0, width: 280, height: Style.Metrics.rowHeight)
        row.indentation = FolderTree.indentPerLevel

        let loose = row.pillRect
        row.isInGroupPlate = true
        let plated = row.pillRect

        // The leading edge stays at the indent; the trailing edge pulls in by
        // one indent step, so the pill is inset from the plate by the same
        // amount on both sides instead of running flush into its right corner.
        #expect(plated.minX == loose.minX)
        #expect(loose.maxX - plated.maxX == Style.Metrics.rowIndent)
        // The pill keeps its full height, so its content stays centred in it.
        #expect(plated.height == loose.height)
        #expect(plated.midY == loose.midY)
    }

    @Test("The row that ends a folder's plate keeps its pill off the plate's bottom edge")
    func lastPlateRowPadsBelowThePill() {
        let row = TabRowView()
        let slack = (Style.Metrics.rowHeight - Style.Metrics.rowPillHeight) / 2
        row.frame = NSRect(
            x: 0, y: 0, width: 280,
            height: Style.Metrics.rowHeight + Style.Metrics.folderPlateBottomPadding
        )
        row.isInGroupPlate = true
        let pill = row.pillRect

        // Distances from the row's own edges, whichever way its y axis runs.
        let fromTop = row.isFlipped ? pill.minY - row.bounds.minY : row.bounds.maxY - pill.maxY
        let fromBottom = row.isFlipped ? row.bounds.maxY - pill.maxY : pill.minY - row.bounds.minY

        // The pill is the height it always is and keeps its usual margin at the
        // row's top edge, so the rows above it keep their rhythm.
        #expect(pill.height == Style.Metrics.rowPillHeight)
        #expect(fromTop == slack)
        // The extra height is under it, where the plate's bottom edge is, so
        // the two no longer run along each other.
        #expect(fromBottom == slack + Style.Metrics.folderPlateBottomPadding)
    }

    @Test("A plate's extra bottom height goes below a row's content, not into it")
    func lastPlateRowKeepsContentAtTheTop() {
        let row = TabRowView()
        row.configure(TabRowContent(title: "Start"))
        row.indentation = FolderTree.indentPerLevel
        row.frame = NSRect(
            x: 0, y: 0, width: 280,
            height: Style.Metrics.rowHeight + Style.Metrics.folderPlateBottomPadding
        )
        row.layoutSubtreeIfNeeded()

        // The favicon sits half a row-height below the row's top edge, exactly
        // where it sits in an ordinary row: the padding is empty space under
        // the content rather than a second centre for it to drift towards.
        let fromTop = row.isFlipped
            ? row.favicon.frame.midY - row.bounds.minY
            : row.bounds.maxY - row.favicon.frame.midY
        #expect(fromTop == Style.Metrics.rowHeight / 2)
    }

    @Test("A row's icon keeps a margin inside its own pill")
    func contentSitsInsidePill() {
        let row = TabRowView()
        row.indentation = FolderTree.indentPerLevel
        row.frame = NSRect(x: 0, y: 0, width: 280, height: Style.Metrics.rowHeight)
        row.layoutSubtreeIfNeeded()
        #expect(row.favicon.frame.minX - row.pillRect.minX == Style.Metrics.rowContentInset)
    }

    @Test("Indenting a row moves its content, not just its pill")
    func indentationMovesContent() {
        let row = TabRowView()
        row.indentation = 0
        row.frame = NSRect(x: 0, y: 0, width: 280, height: Style.Metrics.rowHeight)
        row.layoutSubtreeIfNeeded()
        let flush = row.favicon.frame.minX

        row.indentation = Style.Metrics.rowIndent
        row.layoutSubtreeIfNeeded()
        #expect(row.favicon.frame.minX - flush == Style.Metrics.rowIndent)
    }
}

@Suite("The archive list")
@MainActor
struct ArchiveListTests {
    private func entry(_ title: String, space: String? = "Work") -> ArchiveListView.Entry {
        ArchiveListView.Entry(
            record: BrowserSession.ArchivedTab(
                snapshot: SessionSnapshot.Tab(url: URL(string: "https://example.com/\(title)")!, title: title),
                spaceID: UUID(),
                archivedAt: .now
            ),
            spaceName: space
        )
    }

    private func text(in list: ArchiveListView) -> String {
        UITestSupport.textFields(in: list).map(\.stringValue).joined(separator: " ")
    }

    private func clearButton(in list: ArchiveListView) -> NSButton? {
        UITestSupport.buttons(in: list).first { $0.title == "Clear" }
    }

    @Test("With archiving off, an empty list says where to turn it on")
    func emptyStatePointsAtTheSetting() {
        let list = ArchiveListView()
        list.show([], isArchivingEnabled: false)

        #expect(list.isEmpty)
        #expect(list.count == 0)
        #expect(text(in: list).contains("Nothing is archived"))
        #expect(text(in: list).contains("Settings"))
        // Nothing to clear, so the button that would is inert.
        #expect(clearButton(in: list)?.isEnabled == false)
    }

    @Test("With archiving on, the empty state promises sleeping tabs instead")
    func emptyStateWithArchivingOn() {
        let list = ArchiveListView()
        list.show([], isArchivingEnabled: true)
        #expect(text(in: list).contains("Nothing is archived yet"))
        #expect(!text(in: list).contains("Settings"))
    }

    @Test("Rows are listed, and the empty state gives way to them")
    func rowsReplaceTheEmptyState() {
        let list = ArchiveListView()
        list.show([entry("one"), entry("two")], isArchivingEnabled: true)

        #expect(!list.isEmpty)
        #expect(list.count == 2)
        let table = UITestSupport.descendants(of: list).compactMap { $0 as? NSTableView }.first
        #expect(table?.numberOfRows == 2)
        #expect(clearButton(in: list)?.isEnabled == true)
    }

    @Test("The list is not a selection: a click puts the tab back")
    func rowsArePressedNotSelected() {
        let list = ArchiveListView()
        let table = UITestSupport.descendants(of: list).compactMap { $0 as? NSTableView }.first
        guard let table else {
            Issue.record("the list has no table")
            return
        }
        // A selection would be a second state to read on top of the click that
        // already acted.
        #expect(list.tableView(table, shouldSelectRow: 0) == false)
        #expect(table.selectionHighlightStyle == .none)
    }
}

@Suite("The archived row")
@MainActor
struct ArchivedRowTests {
    /// A real event object: the hover handlers take one, and an empty one is
    /// enough for a view that only looks at the pointer's presence.
    private func event() -> NSEvent {
        NSEvent.mouseEvent(
            with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0
        )!
    }

    @Test("The remove button arrives with the pointer, not before")
    func removeButtonIsHoverOnly() {
        let row = ArchivedRowView()
        row.onRemove = {}
        let remove = UITestSupport.buttons(in: row).first
        #expect(remove?.isHidden == true)

        row.mouseEntered(with: event())
        #expect(remove?.isHidden == false)
        row.mouseExited(with: event())
        #expect(remove?.isHidden == true)
    }

    @Test("Pressing the row puts the tab back, so the whole row is the target")
    func pressingPicks() {
        let row = ArchivedRowView()
        var picked = 0
        row.onPick = { picked += 1 }
        #expect(row.accessibilityPerformPress())
        #expect(picked == 1)
    }

    @Test("The pill is taller than a tab row's, because the row has two lines")
    func pillFitsTwoLines() {
        let row = ArchivedRowView()
        row.frame = NSRect(x: 0, y: 0, width: 280, height: ArchivedRowView.rowHeight)
        // Inset from the row on every side, and starting where a tab row's pill
        // starts so the two lists line up.
        #expect(row.pillRect.minX == Style.Metrics.sidebarInset + 2)
        #expect(row.pillRect.height > Style.Metrics.rowPillHeight)
        #expect(row.pillRect.height < row.bounds.height)
    }
}

@Suite("The sidebar footer")
@MainActor
struct SidebarFooterTests {
    @Test("One space needs no indicator")
    func hidesSingleDot() {
        let dots = PageDotsView()
        dots.show(count: 1, selected: 0)
        #expect(dots.isHidden)
        dots.show(count: 3, selected: 1)
        #expect(!dots.isHidden)
    }

    @Test("The dot strip is exactly as wide as the dots it draws")
    func intrinsicWidthMatchesDots() {
        let dots = PageDotsView()
        dots.show(count: 3, selected: 0)
        let expected = 2 * Style.Metrics.pageDotSpacing + Style.Metrics.pageDotDiameter
        #expect(dots.intrinsicContentSize.width == expected)
    }

    @Test("The dots say where you are, for VoiceOver as well as visually")
    func announcesPosition() {
        let dots = PageDotsView()
        dots.show(count: 3, selected: 1)
        #expect(dots.accessibilityValue() as? String == "2 of 3")
    }

    @Test("The dots are clickable at button size and distinguishable at a glance")
    func dotsAreLegibleAndHittable() {
        let dots = PageDotsView()
        dots.show(count: 3, selected: 1)
        #expect(dots.intrinsicContentSize.height == Style.Metrics.iconButtonSide)
        #expect(dots.intrinsicContentSize.width > Style.Metrics.pageDotDiameter)
        #expect(Style.Colors.pageDotActive != Style.Colors.pageDotInactive)
        #expect(Style.Metrics.pageDotSpacing > Style.Metrics.pageDotDiameter)
    }

    @Test("One space needs no indicator")
    func singleSpaceHidesDots() {
        let dots = PageDotsView()
        dots.show(count: 1, selected: 0)
        #expect(dots.isHidden)
        dots.show(count: 2, selected: 0)
        #expect(!dots.isHidden)
    }

    @Test("The footer is one row: a leading slot, the dots centred, a trailing slot")
    func footerIsASingleRow() {
        let footer = SidebarFooterView()
        footer.setLeadingActions([TopBarAction(symbolName: "sidebar.leading", label: "Toggle") {}])
        footer.setTrailingActions([TopBarAction(symbolName: "chevron.down", label: "Spaces") {}])
        footer.showPages(count: 2, selected: 0)

        let frames = UITestSupport.laidOutFooter(footer, width: Style.Metrics.sidebarWidth)
        #expect(frames.height == Style.Metrics.footerHeight)
        // One row: everything shares a centre line.
        #expect(abs(frames.leading.midY - frames.dots.midY) < 1)
        #expect(abs(frames.trailing.midY - frames.dots.midY) < 1)
        // In order, and not on top of each other.
        #expect(frames.leading.maxX < frames.dots.minX)
        #expect(frames.dots.maxX < frames.trailing.minX)
        #expect(abs(frames.dots.midX - Style.Metrics.sidebarWidth / 2) < 1)
    }
}

@Suite("Content container")
@MainActor
struct ContentContainerTests {
    @Test("All four corners are rounded, because the card meets only the window top")
    func roundsEveryCorner() {
        let container = ContentContainerView()
        let card = container.subviews.first { $0.layer?.cornerRadius ?? 0 > 0 }
        #expect(card?.layer?.cornerRadius == Style.Metrics.contentCornerRadius)
        #expect(card?.layer?.maskedCorners == [
            .layerMinXMinYCorner, .layerMinXMaxYCorner,
            .layerMaxXMinYCorner, .layerMaxXMaxYCorner
        ])
    }

    @Test("The card is backed by material, so the corner has something to reveal")
    func cardSitsOnSidebarMaterial() {
        let container = ContentContainerView()
        let material = container.subviews.compactMap { $0 as? NSVisualEffectView }.first
        #expect(material?.material == .sidebar)
        #expect(material?.blendingMode == .behindWindow)

        let card = container.subviews.first { $0.layer?.cornerRadius ?? 0 > 0 }
        #expect(card?.layer?.cornerCurve == .continuous)
        // The material is below the card, and the card starts below the top.
        let materialIndex = material.flatMap { container.subviews.firstIndex(of: $0) }
        let cardIndex = card.flatMap { container.subviews.firstIndex(of: $0) }
        #expect(materialIndex != nil && cardIndex != nil && materialIndex! < cardIndex!)
        // The same gutter on all four edges: the card carries its own toolbar,
        // so a zero top inset puts the card against the window while the other
        // three sides float, which reads as a missing gap.
        #expect(Style.Metrics.contentTopInset == Style.Metrics.elementSeparation)
        #expect(Style.Metrics.elementSeparation > 0)
    }

    @Test("Setting a page twice does not leave the first one behind")
    func pageIsReplaced() {
        let container = ContentContainerView()
        let first = NSView()
        let second = NSView()
        container.setPage(first)
        container.setPage(second)
        #expect(first.superview == nil)
        #expect(second.superview != nil)
        container.setPage(nil)
        #expect(second.superview == nil)
    }
}

/// Walking a view tree is the only way to assert on views a component keeps
/// private, and every suite above needs the same three walks.
@MainActor
enum UITestSupport {
    static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    static func accessibilityLabels(in view: NSView) -> [String] {
        descendants(of: view).compactMap { $0.accessibilityLabel() }
    }

    static func textFields(in view: NSView) -> [NSTextField] {
        descendants(of: view).compactMap { $0 as? NSTextField }
    }

    static func imageViews(in view: NSView) -> [NSImageView] {
        descendants(of: view).compactMap { $0 as? NSImageView }
    }

    static func buttons(in view: NSView) -> [NSButton] {
        descendants(of: view).compactMap { $0 as? NSButton }
    }

    /// Alignment is a claim about frames, and a frame only exists once Auto
    /// Layout has run, so these two put the view in a host of a known width
    /// and resolve it.
    static func host(_ view: NSView, width: CGFloat, height: CGFloat) -> NSView {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.topAnchor.constraint(equalTo: host.topAnchor)
        ])
        host.layoutSubtreeIfNeeded()
        return host
    }

    static func laidOut(_ bar: ContentTopBar, width: CGFloat) -> (breadcrumb: NSRect, share: NSRect) {
        let host = host(bar, width: width, height: Style.Metrics.topBarHeight)
        let share = buttons(in: bar).first { $0.accessibilityLabel() == "Share" }
        let shareFrame = share.map { $0.convert($0.bounds, to: host) } ?? .zero
        let breadcrumb = descendants(of: bar).first { $0 is BreadcrumbView }
        let breadcrumbFrame = breadcrumb.map { $0.convert($0.bounds, to: host) } ?? .zero
        return (breadcrumbFrame, shareFrame)
    }

    static func laidOutFooter(
        _ footer: SidebarFooterView,
        width: CGFloat
    ) -> (height: CGFloat, leading: NSRect, dots: NSRect, trailing: NSRect) {
        let host = host(footer, width: width, height: Style.Metrics.footerHeight)
        let dots = descendants(of: footer).first { $0 is PageDotsView }
        let slots = footer.subviews.compactMap { $0 as? NSStackView }
        let frames = slots.map { $0.convert($0.bounds, to: host) }.sorted { $0.minX < $1.minX }
        return (
            footer.frame.height,
            frames.first ?? .zero,
            dots.map { $0.convert($0.bounds, to: host) } ?? .zero,
            frames.last ?? .zero
        )
    }
}

@Suite("Pinned tile wrapping")
struct TileGridTests {
    @Test("Tiles fill the row and share its width equally")
    func fillsTheRow() {
        let plan = TileGrid.plan(itemCount: 4, availableWidth: 300)
        #expect(plan.columns == 4)
        let spacing = Style.Metrics.tileSpacing
        let total = plan.tileWidth * 4 + spacing * 3
        #expect(abs(total - 300) < 0.01)
    }

    @Test("A narrow strip wraps instead of shrinking tiles past legibility")
    func wrapsWhenNarrow() {
        // Derived from the minimum rather than hardcoded, so changing the tile
        // size does not turn this into a test of what the size used to be.
        let spacing = Style.Metrics.tileSpacing
        let width = TileGrid.minimumTileWidth * 2 + spacing
        let plan = TileGrid.plan(itemCount: 4, availableWidth: width)

        #expect(plan.columns == 2)
        #expect(plan.rows == 2)
        #expect(plan.tileWidth >= TileGrid.minimumTileWidth)
    }

    @Test("A tile is never narrower than the minimum, at any width")
    func neverBelowMinimum() {
        for width in stride(from: 40.0, through: 900.0, by: 7.0) {
            let plan = TileGrid.plan(itemCount: 6, availableWidth: width)
            // One column is allowed to be narrower: there is nothing to wrap to.
            guard plan.columns > 1 else { continue }
            #expect(plan.tileWidth >= TileGrid.minimumTileWidth,
                    "width \(width) produced \(plan.tileWidth)")
        }
    }

    @Test("A wide strip never has more columns than tiles")
    func neverMoreColumnsThanTiles() {
        let plan = TileGrid.plan(itemCount: 4, availableWidth: 1200)
        #expect(plan.columns == 4)
        #expect(plan.rows == 1)
    }

    @Test("Height grows with the number of rows")
    func heightFollowsRows() {
        let one = TileGrid.plan(itemCount: 2, availableWidth: 300)
        let two = TileGrid.plan(itemCount: 4, availableWidth: 150)
        #expect(one.rows == 1)
        #expect(two.rows == 2)
        #expect(two.height > one.height)
    }

    @Test("A single tile is never stretched across the whole strip")
    func singleTile() {
        let plan = TileGrid.plan(itemCount: 1, availableWidth: 900)
        #expect(plan.columns == 1)
        #expect(plan.tileWidth == 900)
    }

    @Test("A zero width does not divide by zero or report a negative height")
    func zeroWidth() {
        let plan = TileGrid.plan(itemCount: 3, availableWidth: 0)
        #expect(plan.columns == 1)
        #expect(plan.height > 0)
    }
}

@Suite("Brand ring colours")
@MainActor
struct BrandPaletteTests {
    private func swatch(_ colors: [NSColor], side: Int = 8) -> NSImage {
        let image = NSImage(size: NSSize(width: side * colors.count, height: side))
        image.lockFocus()
        for (index, color) in colors.enumerated() {
            color.setFill()
            NSRect(x: index * side, y: 0, width: side, height: side).fill()
        }
        image.unlockFocus()
        return image
    }

    @Test("Grey, white and black are not brand colours")
    func chromaticFilter() {
        #expect(BrandPalette.isChromatic(.white) == false)
        #expect(BrandPalette.isChromatic(.black) == false)
        #expect(BrandPalette.isChromatic(NSColor(white: 0.5, alpha: 1)) == false)
        #expect(BrandPalette.isChromatic(.systemRed))
        #expect(BrandPalette.isChromatic(.systemBlue))
    }

    @Test("A multi-coloured icon yields its colours")
    func findsColors() {
        let found = BrandPalette.colors(in: swatch([.systemRed, .systemBlue, .systemGreen]))
        #expect(found.count >= 2)
    }

    @Test("Shades of one colour count as one, not as several")
    func mergesShades() {
        let red = NSColor.systemRed
        let lighter = red.blended(withFraction: 0.25, of: .white) ?? red
        let found = BrandPalette.colors(in: swatch([red, lighter]))
        #expect(found.count == 1)
    }

    @Test("Reds either side of the hue wrap are one colour, not two")
    func mergesAcrossTheHueSeam() {
        // Red sits at hue 0, so two shades of it can land at 0.998 and 0.004.
        // They are the same red to the eye and must bucket together. Stated as
        // explicit hues rather than .systemRed, whose exact value moves between
        // macOS releases — that drift is what hid this in the first place.
        let below = NSColor(hue: 0.998, saturation: 0.9, brightness: 0.9, alpha: 1)
        let above = NSColor(hue: 0.004, saturation: 0.9, brightness: 0.9, alpha: 1)
        #expect(BrandPalette.colors(in: swatch([below, above])).count == 1)
    }

    @Test("A monochrome icon gets a neutral ring rather than an invented one")
    func monochromeFallsBack() {
        let found = BrandPalette.colors(in: swatch([.white, .black, NSColor(white: 0.5, alpha: 1)]))
        #expect(found.isEmpty)
        #expect(BrandPalette.ringColors(for: nil).count >= 2)
    }

    @Test("The ring always closes, so a conic sweep shows no seam")
    func ringCloses() {
        for image in [swatch([.systemRed, .systemBlue]), swatch([.systemRed])] {
            let ring = BrandPalette.ringColors(for: image)
            #expect(ring.count >= 2)
            #expect(ring.first == ring.last)
        }
    }

    @Test("A single-colour icon still gets a gradient, not a flat line")
    func singleColorStillGradients() {
        let ring = BrandPalette.ringColors(for: swatch([.systemRed]))
        #expect(ring.count == 3)
        #expect(ring[0] != ring[1])
    }
}

@Suite("Sidebar context menu")
@MainActor
struct SidebarContextMenuTests {
    @Test("The menu has the expected shape")
    func hasDiasShape() {
        let sidebar = SidebarViewController(session: TestSession.make().0)
        let titles = sidebar.makeContextMenu().items.map { $0.isSeparatorItem ? "-" : $0.title }
        #expect(titles == [
            "New Tab", "Reopen Closed Tab", "-",
            "New Group", "New Live Group", "-",
            "New Space\u{2026}", "-",
            "Archive\u{2026}", "-",
            "Bookmark All Tabs", "-",
            "Hide Sidebar", "Compact Mode", "-",
            "Close All Tabs in Space"
        ])
    }

    @Test("Live groups come in every provider kind there is")
    func liveGroupSubmenu() {
        let sidebar = SidebarViewController(session: TestSession.make().0)
        let live = sidebar.makeContextMenu().items.first { $0.title == "New Live Group" }
        let kinds = live?.submenu?.items.map(\.title) ?? []
        #expect(kinds == ["RSS Feed\u{2026}", "GitHub Pull Requests\u{2026}", "GitHub Issues\u{2026}"])
    }

    @Test("A tab row's menu has the expected shape, less what Kylmora cannot offer")
    func tabMenuShape() {
        let session = TestSession.make().0
        let tab = session.newTab(url: URL(string: "https://a.example")!)
        let sidebar = SidebarViewController(session: session)
        let titles = sidebar.makeTabMenu(for: tab).items.map { $0.isSeparatorItem ? "-" : $0.title }
        #expect(titles == [
            "Pin", "-",
            "Keep Awake", "Keep in Sidebar", "Sleep Now", "Archive Now", "-",
            "Open as Split", "Duplicate", "-",
            "New Group with Tab", "Move to Space", "-",
            "Rename\u{2026}", "-",
            "Close", "Close Other Tabs", "Close Tabs Below", "Close All Tabs in Space"
        ])
    }

    @Test("Window-level items go up the responder chain rather than to the sidebar")
    func windowItemsHaveNoTarget() {
        let sidebar = SidebarViewController(session: TestSession.make().0)
        let items = sidebar.makeContextMenu().items
        let newTab = items.first { $0.title == "New Tab" }
        #expect(newTab?.target == nil)
        #expect(newTab?.action == #selector(BrowserWindowController.newTab(_:)))
        let newGroup = items.first { $0.title == "New Group" }
        #expect(newGroup?.target === sidebar)
    }
}

@Suite("The sidebar's archive")
@MainActor
struct SidebarArchiveTests {
    /// The sidebar's own tab table, which is the one it is the data source of.
    private func tabList(in sidebar: SidebarViewController) -> NSTableView? {
        UITestSupport.descendants(of: sidebar.view)
            .compactMap { $0 as? NSTableView }
            .first { ($0.dataSource as AnyObject?) === sidebar }
    }

    private func archive(in sidebar: SidebarViewController) -> ArchiveListView? {
        UITestSupport.descendants(of: sidebar.view).compactMap { $0 as? ArchiveListView }.first
    }

    @Test("The archive takes the pins' and the tab list's place, and gives them back")
    func archiveReplacesTheTabs() {
        let sidebar = SidebarViewController(session: TestSession.make().0)
        sidebar.loadViewIfNeeded()

        let list = tabList(in: sidebar)
        let archiveList = archive(in: sidebar)
        // The space's own list is what the sidebar shows until it is asked for
        // the archive.
        #expect(!sidebar.isShowingArchive)
        #expect(archiveList?.isHidden == true)
        #expect(list?.isHiddenOrHasHiddenAncestor == false)

        sidebar.toggleArchive()
        #expect(sidebar.isShowingArchive)
        #expect(archiveList?.isHidden == false)
        #expect(list?.isHiddenOrHasHiddenAncestor == true)

        sidebar.toggleArchive()
        #expect(!sidebar.isShowingArchive)
        #expect(archiveList?.isHidden == true)
        #expect(list?.isHiddenOrHasHiddenAncestor == false)
    }
}

