import AppKit

/// The sidebar's top strip: the space the traffic lights float over, plus the
/// space's name sitting inline beside them.
///
/// The window has no titlebar (`fullSizeContentView`), so the traffic lights
/// are drawn over whatever is at the top-left of the content view. Nothing here
/// may be placed in `trafficLightWidth`, and nothing here is opaque to drags:
/// the view is transparent and does not implement `mouseDown`, so a titlebar
/// drag view sitting behind it still moves the window.
@MainActor
final class SidebarHeaderView: NSView {
    /// The space label. Pull-down rather than plain text because the identity
    /// a page loads under must be visible *and* changeable in one place.
    let spaceButton = MenuLabelButton()

    private let trailingStack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        trailingStack.orientation = .horizontal
        trailingStack.spacing = Style.Metrics.iconButtonSpacing
        trailingStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(spaceButton)
        addSubview(trailingStack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Style.Metrics.titlebarHeight),
            spaceButton.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: Style.Metrics.trafficLightWidth
            ),
            spaceButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            spaceButton.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingStack.leadingAnchor,
                constant: -Style.Metrics.iconButtonSpacing
            ),
            trailingStack.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -Style.Metrics.sidebarInset
            ),
            trailingStack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("SidebarHeaderView is created in code only")
    }

    /// Buttons on the trailing end of the strip. Empty is a valid state.
    func setActions(_ actions: [TopBarAction]) {
        for view in trailingStack.arrangedSubviews {
            trailingStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for action in actions {
            trailingStack.addArrangedSubview(
                IconButton(symbolName: action.symbolName, label: action.label, onClick: action.handler)
            )
        }
    }
}

/// A text button that pops up a menu under itself.
///
/// `NSPopUpButton` in pull-down mode would do this, but it insists on a bezel,
/// a chevron and a first item used as the title -- three things that have to be
/// fought rather than configured. Drawing the label and calling
/// `NSMenu.popUp(positioning:)` is shorter than the fight.
@MainActor
final class MenuLabelButton: NSView {
    /// The menu shown on click. `nil` makes the button inert but still legible,
    /// which is right for a build that has no spaces to choose between.
    var menuProvider: (() -> NSMenu?)?

    private let label = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?
    private var highlight: RowHighlight?
    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            highlight?.apply(
                isHovered && menuProvider != nil ? .hover : .rest,
                appearance: effectiveAppearance
            )
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        if let layer { highlight = RowHighlight(in: layer, depth: .flat) }

        label.font = Style.Fonts.title
        label.textColor = Style.Colors.primaryText
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        label.setAccessibilityElement(false)
        label.translatesAutoresizingMaskIntoConstraints = false
        // The name yields before the sidebar does.
        //
        // It truncates, but truncating is not the same as being willing to:
        // at the default resistance the label still *asks* for its full width,
        // and that ask travels up to the split view, which widens the sidebar
        // to grant it. Switching to a space with a longer name therefore shoved
        // the divider out -- "Read Later BF9059" wanted 240 points where
        // "Studio" wanted 216 -- and switching away left it there. Walking
        // through eleven spaces, the sidebar visibly grew at two of them.
        //
        // Lowered on both: the label is what has the intrinsic width, and this
        // view is what passes it on.
        //
        // Below `.defaultLow`, not at it. The split view holds the sidebar at
        // `.defaultLow` too, so leaving the name there left the two asks tied
        // at 250 and the solver free to satisfy either -- the same tie as the
        // Settings pane's gutter. It happened to come out right while the Now
        // Playing card was quietly holding the sidebar at 169 whatever the
        // name said; with the card no longer doing that, a long name took the
        // width again. One step above nothing, so the name always yields.
        for view in [label, self] as [NSView] {
            view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            view.setContentHuggingPriority(.init(1), for: .horizontal)
        }
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3)
        ])

        setAccessibilityRole(.popUpButton)
        // A role alone does not make an `NSView` an element; without this the
        // button, and so the whole space menu, is invisible to VoiceOver.
        setAccessibilityElement(true)
    }

    required init?(coder: NSCoder) {
        fatalError("MenuLabelButton is created in code only")
    }

    func show(title: String, accessibilityLabel: String, tooltip: String?) {
        label.stringValue = title
        setAccessibilityLabel(accessibilityLabel)
        setAccessibilityValue(title)
        toolTip = tooltip
    }

    override func layout() {
        super.layout()
        highlight?.layout(bounds, in: bounds.height, flipped: isFlipped, radius: 7, scale: highlightScale)
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

    /// The squeeze the header gives under a click. See `SpringPress`.
    private lazy var press = SpringPress(view: self)

    override func mouseDown(with event: NSEvent) {
        // Flicked before the menu opens rather than held through it: a menu
        // runs its own event loop, so a held press would stay squeezed for as
        // long as the menu is on screen.
        if acceptsSpringPress { press.flick() }
        presentMenu()
    }

    override func accessibilityPerformPress() -> Bool {
        presentMenu()
        return true
    }

    private func presentMenu() {
        guard let menu = menuProvider?() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 2), in: self)
    }
}
