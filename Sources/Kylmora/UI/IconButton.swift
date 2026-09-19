import AppKit

/// A square, borderless SF Symbol button with a rounded hover highlight.
///
/// AppKit's borderless `NSButton` gives no hover feedback at all, and its
/// bordered styles draw a bezel that is wrong for chrome that is meant to
/// disappear into the page. Rather than repeat a tracking area and a rounded
/// fill in the top bar, the tile strip and the footer, all three use this.
///
/// It takes a closure instead of a target/action pair so the surrounding views
/// can stay free of the session model.
@MainActor
final class IconButton: NSButton {
    /// Drawn as on. For a button that toggles what the window is showing -- the
    /// sidebar's Archive -- so the state is legible from the button rather than
    /// only from the list it changed.
    var isActive = false {
        didSet { if isActive != oldValue { updateHighlight() } }
    }

    /// The symbol, as a subview rather than as the button cell's own image.
    ///
    /// The highlight behind it is a layer, and a layer added to a view's
    /// backing layer draws *above* whatever that view painted in `draw(_:)` --
    /// so a cell-drawn glyph would sit underneath its own highlight. A subview
    /// has a layer of its own, which stacks above the highlight's, so the two
    /// end up in the order the eye expects.
    private let glyph = NSImageView()
    /// The count in the button's top-trailing corner, hidden while it is zero.
    private let badge = CountBadgeView()
    /// What the button is, without its count. Kept so the tooltip and the
    /// accessibility label can be rebuilt as "Archive (3)" and back again.
    private var label: String
    private var onClick: (() -> Void)?
    private var trackingArea: NSTrackingArea?
    private var highlight: RowHighlight?
    private var isHovered = false {
        didSet { if isHovered != oldValue { updateHighlight() } }
    }

    /// The button's corner. Smaller than a row pill's, because the shape is
    /// square: the same radius that reads as a gently rounded rectangle on a
    /// 200-point pill reads as a blob on a 29-point square.
    private static let cornerRadius: CGFloat = 7

    /// The symbol's point size for a button of a given side.
    ///
    /// Just under half, which leaves a margin of about a quarter of the button
    /// on each side: enough for the hover plate to read as a plate around the
    /// glyph rather than as a box drawn on it, and not so much that the symbol
    /// stops being the thing the eye lands on. Floored, because below about
    /// nine points SF Symbols stop being legible whatever the button is doing.
    static func symbolPointSize(forSide side: CGFloat) -> CGFloat {
        max(9, (side * 0.48).rounded())
    }

