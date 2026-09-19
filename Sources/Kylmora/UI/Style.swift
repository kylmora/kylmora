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

        /// Resting sidebar width.
        ///
        /// Twenty per cent under the 306 this was measured at, at the user's
        /// request. The page is what the window is for, and 306 points of
        /// chrome beside it claimed more of the window than a list of tab
        /// titles needs. Titles truncate sooner at this width and the pinned
        /// strip fits fewer tiles across before it wraps, which is the trade
        /// being made rather than an oversight.
        ///
        /// Still comfortably above `sidebarMinWidth`, so nothing that degrades
        /// gracefully further down has to start doing so here.
        ///
        /// This is where every window opens, not only a first launch: an
        /// autosaved divider position outranks a split item's own thickness
        /// bounds, so `BrowserWindowController.buildSplitView` sets the divider
        /// from this number explicitly each time it builds one.
        static let sidebarWidth: CGFloat = 245
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
        ///
        /// Eight, matching `elementSeparation`, so the gutter inside the
        /// sidebar is the same measure as the gutter between the sidebar and
        /// the page. At six the pills cleared the window edge by less than the
        /// page card did, and the two gutters disagreeing by two points is
        /// exactly the kind of thing that reads as "off" without being
        /// nameable.
        static let sidebarInset: CGFloat = elementSeparation

        /// One device pixel on a Retina display. Hairlines are drawn at this
        /// rather than at 1, which on a 2x screen is two pixels and reads as a
        /// drawn border rather than as an edge.
        static let hairline: CGFloat = 0.5

        /// Height of the strip the traffic lights float over. The sidebar owns
        /// it because the window has no titlebar of its own.
        static let titlebarHeight: CGFloat = 53
        /// Space the traffic lights need before anything else may be placed on
        /// the titlebar row.
        static let trafficLightWidth: CGFloat = 78

        static let tileWidth: CGFloat = 68
        /// A common tile height is 46. Ours is smaller so more shortcuts fit
        /// across the strip before it wraps, which is the whole point of a row
        /// of them -- but not as small as the 32 it was: a 16-point icon in a
        /// 32-point tile leaves eight points above and below, which is too
        /// tight to read as a button and is why the strip looked like a row of
        /// swatches rather than a row of shortcuts.
        static let tileHeight: CGFloat = 36
        static let tileSpacing: CGFloat = 4
        /// Scaled with the tile: this proportion reads as a rounded square,
        /// which is what a shortcut to an app-like site should be. Much larger
        /// and it becomes a lozenge and stops rhyming with the favicon in it.
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
        /// How far the selected row's plate blurs below itself. Small: the
        /// plate is meant to sit a millimetre off the material, not to hover
        /// over it. A larger radius on a 26-point pill puts more shadow on
        /// screen than pill and reads as a glow.
        static let rowShadowRadius: CGFloat = 3
        /// And how far it is offset downwards, so the light reads as coming
        /// from above.
        static let rowShadowOffset: CGFloat = 1
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
        /// the pills inside it, as a container should be. The gap between this
        /// and `rowCornerRadius` is what says which shape is inside which.
        static let folderPlateCornerRadius: CGFloat = 12
        /// Clear space above a folder's plate. It is added to the header's row,
        /// so two folders in a row, or a folder after loose tabs, are separated
        /// by more than the pill margin alone.
        ///
        /// A card needs more clear space around it than the rows inside it have
        /// between them, or the eye cannot tell which gaps are joins and which
        /// are breaks. At six -- barely more than the three points a pill keeps
        /// -- two folders stacked on each other read as one striped block.
        static let folderPlateGap: CGFloat = 10
        /// Clear space inside a folder's plate, under its last row. It is added
        /// to that row's height, so the card's bottom edge clears the last pill
        /// by a visible margin -- a pill whose bottom runs along the plate's
        /// bottom edge reads as the plate's own outline rather than as a row
        /// inside it.
        ///
        /// Not the same as `folderPlateGap`, which is the space *outside* the
        /// card: the padding within a container is smaller than the gap between
        /// containers, or the grouping inverts and the cards read as separated
        /// rows rather than as rows inside cards.
        static let folderPlateBottomPadding: CGFloat = 5
        /// Disclosure chevron and the small glyphs in the sidebar footer.
        static let smallGlyphSide: CGFloat = 11

        /// The workspace indicator row, which is what the footer is.
        static let footerHeight: CGFloat = 40
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
        /// The count pill on an icon button. Tall enough for a nine-point
        /// digit with a point of air above and below, and never narrower than
        /// it is tall, so a single digit comes out as a circle rather than as
        /// a squeezed oval.
        static let countBadgeHeight: CGFloat = 13
        /// Either side of the digits, inside the pill.
        static let countBadgePadding: CGFloat = 3
        /// Gap between the last navigation button and the breadcrumb.
        static let breadcrumbLeadingGap: CGFloat = 24
        /// How wide the address field is allowed to get.
        ///
        /// An address bar as wide as the window is a browser-chrome habit, not
        /// a good idea: addresses are rarely longer than this, the extra width
        /// is never used, and it puts the one field in the chrome a user aims
        /// at somewhere different on every window size. Capped, it is a fixed
        /// target in a fixed place.
        static let addressFieldMaxWidth: CGFloat = 620
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
        /// How far the page card's shadow spreads, and how far it is pushed
        /// down. Larger than a row's, because the card is the largest surface
        /// in the window and a shadow has to scale with what casts it: the
        /// same three points that lift a 26-point pill are invisible under a
        /// thousand-point sheet.
        static let cardShadowRadius: CGFloat = 10
        static let cardShadowOffset: CGFloat = 2

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

        /// The space's name, at the top of the sidebar. The one piece of
        /// chrome text that is allowed to be larger than the body: it names
        /// the whole window, and everything under it is a member of it.
        static var title: NSFont { .systemFont(ofSize: 14, weight: .semibold) }

        /// A folder's name.
        ///
        /// Smaller than the tabs inside it, not larger. A folder header is a
        /// label for a group, not an item competing with the items -- the same
        /// reasoning behind every section header in macOS. Set at the same
        /// weight as the body text at a smaller size, and drawn in the
        /// secondary colour, it reads as a caption over the rows rather than
        /// as the loudest thing on the screen, which is what a bold 13-point
        /// header on 13-point rows was.
        static var groupHeader: NSFont { .systemFont(ofSize: 11.5, weight: .semibold) }
        /// Emoji ignore weight, and at 13pt they sit a shade small next to
        /// 13pt text, so group emoji get their own size.
        static var groupEmoji: NSFont { .systemFont(ofSize: 12) }
        /// A second line under a label: the sentence that explains a setting.
        /// Smaller than the body and always drawn in the secondary colour, so
        /// it reads as an aside rather than as more of the same.
        static var note: NSFont { .systemFont(ofSize: 11) }

        /// The idle badge on a tab row. Smaller than the title and no lighter:
        /// a badge that is both smaller and greyer reads as damage rather than
        /// as a second line of information, and it is already grey.
        static var badge: NSFont { .systemFont(ofSize: 10, weight: .medium) }

        /// The count on a footer button. A point smaller than the row badge
        /// and a weight heavier: it is drawn reversed out of a small pill,
        /// where a regular weight closes up and stops being a number.
        static var countBadge: NSFont { .systemFont(ofSize: 9, weight: .semibold) }
    }

    // MARK: - Colours

    enum Colors {
        /// One appearance-aware colour, given both its coats.
        ///
        /// Every colour below is built from this rather than from a semantic
        /// system colour, because the sidebar is not a system surface: it
        /// carries a space's tint, and `quaternaryLabelColor` over a tinted
        /// material comes out as a grey smear rather than as a highlight. The
        /// pair is stated once and read in both appearances, which is also
        /// what makes light and dark reviewable side by side.
        static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
            NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            }
        }

        /// White at an alpha in light, white at another in dark. Most of the
        /// chrome's surfaces are exactly this: a veil of light over whatever
        /// the material and the space's tint have already put down.
        static func veil(light: CGFloat, dark: CGFloat) -> NSColor {
            dynamic(light: NSColor(white: 1, alpha: light), dark: NSColor(white: 1, alpha: dark))
        }

        /// Ink: black in light, white in dark, each at its own alpha. For the
        /// shadows and hairlines that have to darken a light surface and
        /// lighten a dark one.
        static func ink(light: CGFloat, dark: CGFloat) -> NSColor {
            dynamic(light: NSColor(white: 0, alpha: light), dark: NSColor(white: 1, alpha: dark))
        }

        /// Black at an alpha in light, black at another in dark.
        ///
        /// For shadows, and only for shadows. `ink` inverts with the
        /// appearance, which is right for a hairline -- an edge has to contrast
        /// with the surface it is on -- and badly wrong for a shadow: light
        /// still falls from above in dark mode, so a shadow is still an absence
        /// of light. Drawing one in white put a glowing halo around the
        /// selected row rather than sitting it on the surface.
        static func shade(light: CGFloat, dark: CGFloat) -> NSColor {
            dynamic(light: NSColor(white: 0, alpha: light), dark: NSColor(white: 0, alpha: dark))
        }

        // MARK: Rows

        /// The plate under the selected row.
        ///
        /// Nearly opaque white in light, a thin veil in dark. It is the one
        /// surface in the sidebar that is meant to read as lifted off the
        /// material, so it carries a hairline (`rowSelectedStroke`) and a soft
        /// shadow (`rowSelectedShadow`) as well -- three cues, none of them
        /// loud. A flat fill on its own was what made the selected tab read as
        /// a white blob dropped on the tint.
        static var rowSelectedFill: NSColor { veil(light: 0.92, dark: 0.16) }
        /// The hairline around the selected plate: a shade of the surface it
        /// sits on, not a border colour. It defines the edge at the point the
        /// fill and the tint underneath are closest in value.
        static var rowSelectedStroke: NSColor { ink(light: 0.07, dark: 0.13) }
        /// What the selected plate casts. Deeper in dark, because a dark
        /// surface swallows a shadow that a pale one would show plainly.
        static var rowSelectedShadow: NSColor { shade(light: 0.13, dark: 0.40) }
        /// Hover is a hint, not a selection: a twentieth of an alpha, enough to
        /// confirm the pointer is on the row and no more.
        static var rowHoverFill: NSColor { ink(light: 0.05, dark: 0.07) }

        // MARK: Containers

        /// The plate behind a folder and its children.
        ///
        /// Light in light mode rather than dark: a black veil over a tinted
        /// sidebar reads as dirt, a white one as a recessed card. Faint enough
        /// that a hovered or selected pill still lifts clearly off it.
        static var folderPlateFill: NSColor { veil(light: 0.30, dark: 0.05) }
        /// The hairline around a folder's plate. Without it the plate has no
        /// edge at all in light mode, where its fill and the sidebar are within
        /// a few percent of each other.
        static var folderPlateStroke: NSColor { ink(light: 0.05, dark: 0.07) }

        /// Fill behind a pinned tile.
        static var tileFill: NSColor { veil(light: 0.42, dark: 0.07) }
        static var tileHoverFill: NSColor { veil(light: 0.68, dark: 0.13) }
        /// The dashed outline of the empty pinned slot.
        static var emptySlotStroke: NSColor { ink(light: 0.16, dark: 0.20) }
        /// The hairline every small container in the chrome carries.
        static var hairline: NSColor { ink(light: 0.06, dark: 0.09) }

        /// The resting plate behind the address bar.
        ///
        /// Faint, but present. Plain text floating in the middle of a wide bar
        /// has no shape, so nothing says where to click or how far the field
        /// runs -- and an address is the one thing in the chrome a user reaches
        /// for by aiming rather than by reading. The plate is the shape.
        static var fieldFill: NSColor { ink(light: 0.04, dark: 0.08) }
        static var fieldStroke: NSColor { ink(light: 0.05, dark: 0.07) }

        /// What the page card casts onto the chrome beside it. Weaker than a
        /// row's shadow in absolute terms because it is spread over a much
        /// larger radius, where the same opacity would read as a dark halo.
        static var cardShadow: NSColor { shade(light: 0.10, dark: 0.42) }

        /// The ring around the dots on a favicon's corner.
        ///
        /// Opaque, and neither the window background nor the tint: the ring's
        /// only job is to hold a coloured dot off the icon it overlaps, and it
        /// can only do that if it contrasts with both. A translucent ring picks
        /// up the favicon underneath and stops separating anything.
        static var dotRing: NSColor {
            dynamic(light: .white, dark: NSColor(white: 0.17, alpha: 1))
        }

        static var pageFill: NSColor { .textBackgroundColor }

        /// The plate a panel or popover of Kylmora's own controls is drawn on.
        ///
        /// Opaque. `windowBackgroundColor` rather than a veil: these controls
        /// are drawn against it, and their greys are only legible if what is
        /// behind them is a known value rather than whatever the desktop, the
        /// page or a translucent material happens to put there.
        static var panelSurface: NSColor { .windowBackgroundColor }

        // MARK: Panel controls

        /// The plate behind a control in a panel or sheet -- a text field, a
        /// segmented track, a quiet button.
        ///
        /// `ink`, not `veil`. The rest of the chrome's surfaces are veils
        /// because they sit on a space's tint, where white is what lifts; the
        /// New Space sheet and the group editor sit on the window's own
        /// background, which in light mode is near white. A white veil there is
        /// invisible -- the sheet's fields, toggles and pills drew nothing at
        /// all -- so on a panel it is black that has to do the darkening.
        static var controlFill: NSColor { ink(light: 0.06, dark: 0.07) }
        /// The same plate, under the pointer.
        static var controlHoverFill: NSColor { ink(light: 0.10, dark: 0.14) }
        /// A control that has to read as a shape in its own right rather than
        /// as a recess: an off switch, whose track carries a white knob.
        static var controlTrackFill: NSColor { ink(light: 0.16, dark: 0.16) }
        /// The thumb lifted onto a segmented track: opaque in light, a veil in
        /// dark, the same reading as a selected row but on a surface with no
        /// tint under it.
        static var controlThumbFill: NSColor {
            dynamic(light: .white, dark: NSColor(white: 1, alpha: 0.16))
        }
        /// The ring that holds a chip or knob off the surface behind it, for
        /// when the two are near the same value.
        static var controlRing: NSColor { ink(light: 0.18, dark: 0.30) }

        // MARK: Text

        static var primaryText: NSColor { .labelColor }
        static var secondaryText: NSColor { .secondaryLabelColor }
        static var tertiaryText: NSColor { .tertiaryLabelColor }

        /// Near-full contrast for the current space and a clearly visible grey
        /// for the others: a dot the user cannot see is not an indicator.
        static var pageDotActive: NSColor { .labelColor }
        static var pageDotInactive: NSColor { ink(light: 0.22, dark: 0.26) }

        /// The count pill on the footer's Archive button, and its digits.
        ///
        /// Ink rather than the system accent: the footer is a monochrome strip
        /// sitting on whatever tint the space carries, and an accent-coloured
        /// dot down there reads as an alert -- something is wrong, go and look
        /// -- when all the badge is saying is how many tabs are in a drawer.
        /// Dark-on-light in the light coat and light-on-dark in the dark one,
        /// so the digits stay legible in both.
        static var countBadgeFill: NSColor { ink(light: 0.55, dark: 0.70) }
        static var countBadgeText: NSColor { dynamic(light: .white, dark: .black) }
    }

    // MARK: - Motion

    /// How long the chrome's small state changes take.
    ///
    /// The numbers are short on purpose. A hover that takes a quarter second to
    /// arrive feels laggy, not smooth; the point of animating it at all is that
    /// the highlight appears to grow rather than to blink into existence, and
    /// that reads at well under a tenth of a second. Anything the user is
    /// waiting on (a hover) is faster than anything they have just committed to
    /// (a selection), which can afford to be seen travelling.
    enum Motion {
        /// A hover highlight fading in or out.
        static let hover: CFTimeInterval = 0.09
        /// A selection moving from one row to another.
        static let selection: CFTimeInterval = 0.16

        /// The curve everything in the chrome moves on: quick to leave, gentle
        /// to arrive. `easeOut` alone starts too abruptly at these durations.
        static var curve: CAMediaTimingFunction {
            CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)
        }

        // MARK: Press

        /// How long the squeeze takes to go down.
        ///
        /// A press is the one moment in the interface that is not feedback
        /// about a state change but feedback about a finger, so it has to keep
        /// up with the finger: the surface should already be down by the time
        /// the user notices they have pressed it. The same 90ms a hover takes,
        /// and for the same reason -- anything slower reads as the control
        /// lagging behind the click rather than yielding to it.
        static let pressDown: CFTimeInterval = 0.09

        /// How long the rebound takes to settle.
        ///
        /// Longer than anything else here, because this is the one animation
        /// the user is *meant* to watch: the overshoot is the whole point, and
        /// a bounce that is over in 150ms reads as a glitch rather than as
        /// springiness. This is the perceptual duration -- roughly when the
        /// motion looks finished -- not the settling time, which is longer
        /// because a spring technically never stops.
        static let pressSettle: CFTimeInterval = 0.34

        /// How far past its resting size a released surface swings.
        ///
        /// Core Animation's `bounce` is 0 for a spring that glides to a stop
        /// and 1 for one that barely damps at all. A third is the point where
        /// the overshoot is plainly visible on a 29-point button without the
        /// control wobbling afterwards -- one clear swing past and back, which
        /// is what a physical key does.
        static let pressBounce: Double = 0.34

        /// How many points the longest edge of a pressed surface gives up,
        /// in total across both of its ends.
        ///
        /// A press cannot be a fixed *ratio*, which is the obvious thing to
        /// reach for and is wrong: 0.94 on a 29-point button is a two-point
        /// squeeze, and the same 0.94 on a 250-point tab row is a fifteen-point
        /// lurch. Scaling instead so that the long edge always loses the same
        /// few points makes a button and a row feel like the same material,
        /// which a shared ratio emphatically does not.
        static let pressTravel: CGFloat = 6

        /// The smallest scale a press is allowed to reach.
        ///
        /// `pressTravel` alone would squeeze a 29-point button to 0.79, which
        /// is a cartoon. On anything smaller than about 75 points the floor is
        /// what actually applies, and it is set where the squeeze is still
        /// clearly visible -- a little over two points on an icon button -- and
        /// not yet comic.
        static let pressScaleFloor: CGFloat = 0.92

        /// The scale to squeeze a surface of this size to.
        ///
        /// Derived from the two numbers above rather than stored per control,
        /// so a new button gets the right press without anyone choosing one.
        static func pressScale(for size: CGSize) -> CGFloat {
            let longest = max(size.width, size.height)
            guard longest > 0 else { return pressScaleFloor }
            return max(pressScaleFloor, 1 - pressTravel / longest)
        }

        // MARK: Presence

        /// The size a surface arrives at, and leaves at, when it springs in.
        ///
        /// A flat ratio is right here where it was wrong for a press: a toast
        /// or a card is appearing from nothing rather than yielding under a
        /// finger, so what has to read consistently is the *proportion* it
        /// grows through, not the number of points it travels.
        static let entryScale: CGFloat = 0.94

        /// How long an arrival takes to look finished.
        ///
        /// Longer than a press rebound. A press is answering something the user
        /// just did and must not keep them waiting; an arrival is the surface
        /// introducing itself, and has a moment to do it in.
        static let entrySettle: CFTimeInterval = 0.42

        /// How far an arriving surface overshoots.
        ///
        /// Less bouncy than a press. A control springing under the hand is
        /// playful; a notification that wobbles on its way in is a notification
        /// that is harder to read, and reading it is the entire point.
        static let entryBounce: Double = 0.24

        /// How far a row slides as a list opens a place for it.
        ///
        /// Rows arrive from the leading edge rather than from nowhere, because
        /// a list has a direction and a new row joining it should look like it
        /// came from somewhere. Far enough to read as travel at a glance, and
        /// short enough that a burst of new tabs does not turn the sidebar into
        /// a rolling wave.
        static let entrySlide: CGFloat = 28

        /// How long a surface takes to leave.
        ///
        /// Departures do not spring at all. A spring is anticipation -- it
        /// overshoots because something is arriving -- and a thing on its way
        /// out has nothing to anticipate; bouncing it merely keeps it on screen
        /// after the user is done with it.
        static let exit: CFTimeInterval = 0.14

        /// Whether to move at all. Reduce Motion is a request for state to
        /// change without travelling, which every animated surface here honours
        /// by using a zero duration rather than by skipping the change.
        @MainActor static var isReduced: Bool {
            reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }

        /// The answer the tests pin, when they are checking the motion itself
        /// rather than whether it is wanted. Left `nil` in the app, so the only
        /// thing that ever decides this in a user's hands is the user's own
        /// accessibility setting.
        ///
        /// It exists because the machine otherwise decides: a CI runner is a
        /// headless VM and reports Reduce Motion as on, which would leave the
        /// squeeze -- the one thing those tests are for -- unchecked exactly
        /// where checking it matters most.
        @MainActor static var reduceMotionOverride: Bool?

        /// The duration to actually use, which is none under Reduce Motion.
        @MainActor static func duration(_ base: CFTimeInterval) -> CFTimeInterval {
            isReduced ? 0 : base
        }
    }
}
