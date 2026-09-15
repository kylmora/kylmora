import AppKit
import Testing
@testable import Kylmora

/// The rules behind the default light and dark theme.
///
/// These are not tests of particular numbers -- the numbers are taste and are
/// meant to be tuned -- but of the relationships between them that stop the
/// chrome looking wrong. Each one exists because breaking it produced something
/// visibly bad, and each names what that was.
@Suite("The default light and dark theme")
@MainActor
struct ChromeThemeTests {

    /// A colour as it will actually be painted in one appearance.
    private func resolved(_ color: NSColor, dark: Bool) -> NSColor {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        var out = color
        appearance.performAsCurrentDrawingAppearance {
            out = color.usingColorSpace(.sRGB) ?? color
        }
        return out
    }

    // MARK: - Light and dark

    @Test("A shadow stays dark in dark mode; a hairline does not")
    func shadowsDoNotInvert() {
        // Light still falls from above in dark mode, so a shadow is still an
        // absence of light. Drawing one in white -- which is right for a
        // hairline, because an edge must contrast with its surface -- put a
        // glowing halo around the selected row instead of sitting it down on
        // the surface.
        for shadow in [Style.Colors.rowSelectedShadow, Style.Colors.cardShadow] {
            #expect(resolved(shadow, dark: true).brightnessComponent < 0.1)
            #expect(resolved(shadow, dark: false).brightnessComponent < 0.1)
        }
        // A hairline is the opposite: dark on a light surface, light on a dark
        // one, or it disappears into whichever it is drawn on.
        for line in [Style.Colors.hairline, Style.Colors.folderPlateStroke] {
            #expect(resolved(line, dark: false).brightnessComponent < 0.1)
            #expect(resolved(line, dark: true).brightnessComponent > 0.9)
        }
    }

