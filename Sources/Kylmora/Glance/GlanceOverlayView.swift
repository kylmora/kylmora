import AppKit

/// The floating panel: a dimmed backdrop, a rounded shadowed card holding the
/// page, a rail of buttons, and the one piece of chrome that says what the page
/// inside actually is.
///
/// The card is laid out by hand rather than with constraints because its frame
/// is what the fly-out animates; an autolayout frame animated behind
/// `NSAnimationContext` fights the constraint solver on every frame and the
/// panel lands in the wrong place.
@MainActor
final class GlanceOverlayView: NSView {
    var onClose: (() -> Void)?
    var onPromote: (() -> Void)?
    var onBackdropClick: (() -> Void)?

    private let shadowHost = NSView()
    private let card = NSView()
    /// The dim behind the card. A view of its own rather than this view's
    /// layer: opacity on the overlay's layer applies to the whole subtree, so
    /// the card and the page inside it would be dimmed to the same 30% as
    /// the backdrop, with the owner page showing through them.
    private let backdrop = NSView()
    private let addressPill = GlanceAddressPill()
    private let rail = NSStackView()
    private let closeButton: GlanceRailButton
    private let promoteButton: GlanceRailButton
    private let confirmationHint = GlanceHintPill(text: "Press Escape again to close")
    private var page: NSView?

    /// Set while the fly-out or the fly-back is running, so `layout()` leaves
    /// the card's frame alone instead of snapping it back to rest.
    private var isAnimatingCard = false

    /// Runs the completion when the animation's time is up.
    ///
    /// `NSAnimationContext`'s own completion handler is `@Sendable`, and this
    /// class is main-actor isolated, so nothing that needs `self` can be handed
    /// to it without weakening the isolation. Waiting out the duration instead
    /// gives the same callback with one extra property worth having: a
    /// CoreAnimation completion that is dropped -- which is what happens when a
    /// view is removed mid-flight -- can no longer strand the state machine in
    /// `.opening` with every dismissal refused.
    private var cardAnimation: Task<Void, Never>?

    override init(frame frameRect: NSRect) {
        closeButton = GlanceRailButton(symbolName: "xmark", label: "Close Glance")
        promoteButton = GlanceRailButton(
            symbolName: "arrow.up.left.and.arrow.down.right",
            label: "Open Glance as a Tab"
        )
        super.init(frame: frameRect)

        wantsLayer = true
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor.black.cgColor
        backdrop.layer?.opacity = 0
        backdrop.frame = bounds
        backdrop.autoresizingMask = [.width, .height]
        addSubview(backdrop)

        buildCard()
        buildRail()

        closeButton.onClick = { [weak self] in self?.onClose?() }
        promoteButton.onClick = { [weak self] in self?.onPromote?() }
    }

    required init?(coder: NSCoder) {
        fatalError("GlanceOverlayView is created in code only")
    }

    private func buildCard() {
        shadowHost.wantsLayer = true
        if let layer = shadowHost.layer {
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = GlanceGeometry.shadowOpacity
            layer.shadowOffset = GlanceGeometry.shadowOffset
            layer.shadowRadius = GlanceGeometry.shadowBlur / 2
        }
        addSubview(shadowHost)

        card.wantsLayer = true
        card.layer?.cornerRadius = GlanceGeometry.cornerRadius
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        card.layer?.backgroundColor = Style.Colors.pageFill.cgColor
        card.autoresizingMask = [.width, .height]
        shadowHost.addSubview(card)

        addressPill.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(addressPill)
        confirmationHint.translatesAutoresizingMaskIntoConstraints = false
        confirmationHint.isHidden = true
        card.addSubview(confirmationHint)

        NSLayoutConstraint.activate([
            addressPill.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            addressPill.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            addressPill.leadingAnchor.constraint(
                greaterThanOrEqualTo: card.leadingAnchor,
                constant: GlanceGeometry.railWidth
            ),
            confirmationHint.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            confirmationHint.centerXAnchor.constraint(equalTo: card.centerXAnchor)
        ])
    }

