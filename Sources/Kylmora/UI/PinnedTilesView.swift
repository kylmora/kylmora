import AppKit

/// One pinned shortcut: a site, and the name it is announced by.
///
/// The tile carries the site's address rather than a picture of it, because
/// the picture is a favicon and Kylmora already has one place that turns an
/// address into a favicon. `url` is optional only so that a pin with an
/// address nothing can be fetched from still renders -- as the globe
/// `FaviconImageView` shows, never as a guess at the site's branding.
struct PinnedTile {
    let id: String
    let title: String
    let url: URL?
    /// Whether this shortcut is the page currently on screen. Only the active
    /// tile wears its brand colours; the rest stay neutral, so a strip of
    /// shortcuts reads as one thing with a current item rather than as a row of
    /// competing logos.
    let isActive: Bool

    init(id: String, title: String, url: URL? = nil, isActive: Bool = false) {
        self.id = id
        self.title = title
        self.url = url
        self.isActive = isActive
    }
}

/// The row of shortcut tiles below the traffic lights.
///
/// With no pins at all the strip shows a single dashed slot inviting the first
/// one, so an empty band never renders. That slot is dropped the moment the
/// first pin lands: once there is a shortcut to click, the "add one" placeholder
/// is just noise, and a tab's Pin command is the way to add more.
@MainActor
final class PinnedTilesView: NSView {
    /// The dashed slot was clicked.
    var onAdd: (() -> Void)?
    /// A tile was clicked, identified by `PinnedTile.id`.
    var onSelect: ((String) -> Void)?
    /// A tile asked to be unpinned, identified by `PinnedTile.id`.
    var onRemove: ((String) -> Void)?

    private var tileViews: [PinnedTileView] = []
    private let emptySlot = EmptyTileView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        emptySlot.onClick = { [weak self] in self?.onAdd?() }
        addSubview(emptySlot)