    @Test("Both appearances are defined for every surface, with no shared coat")
    func bothCoatsDiffer() {
        // A surface whose two appearances resolve identically has only been
        // designed once, and one of the two is wrong: the same alpha over a
        // near-white material and over a near-black one does not read the same.
        let surfaces: [NSColor] = [
            Style.Colors.rowSelectedFill, Style.Colors.rowHoverFill,
            Style.Colors.folderPlateFill, Style.Colors.tileFill,
            Style.Colors.fieldFill
        ]
        for surface in surfaces {
            let light = resolved(surface, dark: false)
            let dark = resolved(surface, dark: true)
            #expect(light.alphaComponent != dark.alphaComponent
                || light.brightnessComponent != dark.brightnessComponent)
        }
    }

    // MARK: - Loudness

    @Test("A space's colour tints the chrome rather than covering it")
    func washIsATint() {
        // Above about a third, the wash stops being a tint: it covers the
        // material completely, so the chrome loses the desktop showing through
        // it, and every surface drawn on top has to fight a flat block of
        // pigment instead of sitting on a neutral one.
        for theme in SpaceTheme.palette where theme.tintsChrome {
            for dark in [false, true] {
                let alpha = resolved(theme.wash!, dark: dark).alphaComponent
                #expect(alpha < 0.33, "\(theme.title) washes at \(alpha)")
                #expect(alpha > 0.05, "\(theme.title) is too faint to identify a space")
            }
        }
    }

    @Test("A folder's colour is quieter than the space it sits inside")
    func groupIsQuieterThanItsSpace() {
        // A group is a division within a space, so its plate has to be quieter
        // than the space's own wash, not louder. At 0.85 a coloured folder was
        // an opaque slab: it drowned the favicons on its own rows and shouted
        // over the space colour it was meant to sit within.
        let wash = resolved(SpaceTheme.blue.wash!, dark: true).alphaComponent
        #expect(TabGroupAppearance.fillAlpha < 0.35)
        #expect(TabGroupAppearance.fillAlpha < wash * 2)
    }

    @Test("Hover is a hint and selection is a statement")
    func hoverIsQuieterThanSelection() {
        for dark in [false, true] {
            let hover = resolved(Style.Colors.rowHoverFill, dark: dark).alphaComponent
            let selected = resolved(Style.Colors.rowSelectedFill, dark: dark).alphaComponent
            #expect(hover < selected, "a hovered row must not outshout the selected one")
            #expect(hover < 0.12, "hover is confirmation that the pointer is there, nothing more")
        }
    }

    // MARK: - The grid

    @Test("The New Tab row sits on the same grid as the tab rows above it")
    func actionRowMatchesTheTabGrid() {
        // Both are placed by the sidebar at the same leading inset, so their
        // icons have to land on the same column. Before this the action row
        // carried its own numbers and "New Tab" sat five points left of every
        // title above it.
        let tab = TabRowView()
        tab.indentation = 0
        tab.configure(TabRowContent(title: "Start"))
        tab.frame = NSRect(x: 0, y: 0, width: 280, height: Style.Metrics.rowHeight)
        tab.layoutSubtreeIfNeeded()

        let action = ActionRowView()
        action.show(symbolName: "plus", title: "New Tab")
        action.translatesAutoresizingMaskIntoConstraints = true
        action.frame = NSRect(x: 0, y: 0, width: 280, height: Style.Metrics.groupHeaderHeight)
        action.layoutSubtreeIfNeeded()

        // Converted, not read straight off `frame`: the action row nests its
        // contents in a stack, so a raw frame there is in the stack's space.
        func x(of view: NSView, in root: NSView) -> NSRect {
            view.convert(view.bounds, to: root)
        }

        let glyph = try! #require(UITestSupport.imageViews(in: action).first)
        #expect(x(of: glyph, in: action).midX == tab.favicon.frame.midX)

        let newTab = try! #require(
            UITestSupport.textFields(in: action).first { $0.stringValue == "New Tab" }
        )
        let start = try! #require(
            UITestSupport.textFields(in: tab).first { $0.stringValue == "Start" }
        )
        #expect(x(of: newTab, in: action).minX == x(of: start, in: tab).minX)
    }

    @Test("A pill keeps clear material above and below it at every density")
    func pillsDoNotTouch() {
        // Pills that nearly touch read as one segmented bar rather than as
        // separate rows -- and the selected one, which casts a shadow, has
        // nowhere to cast it.
        for density in SidebarDensity.allCases {
            let margin = (density.rowHeight - density.pillHeight) / 2
            #expect(margin >= 3, "\(density.title) leaves only \(margin) points")
            #expect(density.pillHeight >= Style.Metrics.faviconSide + 6,
                    "\(density.title) has no room for a favicon")
        }
    }

    @Test("A selected row's shadow is allowed to leave its row")
    func shadowsAreNotClipped() {
        // The shadow needs more room below the pill than the pill's own margin
        // inside the row, so a row that clips its contents slices the shadow
        // off in a hard straight line -- which reads as a grey rectangle stuck
        // behind the row rather than as a shadow at all. The scroll view still
        // clips at the list's edges, which is the clipping that should happen.
        let margin = (Style.Metrics.rowHeight - Style.Metrics.rowPillHeight) / 2
        #expect(Style.Metrics.rowShadowRadius + Style.Metrics.rowShadowOffset > margin,
                "the shadow fits inside the row, so nothing below is needed")
        #expect(TabRowView().clipsToBounds == false)
        #expect(FolderPlateRowView().clipsToBounds == false)
    }

    @Test("A container is rounder than what sits inside it")
    func containersAreRounderThanTheirContents() {
        // The difference in corner radius is what says which shape is inside
        // which. Equal radii read as two overlapping rectangles.
        #expect(Style.Metrics.folderPlateCornerRadius > Style.Metrics.rowCornerRadius)
        #expect(Style.Metrics.rowCornerRadius <= Style.Metrics.rowPillHeight / 2)
        #expect(Style.Metrics.tileCornerRadius <= Style.Metrics.tileHeight / 2)
    }

    @Test("The gap between cards is larger than the padding inside one")
    func breaksBeatJoins() {
        // Otherwise the grouping inverts: the cards read as separated rows
        // rather than as rows inside cards.
        #expect(Style.Metrics.folderPlateGap > Style.Metrics.folderPlateBottomPadding)
    }

    // MARK: - Type

    @Test("A folder's name is smaller than the tabs it holds")
    func headersDoNotOutrankTheirRows() {
        // A header labels a group; it is not an item competing with the items.
        #expect(Style.Fonts.groupHeader.pointSize < Style.Fonts.body.pointSize)
        // And the space's name, which labels the whole window, outranks both.
        #expect(Style.Fonts.title.pointSize > Style.Fonts.body.pointSize)
    }

    // MARK: - Controls

    @Test("A button's symbol stays legible at every button size")
    func symbolsScaleWithTheirButton() {
        // The glyph is sized by point size rather than by squeezing it into a
        // frame: scaling a 13-point symbol into a 6-point box, which sizing by
        // frame amounts to on the smallest buttons, leaves it both too small to
        // hit and too thin to see.
        for side in [CGFloat(18), Style.Metrics.iconButtonSide, 44] {
            let size = IconButton.symbolPointSize(forSide: side)
            #expect(size >= 9, "a \(side)-point button got a \(size)-point symbol")
            #expect(size < side, "the symbol must leave the highlight a margin")
        }
    }

    @Test("A row's highlight follows the row's state")
    func highlightFollowsState() {
        let row = TabRowView()
        row.frame = NSRect(x: 0, y: 0, width: 280, height: Style.Metrics.rowHeight)
        row.layoutSubtreeIfNeeded()

        row.isSelected = true
        #expect(row.highlightState == .selected)
        row.isSelected = false
        #expect(row.highlightState == .rest)
        row.mouseEntered(with: UITestSupport.hoverEvent())
        #expect(row.highlightState == .hover)
        // Selection outranks hover: the current row stays the current row while
        // the pointer wanders over it.
        row.isSelected = true
        #expect(row.highlightState == .selected)
        row.mouseExited(with: UITestSupport.hoverEvent())
        #expect(row.highlightState == .selected)
    }

    @Test("A recycled row arrives already correct rather than fading in")
    func reusedRowsDoNotAnimate() {
        let row = TabRowView()
        row.frame = NSRect(x: 0, y: 0, width: 280, height: Style.Metrics.rowHeight)
        row.isSelected = true
        row.layoutSubtreeIfNeeded()

        row.prepareForReuse()
        #expect(row.highlightState == .rest)
        row.configure(TabRowContent(title: "Next"))
        row.isSelected = true
        #expect(row.highlightState == .selected)
    }

    @Test("Reduce Motion stops the travel without stopping the change")
    func reduceMotionZeroesDurations() {
        // The durations themselves are short by design: a hover that takes a
        // quarter second to arrive feels laggy rather than smooth.
        #expect(Style.Motion.hover < Style.Motion.selection)
        #expect(Style.Motion.selection <= 0.2)
        if Style.Motion.isReduced {
            #expect(Style.Motion.duration(Style.Motion.selection) == 0)
        } else {
            #expect(Style.Motion.duration(Style.Motion.selection) == Style.Motion.selection)
        }
    }
}