    private func buildRail() {
        rail.orientation = .vertical
        rail.alignment = .centerX
        rail.spacing = GlanceGeometry.railSpacing
        rail.setViews([closeButton, promoteButton], in: .top)
        addSubview(rail)
    }

    /// Puts the live page inside the card, *below* the address pill rather
    /// than under it. A header band costs 36 points of page and buys the one
    /// property the pill exists for: chrome the page cannot be drawn over.
    func setPage(_ view: NSView) {
        page?.removeFromSuperview()
        page = view
        view.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(view, positioned: .below, relativeTo: addressPill)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: addressPill.bottomAnchor, constant: 6),
            view.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])
    }

    /// Hands the page back without disturbing it, for promotion. The web view
    /// keeps its content process, its scroll position and its history; only its
    /// place in the view hierarchy changes.
    func releasePage() -> NSView? {
        guard let page else { return nil }
        page.removeFromSuperview()
        self.page = nil
        return page
    }

    func showAddress(_ url: URL) {
        addressPill.show(url)
    }

    /// The armed state of the Escape guard: the close button goes loud and the
    /// hint says what a second press will do. A button that changes colour with
    /// no explanation is a puzzle, not a warning.
    func setConfirmationArmed(_ armed: Bool) {
        closeButton.isArmed = armed
        confirmationHint.isHidden = !armed
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let layout = GlanceGeometry.layout(in: bounds)
        if !isAnimatingCard {
            shadowHost.frame = layout.card
            updateShadowPath()
        }
        rail.frame = layout.rail
    }

    private func updateShadowPath() {
        shadowHost.layer?.shadowPath = CGPath(
            roundedRect: shadowHost.bounds,
            cornerWidth: GlanceGeometry.cornerRadius,
            cornerHeight: GlanceGeometry.cornerRadius,
            transform: nil
        )
    }

    // MARK: - Animation

    /// The fly-out: the card scales up from the clicked element while the
    /// backdrop dims in.
    func present(from origin: CGRect, animated: Bool, completion: @escaping () -> Void) {
        let target = GlanceGeometry.layout(in: bounds).card
        shadowHost.frame = origin
        rail.alphaValue = 0
        card.alphaValue = 0

        animateCard(to: target, curve: GlanceGeometry.openCurve, animated: animated) { [weak self] in
            self?.updateShadowPath()
            completion()
        }
        fade(layerOpacity: GlanceGeometry.backdropOpacity, animated: animated)
        fade(rail, to: 1, animated: animated)
        // The page itself fades in a touch behind the card so the first frame
        // of a half-laid-out document is never what flies across the screen.
        fade(card, to: 1, animated: animated)
    }

    /// The fly-back, with no overshoot.
    func dismiss(to origin: CGRect, animated: Bool, completion: @escaping () -> Void) {
        setConfirmationArmed(false)
        animateCard(to: origin, curve: GlanceGeometry.closeCurve, animated: animated, completion: completion)
        fade(layerOpacity: 0, animated: animated)
        fade(rail, to: 0, animated: animated)
        fade(card, to: 0, animated: animated)
    }

    /// Promotion: the card grows to fill the whole content pane, which is where
    /// the page is about to live as an ordinary tab.
    func growToFull(animated: Bool, completion: @escaping () -> Void) {
        setConfirmationArmed(false)
        animateCard(to: bounds, curve: GlanceGeometry.closeCurve, animated: animated, completion: completion)
        fade(layerOpacity: 0, animated: animated)
        fade(rail, to: 0, animated: animated)
        fade(addressPill, to: 0, animated: animated)
    }

    private func animateCard(
        to frame: CGRect,
        curve: (Float, Float, Float, Float),
        animated: Bool,
        completion: @escaping () -> Void
    ) {
        guard animated else {
            shadowHost.frame = frame
            updateShadowPath()
            completion()
            return
        }
        isAnimatingCard = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = GlanceGeometry.animationDuration
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: curve.0, curve.1, curve.2, curve.3
            )
            context.allowsImplicitAnimation = true
            shadowHost.animator().frame = frame
        }
        cardAnimation?.cancel()
        cardAnimation = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(GlanceGeometry.animationDuration))
            guard !Task.isCancelled else { return }
            self?.isAnimatingCard = false
            self?.updateShadowPath()
            completion()
        }
    }

    private func fade(_ view: NSView, to alpha: CGFloat, animated: Bool) {
        guard animated else { view.alphaValue = alpha; return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = GlanceGeometry.animationDuration
            view.animator().alphaValue = alpha
        }
    }

    /// How dark the backdrop currently is, for tests.
    var backdropOpacity: Float { backdrop.layer?.opacity ?? 0 }

    private func fade(layerOpacity opacity: Float, animated: Bool) {
        guard let dim = backdrop.layer else { return }
        guard animated else { dim.opacity = opacity; return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = dim.presentation()?.opacity ?? dim.opacity
        animation.toValue = opacity
        animation.duration = GlanceGeometry.animationDuration
        dim.opacity = opacity
        dim.add(animation, forKey: "glance.dim")
    }

    // MARK: - Hit testing

    /// A click on the dimmed area is a dismissal. Clicks on the card reach the
    /// page, because the card and its subviews win the hit test first.
    override func mouseDown(with event: NSEvent) {
        onBackdropClick?()
    }

    /// Swallows scrolls over the dim so a glance cannot be scrolled out from
    /// under by wheeling on the page behind it.
    override func scrollWheel(with event: NSEvent) {}
}