    /// `side` is both width and height; the symbol is centred inside it.
    init(
        symbolName: String,
        label: String,
        side: CGFloat = Style.Metrics.iconButtonSide,
        onClick: (() -> Void)? = nil
    ) {
        self.label = label
        self.onClick = onClick
        super.init(frame: .zero)

        self.title = ""
        // The cell draws nothing at all; `glyph` is the button's face.
        self.imagePosition = .noImage
        self.isBordered = false
        self.bezelStyle = .accessoryBarAction
        self.toolTip = label
        self.target = self
        self.action = #selector(fire)
        setAccessibilityLabel(label)

        wantsLayer = true
        if let layer { highlight = RowHighlight(in: layer, depth: .flat) }

        glyph.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)
        // The symbol is sized by its point size rather than by squeezing it
        // into a frame, so the stroke weight stays right at every button size.
        // Scaling a 13-point symbol down into a 6-point box, which sizing by
        // frame amounts to on the smallest buttons, produces a glyph that is
        // both too small to hit and too thin to see.
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: Self.symbolPointSize(forSide: side), weight: .medium
        )
        glyph.imageScaling = .scaleProportionallyDown
        glyph.contentTintColor = Style.Colors.secondaryText
        glyph.setAccessibilityElement(false)
        // The glyph never takes the click: it is the button's face, and a hit
        // landing on it rather than on the button would swallow the press.
        glyph.isEnabled = false
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)

        // Added after the glyph so it draws over it: the pill is meant to
        // overlap the symbol's corner, which is what makes it read as being
        // attached to the button rather than floating beside it.
        badge.isHidden = true
        addSubview(badge)

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: side),
            heightAnchor.constraint(equalToConstant: side),
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Held inside the button rather than hung off its corner. The
            // footer's buttons sit hard against the sidebar's edges, so a pill
            // that overhung would be the first thing lost when the sidebar is
            // dragged narrow -- and the hover plate it sits on is drawn to the
            // button's bounds, so a badge outside them would float free of it.
            badge.topAnchor.constraint(equalTo: topAnchor),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("IconButton is created in code only")
    }

    /// Replaces the symbol and every label that describes it at once, so a
    /// button that changes meaning -- reload becoming stop -- can never end up
    /// showing one thing and announcing another.
    func setSymbol(_ symbolName: String, label: String) {
        glyph.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)
        self.label = label
        toolTip = label
        setAccessibilityLabel(label)
    }

    /// How many things are in the list this button opens. Zero hides the pill
    /// entirely: a badge reading "0" is a worse answer than no badge, because
    /// it draws the eye to say nothing happened.
    ///
    /// The count goes into the tooltip and the accessibility value as well as
    /// onto the face, so it is not something only a sighted user gets. The
    /// value rather than the label, because the label is how the footer finds
    /// its buttons again -- a button that renamed itself to "Archive (3)"
    /// would stop being findable the moment something was archived.
    var badgeCount: Int {
        get { badge.count }
        set {
            guard newValue != badge.count else { return }
            badge.count = newValue
            toolTip = newValue > 0 ? "\(label) (\(newValue))" : label
            setAccessibilityValue(newValue > 0 ? "\(newValue)" : nil)
        }
    }

    func setClickHandler(_ handler: (() -> Void)?) {
        onClick = handler
    }

    override var isEnabled: Bool {
        didSet {
            glyph.contentTintColor = isEnabled ? Style.Colors.secondaryText : Style.Colors.tertiaryText
        }
    }

    /// Kept working for callers that tint the button rather than its glyph.
    override var contentTintColor: NSColor? {
        get { glyph.contentTintColor }
        set { glyph.contentTintColor = newValue }
    }

    override func layout() {
        super.layout()
        highlight?.layout(
            bounds, in: bounds.height, flipped: isFlipped,
            radius: Self.cornerRadius, scale: highlightScale
        )
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        highlight?.refresh(appearance: effectiveAppearance)
    }

    /// The active fill keeps its shape when the pointer leaves: a button that
    /// is on is on, not hovering.
    private func updateHighlight() {
        let state: RowHighlight.State
        if isActive {
            state = .selected
        } else if isHovered && isEnabled && isPointerInside {
            state = .hover
        } else {
            state = .rest
        }
        highlight?.apply(state, appearance: effectiveAppearance)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingArea = installHoverTracking(replacing: trackingArea)
        // Re-registered on every move or resize, which is also when a stale
        // hover from a missed exit is most likely; resync it from the pointer.
        let inside = isPointerInside
        if isHovered != inside {
            isHovered = inside
        } else {
            updateHighlight()
        }
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    /// The squeeze the button gives under a click. See `SpringPress`.
    private lazy var press = SpringPress(view: self)

    /// Held down for exactly as long as the button is.
    ///
    /// `NSButton` tracks the mouse itself, inside `super.mouseDown`, which does
    /// not return until the button has been released and the action sent. That
    /// makes the two lines around it the true edges of the press -- including
    /// the case where the pointer is dragged off the button and back on, which
    /// the cell handles and which nothing here has to know about.
    override func mouseDown(with event: NSEvent) {
        guard acceptsSpringPress else {
            super.mouseDown(with: event)
            return
        }
        press.down()
        super.mouseDown(with: event)
        press.up()
    }

    @objc private func fire() {
        onClick?()
    }
}


/// The small count in the corner of an icon button -- how many tabs are in the
/// archive, from the button that opens it.
///
/// A pill rather than a bare number: at nine points a loose digit dropped on
/// the corner of a symbol reads as part of the symbol, and `archivebox` has
/// enough going on in that corner already.
///
/// Drawn rather than built from a label and a background view, for the same
/// reason `PageDotsView` is: two bezier paths and a string cost less than a
/// text field, its cell and the layer under it, and this one is laid out once
/// and then only ever redrawn with a different number in it.
@MainActor
final class CountBadgeView: NSView {
    /// Above this the badge stops counting and starts saying "a lot". A
    /// three-digit pill is wider than the button it sits on, and nobody
    /// hunting a lost tab needs to know whether it is the 104th or the 140th.
    private static let maximum = 99

    private var text = ""

    var count: Int = 0 {
        didSet {
            guard count != oldValue else { return }
            text = count > Self.maximum ? "\(Self.maximum)+" : "\(count)"
            isHidden = count <= 0
            setAccessibilityValue(text)
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        // The button around it is the control; this is a label on its face, and
        // the button already announces the count in its own label.
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        fatalError("CountBadgeView is created in code only")
    }

    private var attributes: [NSAttributedString.Key: Any] {
        [
            .font: Style.Fonts.countBadge,
            .foregroundColor: Style.Colors.countBadgeText
        ]
    }

    override var intrinsicContentSize: NSSize {
        let height = Style.Metrics.countBadgeHeight
        guard !text.isEmpty else { return NSSize(width: height, height: height) }
        let width = (text as NSString).size(withAttributes: attributes).width
            + Style.Metrics.countBadgePadding * 2
        // Never narrower than it is tall, so "3" is a circle and "12" is a
        // capsule -- the shape grows with the number instead of the number
        // being squeezed into a fixed box.
        return NSSize(width: max(width.rounded(.up), height), height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        let pill = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        Style.Colors.countBadgeFill.setFill()
        pill.fill()

        let string = text as NSString
        let size = string.size(withAttributes: attributes)
        // Centred on the pill rather than on the baseline the font would put
        // it: digits have no descenders, so a baseline-aligned number sits
        // visibly low in a circle this small.
        string.draw(
            at: NSPoint(
                x: (bounds.width - size.width) / 2,
                y: (bounds.height - size.height) / 2
            ),
            withAttributes: attributes
        )
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
