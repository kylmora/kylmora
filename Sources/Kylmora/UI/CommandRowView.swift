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
    private let shortcutLabel = NSTextField(labelWithString: "")
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

        shortcutLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        shortcutLabel.alignment = .right
        shortcutLabel.cell?.usesSingleLineMode = true
        shortcutLabel.setAccessibilityElement(false)
        shortcutLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        shortcutLabel.setContentHuggingPriority(.required, for: .horizontal)
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false

        let labels = NSStackView(views: [titleLabel, subtitleLabel])
        labels.orientation = .horizontal
        labels.alignment = .lastBaseline
        labels.spacing = CommandBarMetrics.rowLabelSpacing
        labels.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(labels)
        addSubview(shortcutLabel)

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
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcutLabel.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -CommandBarMetrics.rowInset
            ),
            shortcutLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcutLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: labels.trailingAnchor,
                constant: Style.Metrics.rowContentSpacing
            ),
            labels.trailingAnchor.constraint(
                lessThanOrEqualTo: shortcutLabel.leadingAnchor,
                constant: -Style.Metrics.rowContentSpacing
            )
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
        if let shortcut = result.shortcut, !shortcut.isEmpty {
            shortcutLabel.stringValue = shortcut
            shortcutLabel.isHidden = false
            setAccessibilityLabel("\(result.title), \(result.subtitle), shortcut \(shortcut)")
        } else {
            shortcutLabel.stringValue = ""
            shortcutLabel.isHidden = true
            setAccessibilityLabel("\(result.title), \(result.subtitle)")
        }
    }

    /// A selected row is filled with the system's selection colour, so its text
    /// has to move to the colour that is legible on it. Both are semantic, so
    /// this is also what makes the row correct in light and dark.
    private func applySelectionColours() {
        titleLabel.textColor = isSelected ? .alternateSelectedControlTextColor : Style.Colors.primaryText
        subtitleLabel.textColor = isSelected ? .alternateSelectedControlTextColor : Style.Colors.secondaryText
        shortcutLabel.textColor = isSelected ? .alternateSelectedControlTextColor : Style.Colors.tertiaryText
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
        trackingArea = installHoverTracking(replacing: trackingArea)
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?()
    }

    /// The squeeze the row gives under a click. See `SpringPress`.
    ///
    /// This row is one of the few that acts on `mouseUp`, so it can hold the
    /// squeeze for as long as the button is actually held rather than flicking
    /// on a fixed clock.
    private lazy var press = SpringPress(view: self)

    override func mouseDown(with event: NSEvent) {
        if acceptsSpringPress { press.down() }
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        press.up()
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}