        setAccessibilityRole(.group)
        setAccessibilityLabel("Pinned shortcuts")
        setAccessibilityElement(true)
    }

    required init?(coder: NSCoder) {
        fatalError("PinnedTilesView is created in code only")
    }

    /// Number of tiles currently shown, not counting the dashed slot. Exists
    /// for the layout tests, which otherwise have no way to see inside.
    private(set) var tileCount = 0

    /// - Parameter isPrivate: whether the space the pins belong to is private. It
    ///   reaches the favicon layer, which writes nothing to disk for a private
    ///   one. The default is the private answer rather than the common one: a
    ///   caller that has not said which kind of space this is must not have its pins
    ///   recorded on disk on the strength of a convenient default.
    func show(_ tiles: [PinnedTile], isPrivate: Bool = true) {
        for view in tileViews { view.removeFromSuperview() }
        tileViews = tiles.map { tile in
            let view = PinnedTileView(tile: tile, isPrivate: isPrivate)
            view.onClick = { [weak self] in self?.onSelect?(tile.id) }
            view.onRemove = { [weak self] in self?.onRemove?(tile.id) }
            return view
        }
        // Inserted below the dashed slot so the subview order matches the order
        // they are read in: tiles first, the slot last.
        for view in tileViews { addSubview(view, positioned: .below, relativeTo: emptySlot) }
        // The dashed slot is the empty state, not a permanent "add" button: it
        // shows only until the first pin exists.
        emptySlot.isHidden = !tiles.isEmpty
        tileCount = tiles.count
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    // MARK: - Layout

    /// Rows are numbered from the top, so the strip has to be too. Without
    /// this the first row is drawn at the bottom and the tiles read backwards.
    override var isFlipped: Bool { true }

    /// Laid out by hand rather than by a stack view, because the strip has to
    /// wrap: a stack is one line, and the tiles need to reflow into as many
    /// rows as the sidebar's width needs. Every tile in a row is the same
    /// width and the row fills the strip, so dragging the sidebar resizes them
    /// rather than leaving a ragged gap.
    override func layout() {
        super.layout()
        // Once there are tiles, the dashed slot is gone, so it drops out of the
        // grid too and the tiles fill the strip without a trailing blank cell.
        let items = tileViews.map { $0 as NSView } + (tileViews.isEmpty ? [emptySlot] : [])
        let plan = TileGrid.plan(itemCount: items.count, availableWidth: bounds.width)

        // The number of rows is only knowable once the width is, and the width
        // is only known here. Asking for a new intrinsic height when the two
        // disagree is what lets the strip grow a second row; the comparison is
        // what stops it asking on every pass.
        if abs(plan.height - bounds.height) > 0.5 {
            invalidateIntrinsicContentSize()
        }

        for (index, view) in items.enumerated() {
            let column = index % plan.columns
            let row = index / plan.columns
            let x = CGFloat(column) * (plan.tileWidth + Style.Metrics.tileSpacing)
            let y = CGFloat(row) * (Style.Metrics.tileHeight + Style.Metrics.tileSpacing)
            view.frame = NSRect(
                x: x,
                y: y,
                width: plan.tileWidth,
                height: Style.Metrics.tileHeight
            )
        }
    }

    override var intrinsicContentSize: NSSize {
        // Matches `layout`'s item count: the dashed slot counts only while it is
        // the empty state, so a strip with tiles is sized for the tiles alone.
        let itemCount = tileViews.isEmpty ? 1 : tileViews.count
        let plan = TileGrid.plan(itemCount: itemCount, availableWidth: bounds.width)
        return NSSize(width: NSView.noIntrinsicMetric, height: plan.height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        // A narrower strip may need another row, and the height it reports has
        // to change with it or the row below overlaps.
        if widthChanged { invalidateIntrinsicContentSize() }
    }
}

/// How many columns fit, how wide each is, and how tall the result is.
///
/// Separated from the view so the wrapping rule is a test rather than something
/// only a screenshot can confirm.
enum TileGrid {
    struct Plan: Equatable {
        var columns: Int
        var tileWidth: CGFloat
        var rows: Int
        var height: CGFloat
    }

    /// Below this a tile is too narrow to read as one, so the strip wraps
    /// instead of shrinking further.
    static let minimumTileWidth: CGFloat = 45

    /// And above this a tile stops being a tile.
    ///
    /// Without a ceiling the strip divided its whole width between however
    /// many shortcuts there were, so two pinned sites became two lozenges half
    /// a sidebar wide each: the same layout that looks right with six looked
    /// absurd with two, and the tiles changed size every time one was added.
    /// A shortcut is a fixed-size thing that there happen to be some number
    /// of, so the row fills up from the left and stops.
    static let maximumTileWidth: CGFloat = Style.Metrics.tileWidth

    static func plan(itemCount: Int, availableWidth: CGFloat) -> Plan {
        let spacing = Style.Metrics.tileSpacing
        let count = max(itemCount, 1)
        guard availableWidth > 0 else {
            return Plan(columns: 1, tileWidth: minimumTileWidth, rows: count,
                        height: CGFloat(count) * Style.Metrics.tileHeight
                            + CGFloat(count - 1) * spacing)
        }

        let fitting = Int((availableWidth + spacing) / (minimumTileWidth + spacing))
        // Never more columns than there are tiles, or the last row stretches a
        // single tile across the whole strip.
        let columns = max(1, min(count, fitting))
        let even = (availableWidth - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let width = min(even, maximumTileWidth)
        let rows = Int(ceil(Double(count) / Double(columns)))
        let height = CGFloat(rows) * Style.Metrics.tileHeight
            + CGFloat(rows - 1) * spacing
        return Plan(columns: columns, tileWidth: width, rows: rows, height: height)
    }
}

// MARK: - Tiles

/// A single filled tile. Private because nothing outside the strip should be
/// able to place one on its own and get the spacing wrong.
@MainActor
private final class PinnedTileView: NSView {
    var onClick: (() -> Void)?
    /// A right-click on the tile asks to unpin it.
    var onRemove: (() -> Void)?

    /// The same view the sidebar rows use, which is the whole point: a pinned
    /// site has no web view to ask for its declared icons, and that is a case
    /// `FaviconImageView` and the service behind it already handle by falling
    /// back to the `/favicon.ico` convention. Re-deriving the cache-hit,
    /// fetch and placeholder handling here would be a second fetcher for the
    /// sake of a tile.
    private let icon = FaviconImageView()
    /// The brand ring. A conic gradient masked to the tile's outline, so the
    /// colours run around the edge rather than across it.
    private let ring = CAGradientLayer()
    private let ringMask = CAShapeLayer()
    private var trackingArea: NSTrackingArea?
    private var highlight: RowHighlight?
    private var isHovered = false {
        didSet { if isHovered != oldValue { updateHighlight() } }
    }

    private let isActive: Bool

    init(tile: PinnedTile, isPrivate: Bool) {
        self.isActive = tile.isActive
        super.init(frame: .zero)
        // The strip sets this view's frame directly, so it is laid out by
        // frame rather than by constraints.
        translatesAutoresizingMaskIntoConstraints = true

        wantsLayer = true
        if let layer { highlight = RowHighlight(in: layer) }
        ring.type = .conic
        ring.startPoint = CGPoint(x: 0.5, y: 0.5)
        ring.endPoint = CGPoint(x: 0.5, y: 0)
        ringMask.fillColor = NSColor.clear.cgColor
        ringMask.strokeColor = NSColor.black.cgColor
        ringMask.lineWidth = Self.ringWidth
        ring.mask = ringMask
        layer?.addSublayer(ring)
        applyRing(for: nil)

        addSubview(icon)
        // The icon arrives asynchronously, so the ring is coloured when it does
        // rather than once at build time.
        icon.onImageChanged = { [weak self] image in self?.applyRing(for: image) }
        updateHighlight()
        if let url = tile.url {
            icon.show(for: url, in: nil, isPrivate: isPrivate)
        }

        toolTip = tile.title
        setAccessibilityRole(.button)
        setAccessibilityLabel(tile.title)
        setAccessibilityElement(true)

        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("PinnedTileView is created in code only")
    }

    /// Thin enough to read as an outline rather than a frame, at the tile size
    /// the strip draws.
    private static let ringWidth: CGFloat = 2

    /// The brand ring, and only on the tile whose page is in front.
    ///
    /// Every tile used to carry one -- the inactive ones in a neutral grey at
    /// 0.45 -- on the reasoning that a shared shape makes a strip read as one
    /// thing. In practice it did the opposite: six grey outlines around six
    /// grey boxes is six competing rectangles, and the one tile that mattered
    /// was distinguished only by the hue of its outline. A ring nobody else
    /// has is a far stronger signal than a ring everybody has in a different
    /// colour, and the strip reads as a row of icons rather than a row of
    /// frames.
    private func applyRing(for image: NSImage?) {
        guard isActive else {
            ring.isHidden = true
            return
        }
        ring.isHidden = false
        ring.colors = BrandPalette.ringColors(for: image).map(\.cgColor)
        ring.opacity = 1
        needsLayout = true
    }

    private func updateHighlight() {
        highlight?.apply(
            isActive ? .selected : (isHovered ? .hover : .rest),
            appearance: effectiveAppearance
        )
    }

    override func layout() {
        super.layout()
        highlight?.layout(
            bounds, in: bounds.height, flipped: isFlipped,
            radius: Style.Metrics.tileCornerRadius, scale: highlightScale
        )
        // No implicit animation: the tiles are re-laid out on every sidebar
        // drag, and a ring that eases into place on each frame smears.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds
        ringMask.frame = bounds
        ringMask.path = CGPath(
            roundedRect: bounds.insetBy(dx: Self.ringWidth / 2, dy: Self.ringWidth / 2),
            cornerWidth: Style.Metrics.tileCornerRadius,
            cornerHeight: Style.Metrics.tileCornerRadius,
            transform: nil
        )
        CATransaction.commit()
    }

    /// The resting fill, under the highlight. Drawn rather than layered so the
    /// tile always has a body even before it is hovered or made active.
    override func draw(_ dirtyRect: NSRect) {
        Style.Colors.tileFill.setFill()
        NSBezierPath(
            roundedRect: bounds,
            xRadius: Style.Metrics.tileCornerRadius,
            yRadius: Style.Metrics.tileCornerRadius
        ).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        highlight?.refresh(appearance: effectiveAppearance)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingArea = installHoverTracking(replacing: trackingArea)
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    /// The squeeze the tile gives under a click. See `SpringPress`.
    private lazy var press = SpringPress(view: self)

    override func mouseDown(with event: NSEvent) {
        if acceptsSpringPress { press.flick() }
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    /// A tile is pinned from a tab's menu but has nowhere else to be unpinned
    /// (the tab left the list when it became a tile), so a right-click on the
    /// tile is the way back off it.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let unpin = NSMenuItem(title: "Unpin", action: #selector(removeFromMenu), keyEquivalent: "")
        unpin.target = self
        unpin.image = NSImage(systemSymbolName: "pin.slash", accessibilityDescription: nil)
        menu.addItem(unpin)
        return menu
    }

    @objc private func removeFromMenu() { onRemove?() }
}

/// The dashed slot at the end of the strip.
@MainActor
private final class EmptyTileView: NSView {
    var onClick: (() -> Void)?

    private let icon = NSImageView()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // The strip sets this view's frame directly, so it is laid out by
        // frame rather than by constraints.
        translatesAutoresizingMaskIntoConstraints = true

        icon.image = NSImage(systemSymbolName: "pin", accessibilityDescription: nil)
        icon.contentTintColor = Style.Colors.tertiaryText
        icon.imageScaling = .scaleProportionallyDown
        icon.setAccessibilityElement(false)
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        toolTip = "Pin a Shortcut"
        setAccessibilityRole(.button)
        setAccessibilityLabel("Pin a Shortcut")
        setAccessibilityElement(true)

        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: Style.Metrics.smallGlyphSide + 4),
            icon.heightAnchor.constraint(equalToConstant: Style.Metrics.smallGlyphSide + 4)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("EmptyTileView is created in code only")
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            Style.Colors.tileFill.setFill()
            NSBezierPath(
                roundedRect: bounds,
                xRadius: Style.Metrics.tileCornerRadius,
                yRadius: Style.Metrics.tileCornerRadius
            ).fill()
        }
        // Inset by half the line width so the stroke lands inside the tile's
        // own rectangle and the dashes line up with the filled tiles beside it.
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: Style.Metrics.tileCornerRadius,
            yRadius: Style.Metrics.tileCornerRadius
        )
        path.lineWidth = 1
        path.setLineDash([3, 3], count: 2, phase: 0)
        Style.Colors.emptySlotStroke.setStroke()
        path.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingArea = installHoverTracking(replacing: trackingArea)
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    /// The squeeze the tile gives under a click. See `SpringPress`.
    private lazy var press = SpringPress(view: self)

    override func mouseDown(with event: NSEvent) {
        if acceptsSpringPress { press.flick() }
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}
