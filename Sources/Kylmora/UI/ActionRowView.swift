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
    private var highlight: RowHighlight?
    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            highlight?.apply(isHovered ? .hover : .rest, appearance: effectiveAppearance)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        if let layer { highlight = RowHighlight(in: layer, depth: .flat) }

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
        stack.spacing = Style.Metrics.rowContentSpacing
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        // Laid out on exactly the grid a tab row uses: the glyph occupies a
        // favicon-sized slot starting at the pill's content inset, and the
        // title follows it at the row's own content spacing. Before this the
        // row had its own numbers, so "New Tab" sat five points left of every
        // title above it -- one of those misalignments nobody can name but
        // everybody sees.
        let contentInset = (Style.Metrics.rowHeight - Style.Metrics.rowPillHeight) / 2
            + Style.Metrics.rowContentInset
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Style.Metrics.groupHeaderHeight),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: contentInset),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -contentInset),
            glyph.widthAnchor.constraint(equalToConstant: Style.Metrics.faviconSide),
            glyph.heightAnchor.constraint(equalToConstant: Style.Metrics.faviconSide)
        ])

        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) {
        fatalError("ActionRowView is created in code only")
    }

    func show(symbolName: String, title: String) {
        glyph.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        titleLabel.stringValue = title
        toolTip = title
        setAccessibilityLabel(title)
    }

    override func layout() {
        super.layout()
        let pill = bounds.insetBy(dx: 0, dy: (bounds.height - Style.Metrics.rowPillHeight) / 2)
        highlight?.layout(
            pill,
            in: bounds.height,
            flipped: isFlipped,
            radius: Style.Metrics.rowCornerRadius,
            scale: highlightScale
        )
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
    override func mouseDown(with event: NSEvent) { onPress?() }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}
