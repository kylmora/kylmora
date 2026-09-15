import AppKit

/// Every size, radius, font and colour the chrome uses.
///
/// These numbers are measurements, not taste. They were read off a 2x
/// screenshot of a reference window with a pixel scanner and halved.
/// Collecting them here is what stops the same `34` appearing in four files
/// meaning four different things, and makes a re-measurement a one-line edit.
///
/// Colours are computed properties rather than stored constants for two
/// reasons: a stored `NSColor` would be shared mutable global state under
/// strict concurrency, and a semantic colour must be re-resolved every time the
/// appearance changes. Nothing here names a literal RGB value, so light and
/// dark both come out right without a second palette to keep in sync.
enum Style {

    // MARK: - Metrics

    enum Metrics {
        /// The universal gutter, used for the sidebar-to-page gap, the page
        /// inset and the split-view row gap alike -- which is a large part of
        /// why the chrome reads as one system rather than several.
        static let elementSeparation: CGFloat = 8

        /// Resting sidebar width. Some browsers have no default at all -- the
        /// splitter keeps wherever it was left -- so this is only where a
        /// first launch starts.
        static let sidebarWidth: CGFloat = 306
        /// Our own floor. A common floor is 150; some designs let it go about
        /// a third narrower still, and the tile strip already wraps to one
        /// column before this, so nothing breaks down there.
        static let sidebarMinWidth: CGFloat = 105
        static let sidebarMaxWidth: CGFloat = 500
        /// Collapsed: one tab pill plus the padding either side of it.
        static let sidebarCollapsedWidth: CGFloat = 60
        /// Gap between the floating compact sidebar and the window edge. The
        /// same 8 points as `elementSeparation`, named separately because
        /// compact mode is free to change it without moving every other
        /// gutter in the window.
        static let compactFloat: CGFloat = 8
        /// Width of a collapsed sidebar while compact mode is on. Wider than
        /// the ordinary 60 because the floating plate carries its own padding.
        static let sidebarCollapsedCompactWidth: CGFloat = 74
        /// The floating plate: rounder than the page card, because it is
        /// smaller and it floats.
        static let compactPlateCornerRadius: CGFloat = 12
        /// The plate's lift off the page.
        static let compactPlateShadowRadius: CGFloat = 18
        /// Distance from the sidebar's edge to the pinned tiles and the group
        /// headers. Tab rows sit further in again, by `rowIndent`.
        static let sidebarInset: CGFloat = 6

        /// Height of the strip the traffic lights float over. The sidebar owns
        /// it because the window has no titlebar of its own.
        static let titlebarHeight: CGFloat = 53
        /// Space the traffic lights need before anything else may be placed on
        /// the titlebar row.
        static let trafficLightWidth: CGFloat = 78

        static let tileWidth: CGFloat = 68
        /// A common tile height is 46. Ours is a third smaller so more
        /// shortcuts fit across the strip before it wraps, which is the whole
        /// point of a row of them.
        static let tileHeight: CGFloat = 32
        static let tileSpacing: CGFloat = 4
        /// Scaled with the tile: a 14-point radius on a 32-point tile reads as
        /// a lozenge rather than a rounded square.
        static let tileCornerRadius: CGFloat = 10
        /// Icon drawn inside a pinned tile. The same 16 points the sidebar
        /// rows use, which is also the size the favicon cache stores for.
        static let tileIconSide: CGFloat = 16

        /// Full height of a tab row: the pill plus its 2-point margin above
        /// and below.
        ///
        /// Tighter than the usual 37–40 at the user's request. Thirteen-point
        /// text in a 28-point pill still has seven points above and below it,
        /// so the rows read as a list rather than a stack of buttons, and
        /// eight more of them fit on a screen.
        /// Set by the sidebar density in Settings; 32 is the regular one.
        @MainActor static var rowHeight: CGFloat { Settings.shared.sidebarDensity.rowHeight }
        /// The filled rounded rectangle drawn behind the selected row.
        @MainActor static var rowPillHeight: CGFloat { Settings.shared.sidebarDensity.pillHeight }
        /// A reference pill radius is 9 on a 34-point pill; the same
        /// proportion on a 28-point one. A larger radius like 14 looked right
        /// at that bigger size, but turns a pill this short into a capsule.
        static let rowCornerRadius: CGFloat = 8
        /// Extra leading inset for rows that belong to a group.
        static let rowIndent: CGFloat = 14
        /// Matches `FaviconImageView.side`, so a row built here and a row built
        /// by the existing sidebar line up.
        static let faviconSide: CGFloat = 16
        /// Favicon-to-title and title-to-trailing-slot gap. A reference value
        /// is 10 at a taller row height; scaled down here to match.
        static let rowContentSpacing: CGFloat = 8
        /// Padding inside the row pill, before the favicon and after the close
        /// button. Without it the icon sits 2 points from the pill's edge and a
        /// folder's children read as a flat list that happens to start late,
        /// rather than as contents nested under a header.
        static let rowContentInset: CGFloat = 8
        /// A folder header is a row pill plus the same margins, so it lines
        /// up with the tabs under it.
        static let groupHeaderHeight: CGFloat = 32
        /// The plate a folder and its children sit on. A little rounder than
        /// the pills inside it, as a container should be.
        static let folderPlateCornerRadius: CGFloat = 10
        /// Clear space above a folder's plate. It is added to the header's row,
        /// so two folders in a row, or a folder after loose tabs, are separated
        /// by more than the pill margin alone.
        static let folderPlateGap: CGFloat = 6
        /// Clear space inside a folder's plate, under its last row. It is added
        /// to that row's height, so the card's bottom edge clears the last pill
        /// by a visible margin -- a pill whose bottom runs along the plate's
        /// bottom edge reads as the plate's own outline rather than as a row
        /// inside it. Deliberately the same measure as `folderPlateGap`, so a
        /// card is the same weight at both ends.
        static let folderPlateBottomPadding: CGFloat = 6
        /// Disclosure chevron and the small glyphs in the sidebar footer.
        static let smallGlyphSide: CGFloat = 11

