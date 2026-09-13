import AppKit

/// One row of the command bar's result list: symbol, primary label, secondary
/// label.
///
/// Hovering a row *moves the keyboard selection* onto it rather than drawing a
/// second highlight of its own. A launcher has exactly one "this is what Return
/// does" indicator, and two highlights competing to be it is how a list ends up
/// opening something the user was not pointing at.
@MainActor
final class CommandRowView: NSView {
    var onClick: (() -> Void)?
    /// Called when the pointer enters the row; the bar answers by selecting it.
    var onHover: (() -> Void)?

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?

    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            applySelectionColours()
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setAccessibilityElement(false)

        titleLabel.font = Style.Fonts.body
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.usesSingleLineMode = true
        titleLabel.setAccessibilityElement(false)

        subtitleLabel.font = .systemFont(ofSize: CommandBarMetrics.subtitleFontSize)
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.cell?.usesSingleLineMode = true
        subtitleLabel.setAccessibilityElement(false)
        // The address is the row's caption, not its point: it gives way first.
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let labels = NSStackView(views: [titleLabel, subtitleLabel])
        labels.orientation = .horizontal
        labels.alignment = .lastBaseline
        labels.spacing = CommandBarMetrics.rowLabelSpacing
        labels.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(labels)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: CommandBarMetrics.rowHeight),
            iconView.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: CommandBarMetrics.rowInset
            ),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: CommandBarMetrics.rowIconSide),
            iconView.heightAnchor.constraint(equalToConstant: CommandBarMetrics.rowIconSide),
            labels.leadingAnchor.constraint(
                equalTo: iconView.trailingAnchor,
                constant: Style.Metrics.rowContentSpacing
            ),
            labels.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -CommandBarMetrics.rowInset
            ),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        setAccessibilityRole(.button)
        applySelectionColours()
    }

    required init?(coder: NSCoder) {
        fatalError("CommandRowView is created in code only")
    }

    func configure(_ result: CommandResult) {
        iconView.image = NSImage(systemSymbolName: result.symbolName, accessibilityDescription: nil)
        titleLabel.stringValue = result.title
        subtitleLabel.stringValue = result.subtitle
        setAccessibilityLabel("\(result.title), \(result.subtitle)")
    }

    /// A selected row is filled with the system's selection colour, so its text
    /// has to move to the colour that is legible on it. Both are semantic, so
    /// this is also what makes the row correct in light and dark.
    private func applySelectionColours() {
        titleLabel.textColor = isSelected ? .alternateSelectedControlTextColor : Style.Colors.primaryText
        subtitleLabel.textColor = isSelected ? .alternateSelectedControlTextColor : Style.Colors.secondaryText
        iconView.contentTintColor = isSelected ? .alternateSelectedControlTextColor : Style.Colors.secondaryText
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(
            roundedRect: bounds,
            xRadius: CommandBarMetrics.rowCornerRadius,
            yRadius: CommandBarMetrics.rowCornerRadius
        ).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?()
    }

    override func mouseUp(with event: NSEvent) {
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}
