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

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: side),
            heightAnchor.constraint(equalToConstant: side),
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor)
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
        toolTip = label
        setAccessibilityLabel(label)
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

    /// A missed `mouseExited` -- the app deactivating with the pointer over
    /// the button, an overlay opening under it -- would leave the highlight
    /// painted with nothing hovering. The pointer's real position settles it.
    private var isPointerInside: Bool {
        guard let window else { return false }
        return bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
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

    @objc private func fire() {
        onClick?()
    }
}
