import AppKit

/// A row in one of the settings window's rails: a coloured mark with a glyph in
/// it, a name, a pill that lights under the pointer and fills when it is the
/// chosen one, and a squeeze when it is pressed.
///
/// This was the spine's own private row. The Websites pane has a rail of its
/// own -- Reader Mode, Auto-Play, Page Zoom and the rest -- and it was a plain
/// `NSTableView`: no hover, no press, a tile four points larger than the
/// spine's and a different distance from its label, and AppKit's own selection
/// under it. Two lists side by side in one window, doing the same job, drawn by
/// two different pieces of code and looking it.
///
/// So there is one row now, and both rails build it. Nothing here knows what a
/// pane is: a row is a name, a mark and something that happens when you press
/// it.
@MainActor
final class SettingsRailRow: NSView {
    private let title: String
    private let mark = SettingsPlateView()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    /// A live number at the trailing edge -- a space's memory in the Task
    /// Manager's rail. Hidden unless something sets it, so every rail that does
    /// not want one is unchanged.
    private let detail = NSTextField(labelWithString: "")
    private let onClick: () -> Void
    private var trackingArea: NSTrackingArea?
    private let pill = CALayer()

    var isChosen = false {
        didSet {
            guard isChosen != oldValue else { return }
            apply()
        }
    }
    /// Whether the row is drawing itself as under the pointer.
    var isLit: Bool { isHovered }

    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            apply()
        }
    }

    /// What goes inside a row's coloured mark.
    ///
    /// A pane is always a white SF Symbol. A space is whatever its owner put on
    /// it -- an emoji, a picture, a symbol -- which is the whole point of space
    /// icons, and a rail that redrew them all as the same glyph would be a
    /// third place in the browser where a space does not look like itself.
    enum Mark {
        /// A white SF Symbol on the accent.
        case symbol(String)
        /// A picture drawn as it is: an emoji, or a space's own icon.
        case picture(NSImage)
        /// The coloured tile and nothing on it, for a space that never chose
        /// an icon. Its mark *is* a coloured dot, and drawing that dot on a
        /// tile of the same colour would draw nothing you can see.
        case plain
    }

    /// A row is its name, its mark and what happens when it is pressed --
    /// nothing about panes. The spine builds one per pane; the Websites pane
    /// builds one per category; the Task Manager builds one per space.
    convenience init(title: String, symbolName: String, accent: NSColor, onClick: @escaping () -> Void) {
        self.init(title: title, mark: .symbol(symbolName), accent: accent, onClick: onClick)
    }

    init(title: String, mark markKind: Mark, accent: NSColor, onClick: @escaping () -> Void) {
        self.title = title
        self.onClick = onClick
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.addSublayer(pill)

        // The mark keeps its colour whether the row is chosen or not: it is
        // the thing you learn the pane by, so it must not change under you.
        mark.fill = accent
        mark.cornerRadius = Style.SettingsUI.spineTileRadius
        addSubview(mark)

        switch markKind {
        case .symbol(let name):
            icon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            icon.contentTintColor = .white
        case .picture(let image):
            // No tint: the picture is already whatever the user chose, and
            // painting it white would be the thing this case exists to avoid.
            icon.image = image
        case .plain:
            icon.image = nil
        }
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setAccessibilityElement(false)
        addSubview(icon)

        detail.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        detail.textColor = Style.Colors.tertiaryText
        detail.alignment = .right
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.setAccessibilityElement(false)
        detail.isHidden = true
        detail.setContentHuggingPriority(.required, for: .horizontal)
        detail.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(detail)

        label.stringValue = title
        label.font = Style.Fonts.settingsRow
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityElement(false)
        addSubview(label)

        let inset = Style.SettingsUI.railInset
        let side = Style.SettingsUI.spineTileSide
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Style.SettingsUI.spineRowHeight),
            mark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset + 7),
            mark.centerYAnchor.constraint(equalTo: centerYAnchor),
            mark.widthAnchor.constraint(equalToConstant: side),
            mark.heightAnchor.constraint(equalToConstant: side),
            icon.centerXAnchor.constraint(equalTo: mark.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: mark.centerYAnchor),
            label.leadingAnchor.constraint(
                equalTo: mark.trailingAnchor,
                constant: Style.SettingsUI.spineTileGapToLabel
            ),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: detail.leadingAnchor, constant: -6),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(inset + 8)),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        apply()
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsRailRow is created in code only")
    }

    /// The number at the trailing edge. Nil takes it away again.
    func setDetail(_ text: String?) {
        detail.stringValue = text ?? ""
        detail.isHidden = text == nil
        setAccessibilityLabel(text.map { "\(title), \($0)" } ?? title)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // The shape is set without animation: a pill that eased into place
        // on a window resize would smear along behind the row.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pill.frame = bounds.insetBy(dx: Style.SettingsUI.railInset, dy: 0)
        pill.cornerCurve = .continuous
        pill.cornerRadius = Style.SettingsUI.spineRowRadius
        CATransaction.commit()

        // The colour is. Choosing a pane and pointing at one are both worth
        // seeing happen, and they now travel at the speeds the browser
        // window's rows use rather than blinking on and off.
        var colour: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            colour = isChosen
                ? Style.Colors.settingsRailSelected.cgColor
                : (isHovered ? Style.Colors.settingsRailHover.cgColor : nil)
        }
        let duration = Style.Motion.duration(
            isChosen || wasChosen ? Style.Motion.selection : Style.Motion.hover
        )
        wasChosen = isChosen
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(Style.Motion.curve)
        CATransaction.setDisableActions(duration == 0)
        pill.backgroundColor = colour
        CATransaction.commit()
    }

    /// Whether this row was the chosen one when it last drew, so that
    /// losing the selection travels at the same speed as gaining it.
    private var wasChosen = false

    /// Sized from `layout`, never by asking for a redraw from inside one:
    /// a view that dirties itself while drawing never stops drawing.
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pill.frame = bounds.insetBy(dx: Style.SettingsUI.railInset, dy: 0)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply()
    }

    private func apply() {
        label.textColor = isChosen ? Style.Colors.primaryText : Style.Colors.secondaryText
        label.font = isChosen
            ? .systemFont(ofSize: 13, weight: .semibold)
            : Style.Fonts.settingsRow
        mark.alphaValue = isChosen ? 1 : 0.85
        setAccessibilityValue(isChosen ? "selected" : "")
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingArea = installHoverTracking(replacing: trackingArea)
        refreshHover()
    }

    /// Works out for itself whether the pointer is on this row.
    ///
    /// Enter and exit do not always come in pairs. `activeInActiveApp`
    /// means a row that the pointer leaves while the app is in the
    /// background never hears about it, and a row that moves out from under
    /// the pointer -- the list filtering as you type, or scrolling -- never
    /// hears about that either. Either way the row is left lit, and after a
    /// few app switches half the list looks selected. Asking where the
    /// pointer actually is cannot come adrift that way.
    func refreshHover() {
        guard let window, window.isKeyWindow, NSApp.isActive else {
            isHovered = false
            return
        }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        isHovered = bounds.contains(point) && visibleRect.contains(point)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshHover()
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    /// The squeeze the row gives under a click. See `SpringPress`.
    private lazy var press = SpringPress(view: self)

    override func mouseDown(with event: NSEvent) {
        if acceptsSpringPress { press.flick() }
        onClick()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick()
        return true
    }
}
