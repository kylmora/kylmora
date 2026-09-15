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
        didSet { if isActive != oldValue { needsDisplay = true } }
    }

    private var onClick: (() -> Void)?
    private var trackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
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
        self.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)
        self.imagePosition = .imageOnly
        self.imageScaling = .scaleProportionallyDown
        self.isBordered = false
        self.bezelStyle = .accessoryBarAction
        self.contentTintColor = Style.Colors.secondaryText
        self.toolTip = label
        self.target = self
        self.action = #selector(fire)
        setAccessibilityLabel(label)

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: side),
            heightAnchor.constraint(equalToConstant: side)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("IconButton is created in code only")
    }

    /// Replaces the symbol and every label that describes it at once, so a
    /// button that changes meaning -- reload becoming stop -- can never end up
    /// showing one thing and announcing another.
    func setSymbol(_ symbolName: String, label: String) {
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)
        toolTip = label
        setAccessibilityLabel(label)
    }

    func setClickHandler(_ handler: (() -> Void)?) {
        onClick = handler
    }

    override var isEnabled: Bool {
        didSet {
            contentTintColor = isEnabled ? Style.Colors.secondaryText : Style.Colors.tertiaryText
        }
    }

    /// A missed `mouseExited` -- the app deactivating with the pointer over
    /// the button, an overlay opening under it -- would leave the highlight
    /// painted with nothing hovering. The pointer's real position settles it.
    private var isPointerInside: Bool {
        guard let window else { return false }
        return bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    override func draw(_ dirtyRect: NSRect) {
        // The active fill keeps its shape when the pointer leaves: a button that
        // is on is on, not hovering.
        let fill: NSColor?
        if isActive {
            fill = Style.Colors.rowSelectedFill
        } else if isHovered && isEnabled && isPointerInside {
            fill = Style.Colors.rowHoverFill
        } else {
            fill = nil
        }
        if let fill {
            fill.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingArea = installHoverTracking(replacing: trackingArea)
        // Re-registered on every move or resize, which is also when a stale
        // hover from a missed exit is most likely; resync it from the pointer.
        isHovered = isPointerInside
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    @objc private func fire() {
        onClick?()
    }
}
