import AppKit

/// Toast metrics, kept here rather than in `Style`.
///
/// These are fixed values, exactly as `Style`'s are, but nothing outside this
/// folder draws a toast, and a number that only one view uses does not earn a
/// place in the shared table.
enum ToastMetrics {
    /// A toast is pinned to one height on macOS -- min and max are the same
    /// value -- so a one-line message and a message with a button are the same
    /// object moving, never two differently sized things.
    static let height: CGFloat = 48
    static let padding: CGFloat = 8
    static let cornerRadius: CGFloat = 14
    /// Between the icon, the message and the button, and also between the
    /// toast and the edge it sits against.
    static let spacing: CGFloat = 8
    static let edgeOffset: CGFloat = 8
    static let iconSide: CGFloat = 16

    static let buttonHeight: CGFloat = 28
    static let buttonCornerRadius: CGFloat = 10
    static let buttonHorizontalPadding: CGFloat = 8

    /// CSS `0 0 22px 2px`. Core Animation's `shadowRadius` is half the CSS blur
    /// and has no spread at all, so the spread is folded into the radius: the
    /// result matches at a glance, which is all a shadow this soft can claim.
    static let shadowRadius: CGFloat = 12

    static var font: NSFont { .systemFont(ofSize: 14, weight: .semibold) }
}

/// The toast itself: icon, message, optional button.
///
/// Clicking anywhere that is not the button dismisses -- there is no close
/// glyph, since a 48-point bar that disappears in two seconds does not have
/// room for one. Hovering pauses the countdown, which is what makes a button
/// on a two-second notification reachable at all.
@MainActor
final class ToastView: NSView {
    private let backdrop = NSVisualEffectView()
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var actionButton: ToastActionButton?
    private var trackingArea: NSTrackingArea?

    private let onAction: () -> Void
    private let onDismiss: () -> Void
    private let onHoverChange: (Bool) -> Void

    init(
        toast: Toast,
        onAction: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        onHoverChange: @escaping (Bool) -> Void
    ) {
        self.onAction = onAction
        self.onDismiss = onDismiss
        self.onHoverChange = onHoverChange
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.shadowOffset = .zero
        layer?.shadowRadius = ToastMetrics.shadowRadius

        backdrop.material = .hudWindow
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = ToastMetrics.cornerRadius
        backdrop.layer?.cornerCurve = .continuous
        backdrop.layer?.masksToBounds = true
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)

        iconView.image = NSImage(systemSymbolName: toast.symbolName, accessibilityDescription: nil)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: ToastMetrics.iconSide, weight: .semibold)
        iconView.contentTintColor = .labelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false

        label.stringValue = toast.message
        label.font = ToastMetrics.font
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [iconView, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = ToastMetrics.spacing
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        if let action = toast.action {
            let button = ToastActionButton(title: action.title) { [weak self] in self?.onAction() }
            row.addArrangedSubview(button)
            actionButton = button
        }

        // The message is the only thing that may be compressed: an icon that
        // shrinks is unreadable and a button that shrinks is unhittable.
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        actionButton?.setContentCompressionResistancePriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: ToastMetrics.height),

            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),

            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ToastMetrics.padding),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ToastMetrics.padding),
            row.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        setAccessibilityRole(.group)
        setAccessibilityLabel(toast.message)
        updateShadow()
    }

    required init?(coder: NSCoder) {
        fatalError("ToastView is created in code only")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateShadow()
    }

    /// The shadow is four times as strong in the dark, because a dark toast on
    /// a dark page has no contrast edge of its own to separate it from what is
    /// behind it.
    private func updateShadow() {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = isDark ? 0.4 : 0.1
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingArea = installHoverTracking(replacing: trackingArea)
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange(false) }

    /// The squeeze the toast gives under a click. See `SpringPress`.
    private lazy var press = SpringPress(view: self)

    override func mouseDown(with event: NSEvent) {
        if acceptsSpringPress { press.flick() }
        onDismiss()
    }
}

/// The one button a toast may carry.
///
/// A custom draw rather than a bezel style because none of AppKit's bezels is
/// 28 points tall with a 10-point radius, and a toast that mixes its own
/// geometry with the system's reads as two things stuck together.
@MainActor
private final class ToastActionButton: NSButton {
    private let onClick: () -> Void
    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }
    private var trackingArea: NSTrackingArea?

    init(title: String, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)

        self.title = title
        isBordered = false
        bezelStyle = .accessoryBarAction
        font = ToastMetrics.font
        contentTintColor = .labelColor
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: ToastMetrics.font, .foregroundColor: NSColor.labelColor]
        )
        target = self
        action = #selector(fire)
        setAccessibilityLabel(title)

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: ToastMetrics.buttonHeight)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("ToastActionButton is created in code only")
    }

    /// The button's horizontal padding, expressed the way AppKit sizes a button.
    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        return NSSize(
            width: base.width + ToastMetrics.buttonHorizontalPadding * 2,
            height: ToastMetrics.buttonHeight
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        (isHovered ? NSColor.tertiaryLabelColor : NSColor.quaternaryLabelColor).setFill()
        let path = NSBezierPath(
            roundedRect: bounds,
            xRadius: ToastMetrics.buttonCornerRadius,
            yRadius: ToastMetrics.buttonCornerRadius
        )
        path.fill()
        super.draw(dirtyRect)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingArea = installHoverTracking(replacing: trackingArea)
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    /// The squeeze the button gives under a click. See `SpringPress`.
    private lazy var press = SpringPress(view: self)

    /// Held across `NSButton`'s own tracking loop, as `IconButton` does.
    override func mouseDown(with event: NSEvent) {
        guard acceptsSpringPress else {
            super.mouseDown(with: event)
            return
        }
        press.down()
        super.mouseDown(with: event)
        press.up()
    }

    @objc private func fire() { onClick() }
}