/// One round rail button: a circular plate so the glyph stays legible over
/// whatever the dimmed page happens to be, with a soft shadow under it.
@MainActor
private final class GlanceRailButton: NSView {
    var onClick: (() -> Void)? {
        didSet { button.setClickHandler(onClick) }
    }

    var isArmed = false {
        didSet { if isArmed != oldValue { updateAppearance() } }
    }

    private let button: IconButton

    init(symbolName: String, label: String) {
        button = IconButton(symbolName: symbolName, label: label, side: GlanceGeometry.railButtonSide)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = GlanceGeometry.railButtonSide / 2
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.07
        layer?.shadowOffset = .zero
        layer?.shadowRadius = 6

        addSubview(button)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: GlanceGeometry.railButtonSide),
            heightAnchor.constraint(equalToConstant: GlanceGeometry.railButtonSide),
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("GlanceRailButton is created in code only")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (isArmed ? NSColor.systemOrange : NSColor.controlBackgroundColor).cgColor
        }
        button.contentTintColor = isArmed ? .white : Style.Colors.primaryText
    }
}

/// The transient line of text under an armed close button.
@MainActor
private final class GlanceHintPill: NSView {
    init(text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous

        let label = NSTextField(labelWithString: text)
        label.font = Style.Fonts.body
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("GlanceHintPill is created in code only")
    }
}

/// The address of the page inside the glance, drawn by the browser over the
/// top of it.
///
/// This is the whole answer to "how does the user know what they are looking
/// at". The window's own address bar keeps naming the committed page
/// underneath, so without this the glanced page would be the one thing on
/// screen with no address anywhere. It shows the *committed*
/// address for the same reason the omnibox does, and it is chrome: no page
/// script can reach it, move it or cover it.
@MainActor
private final class GlanceAddressPill: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous

        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.font = Style.Fonts.body
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 11),
            icon.heightAnchor.constraint(equalToConstant: 11),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        updateBackground()
    }

    required init?(coder: NSCoder) {
        fatalError("GlanceAddressPill is created in code only")
    }

    func show(_ url: URL) {
        let isSecure = url.scheme?.lowercased() == "https"
        let symbol = isSecure ? "lock.fill" : "exclamationmark.triangle.fill"
        icon.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: isSecure ? "Secure connection" : "Not a secure connection"
        )
        icon.contentTintColor = isSecure ? Style.Colors.secondaryText : .systemOrange
        label.stringValue = AddressFormatter.display(url)
        label.textColor = Style.Colors.primaryText
        setAccessibilityLabel("Glance showing \(label.stringValue)")
        toolTip = url.absoluteString
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Style.Colors.rowSelectedFill.cgColor
        }
    }
}
