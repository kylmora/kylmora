import AppKit

/// A row in the sidebar list that performs an action rather than naming a page.
///
/// "+ New Tab" sits at the end of the tab list, styled as a row rather
/// than as a button parked beside the list. Reusing the group header for it
/// would have been quicker and wrong: that view is a disclosure triangle, and
/// announcing a button as one misleads anyone using VoiceOver.
@MainActor
final class ActionRowView: NSView {
    var onPress: (() -> Void)?

    private let glyph = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        glyph.imageScaling = .scaleProportionallyDown
        glyph.contentTintColor = Style.Colors.secondaryText
        glyph.setAccessibilityElement(false)
        glyph.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = Style.Fonts.body
        titleLabel.textColor = Style.Colors.secondaryText
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.usesSingleLineMode = true
        titleLabel.setAccessibilityElement(false)

        let stack = NSStackView(views: [glyph, titleLabel])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Style.Metrics.groupHeaderHeight),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            glyph.widthAnchor.constraint(equalToConstant: Style.Metrics.smallGlyphSide),
            glyph.heightAnchor.constraint(equalToConstant: Style.Metrics.smallGlyphSide)
        ])

        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) {
        fatalError("ActionRowView is created in code only")
    }

    func show(symbolName: String, title: String) {
        glyph.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        titleLabel.stringValue = title
        toolTip = title
        setAccessibilityLabel(title)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isHovered else { return }
        let pill = bounds.insetBy(dx: 0, dy: (bounds.height - Style.Metrics.rowPillHeight) / 2)
        let path = NSBezierPath(roundedRect: pill,
                                xRadius: Style.Metrics.rowCornerRadius,
                                yRadius: Style.Metrics.rowCornerRadius)
        Style.Colors.rowHoverFill.setFill()
        path.fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingArea = installHoverTracking(replacing: trackingArea)
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) { onPress?() }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}
