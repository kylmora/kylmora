import AppKit

/// The one button in the window we actually want pressed, drawn like it.
///
/// A bezelled `NSButton` is the same grey as every other button on the pane,
/// which is right for "Manage Spaces…" and wrong for the single action the
/// pane exists to invite. This wears the pane's own hue as a fill, which is
/// the loudest thing the window's vocabulary has, and it springs under the
/// press like everything else does.
@MainActor
final class BannerActionButton: NSButton {
    /// The pane's hue. Set by whatever puts the button on a pane, because a
    /// button has no way of knowing which pane it landed on until it is there.
    var tint: NSColor = .controlAccentColor {
        didSet { if tint != oldValue { needsDisplay = true } }
    }

    /// Tall enough to read as a call to action beside a 52-point icon, and
    /// short enough to stay a button rather than become a panel.
    private static let height: CGFloat = 34
    /// Air either side of the title. Generous on purpose: the width of a
    /// button is most of what makes it look pressable.
    private static let horizontalPadding: CGFloat = 18
    private static let cornerRadius: CGFloat = 10

    private var trackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }

    init(title: String, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        bezelStyle = .accessoryBarAction
        target = self
        action = #selector(fire)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) {
        fatalError("BannerActionButton is created in code only")
    }

    private let onClick: () -> Void

    @objc private func fire() { onClick() }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: ceil(attributed().size().width) + Self.horizontalPadding * 2,
            height: Self.height
        )
    }

    /// White on the hue in both appearances. The fill is a saturated colour,
    /// not a surface, so it does not flip with the window's light and dark the
    /// way a plate does -- and label colour over it would be black in light.
    private func attributed() -> NSAttributedString {
        NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        // Lifted, not lightened, under the pointer: a fill this saturated goes
        // muddy when it is blended towards white.
        let fill = isHovered && isEnabled
            ? tint.blended(withFraction: 0.12, of: .white) ?? tint
            : tint
        (isEnabled ? fill : tint.withAlphaComponent(0.4)).setFill()
        NSBezierPath(
            roundedRect: bounds, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius
        ).fill()

        let text = attributed()
        let size = text.size()
        text.draw(at: NSPoint(
            x: ((bounds.width - size.width) / 2).rounded(),
            y: ((bounds.height - size.height) / 2).rounded()
        ))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingArea = installHoverTracking(replacing: trackingArea)
        isHovered = isPointerInside
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    /// The squeeze under the click, the same one every other control gives.
    private lazy var press = SpringPress(view: self)

    /// `NSButton` tracks the mouse inside `super.mouseDown`, which does not
    /// return until the button has been released, so these two lines are the
    /// true edges of the press. See `IconButton`, which does the same.
    override func mouseDown(with event: NSEvent) {
        guard acceptsSpringPress else {
            super.mouseDown(with: event)
            return
        }
        press.down()
        super.mouseDown(with: event)
        press.up()
    }
}

/// The invitation to make Kylmora the default browser, across the top of
/// General.
///
/// It used to be the last row on the pane: a label reading "Kylmora is not
/// your default web browser." and a grey button, under "Quitting", past nine
/// other settings and two separators. The one thing a new browser most needs
/// to ask for was the thing you had to scroll furthest to find, and it was
/// dressed exactly like the settings it was buried among.
///
/// So: the top of the pane, the app's own icon at the size the Dock shows it,
/// a sentence about what changes, and a button wearing the pane's hue.
///
/// And it goes away for good once Kylmora is the default. There is nothing
/// left to ask for at that point, and a banner that stays behind to
/// congratulate itself is one more thing to scroll past every time you open
/// the pane.
@MainActor
final class DefaultBrowserBanner: SettingsPlateView {
    /// Called when the button is pressed. The pane owns what happens next,
    /// because it owns the window the system's confirmation sheet belongs to.
    var onSet: (() -> Void)?

    private let icon = NSImageView(image: NSApp.applicationIconImage)
    private let headline = NSTextField(labelWithString: "Make Kylmora your default browser")
    private let subtitle = NSTextField(wrappingLabelWithString: DefaultBrowserBanner.invitation)
    private lazy var button = BannerActionButton(title: "Set as Default") { [weak self] in
        self?.onSet?()
    }

    /// What actually changes, rather than what the setting is called. "Kylmora
    /// is not your default web browser" states a fact about a checkbox; this
    /// says what the user will notice tomorrow.
    private static let invitation =
        "Links you open from Mail, Messages, Slack and everywhere else will open here."

    /// The icon at the size the Dock draws it. Smaller and it reads as a
    /// toolbar glyph beside the text rather than as the app itself.
    private static let iconSide: CGFloat = 52

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        cornerRadius = Style.SettingsUI.cardRadius
        elevated = true

        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        icon.translatesAutoresizingMaskIntoConstraints = false

        headline.font = .systemFont(ofSize: 16, weight: .semibold)
        headline.textColor = Style.Colors.primaryText

        subtitle.font = Style.Fonts.settingsRow
        subtitle.textColor = Style.Colors.secondaryText

        let words = NSStackView(views: [headline, subtitle])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 3
        words.translatesAutoresizingMaskIntoConstraints = false
        // The sentence wraps rather than pushing the button off the pane when
        // the window is at its narrowest.
        subtitle.setContentCompressionResistancePriority(.init(249), for: .horizontal)

        addSubview(icon)
        addSubview(words)
        addSubview(button)

        let padding = Style.SettingsUI.cardPadding
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: Self.iconSide),
            icon.heightAnchor.constraint(equalToConstant: Self.iconSide),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),

            words.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 14),
            words.centerYAnchor.constraint(equalTo: centerYAnchor),
            words.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -14),

            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),

            // The icon sets the height, and the padding is the same above and
            // below it, so the banner is one shape rather than a stack that
            // happens to be as tall as its tallest piece.
            heightAnchor.constraint(greaterThanOrEqualTo: icon.heightAnchor, constant: padding * 2),
            words.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: padding),
            words.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -padding)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("DefaultBrowserBanner is created in code only")
    }

    /// Says what went wrong in place of the invitation, when the system
    /// refused or the user declined its confirmation.
    func report(_ message: String) {
        subtitle.stringValue = message
    }

    func resetMessage() {
        subtitle.stringValue = Self.invitation
    }

    var isEnabled: Bool {
        get { button.isEnabled }
        set { button.isEnabled = newValue }
    }

    /// The pane's hue reaches the banner only once it is on the pane, so the
    /// fill, the edge and the button are all coloured here rather than at
    /// build time.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyAccent()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAccent()
    }

    private func applyAccent() {
        let accent = settingsAccent ?? .controlAccentColor
        button.tint = accent
        // A wash of the hue rather than the card's own glass. The banner has
        // to be the first thing the eye lands on when the pane opens, and a
        // card that looks like every other card is not that.
        fill = accent.withAlphaComponent(0.12)
        stroke = accent.withAlphaComponent(0.32)
    }
}