        /// The workspace indicator row, which is what the footer is.
        static let footerHeight: CGFloat = 44
        static let pageDotDiameter: CGFloat = 6
        /// Centre-to-centre, so the gap between two dots is this minus the
        /// diameter.
        static let pageDotSpacing: CGFloat = 12

        /// Height of the bar above the page: navigation, breadcrumb, actions.
        /// A common value is 42 on macOS and 38 elsewhere.
        static let topBarHeight: CGFloat = 42
        /// A 17-point glyph with 6 points of padding on each side.
        static let iconButtonSide: CGFloat = 29
        static let iconButtonSpacing: CGFloat = 4
        /// Gap between the last navigation button and the breadcrumb.
        static let breadcrumbLeadingGap: CGFloat = 24
        /// The trailing cluster sits further from its edge than the navigation
        /// buttons do from theirs: the leading edge butts up against the
        /// sidebar, the trailing one against the screen.
        static let topBarTrailingInset: CGFloat = 14

        /// The window's own corner, for anything drawn against the window
        /// edge. Measured off this build's window on macOS 26 by capturing
        /// it with its alpha and fitting the opaque boundary: a continuous
        /// curve of this radius matches to within a fifth of a pixel, a
        /// circular arc of any radius does not. There is no API for it.
        static let windowCornerRadius: CGFloat = 12.5

        /// One approach derives this from the window radius and the gutter:
        /// `max(5, (10 - 8/2) x 1.3)` = 7.8, drawn as a superellipse. AppKit's
        /// `.continuous` corner curve is the same shape, so the number carries
        /// over directly rather than being converted to a plain-round 6.
        static let contentCornerRadius: CGFloat = 8
        /// The card is inset by the same gutter on all four edges.
        ///
        /// A zero top margin on the page wrapper is common elsewhere, and
        /// copying that number directly was a mistake here: in that layout
        /// the toolbar is a separate row *above* the wrapper, so the window's
        /// top edge shows chrome. Our card carries its own toolbar inside it,
        /// so a zero top margin puts the card itself against the window edge
        /// while the other three sides float, which reads as a missing gap
        /// rather than as a design.
        static let contentTopInset: CGFloat = elementSeparation
    }

    // MARK: - Fonts

    enum Fonts {
        /// Tab titles, the breadcrumb, the profile label -- one size for every
        /// piece of sidebar and top-bar text, which is why the chrome reads
        /// as one surface rather than a stack of widgets.
        static var body: NSFont { .systemFont(ofSize: 13) }
        static var emphasis: NSFont { .systemFont(ofSize: 13, weight: .semibold) }
        /// Emoji ignore weight, and at 13pt they sit a shade small next to
        /// 13pt text, so group emoji get their own size.
        static var groupEmoji: NSFont { .systemFont(ofSize: 14) }
        /// The idle badge on a tab row. Smaller than the title and no lighter:
        /// a badge that is both smaller and greyer reads as damage rather than
        /// as a second line of information, and it is already grey.
        static var badge: NSFont { .systemFont(ofSize: 10, weight: .medium) }
    }

    // MARK: - Colours

    enum Colors {
        /// A translucent plate, not the page's colour and not the accent.
        ///
        /// A reference selected pill is `rgba(255,255,255,0.8)` in light and
        /// `rgba(255,255,255,0.18)` in dark, with only a 2-5% accent hint. The
        /// continuity between the selected tab and the page comes from the
        /// shared material behind both, not from painting the row the colour of
        /// the page -- which is what Kylmora did before, and which makes the row
        /// fight whatever site happens to be open.
        static var rowSelectedFill: NSColor {
            NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(white: 1, alpha: isDark ? 0.18 : 0.8)
            }
        }
        static var rowHoverFill: NSColor { .quaternaryLabelColor }
        /// The plate behind a folder and its children: a step lighter than
        /// the sidebar, so the folder reads as one block, and lighter still
        /// than a hovered or selected pill, so those still show on top of it.
        static var folderPlateFill: NSColor {
            NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return isDark ? NSColor(white: 1, alpha: 0.07) : NSColor(white: 0, alpha: 0.05)
            }
        }
        /// Fill behind a pinned tile, and behind the page container.
        static var tileFill: NSColor { .quaternaryLabelColor }
        static var tileHoverFill: NSColor { .tertiaryLabelColor }
        /// The dashed outline of the empty pinned slot.
        static var emptySlotStroke: NSColor { .tertiaryLabelColor }
        static var pageFill: NSColor { .textBackgroundColor }

        static var primaryText: NSColor { .labelColor }
        static var secondaryText: NSColor { .secondaryLabelColor }
        static var tertiaryText: NSColor { .tertiaryLabelColor }

        /// Near-full contrast for the current space and a clearly visible grey
        /// for the others: a dot the user cannot see is not an indicator.
        static var pageDotActive: NSColor { .labelColor }
        static var pageDotInactive: NSColor { .tertiaryLabelColor }
    }
}
