import AppKit

/// Sizes the floating sidebar plate needs that no existing metric covers.
///
/// They live here rather than in `Style` only because compact mode is not
/// allowed to edit that file yet. Nothing else should read them.
enum CompactMetrics {
    /// The plate's lift off the page.
    static let plateShadowRadius: CGFloat = 18
    static let plateShadowOffset = CGSize(width: 0, height: -6)
    static let plateShadowOpacity: Float = 0.28
    /// `native-inner-radius` minus the no-padding fix: the plate is rounder
    /// than the page card because it is smaller and floats.
    static let plateCornerRadius: CGFloat = 12
    /// The 1-point inset highlight that separates the plate from a dark page.
    static let plateBorderWidth: CGFloat = 1
    static let plateBorderOpacity: CGFloat = 0.15
}

/// The floating sidebar: a plate laid over the page that slides off the window
/// edge and comes back on hover.
///
/// It is a view rather than an `NSPanel` child window. A panel would give a
/// real shadow over the web view for free, but it also gets its own key-window
/// and first-responder handling, and the sidebar has a table view and a text
/// field in it -- the panel would have to be made key to type in, which would
/// visibly deactivate the browser window every time the sidebar was hovered.
///
/// Hover is an `NSTrackingArea` **and** the dragging-destination protocol,
/// because during a drag AppKit stops sending mouse-tracking messages. Dragging
/// a tab towards a hidden sidebar has to reveal it or the drag has nowhere to
/// land, and that is the one hover trigger a tracking area can never deliver.
@MainActor
final class CompactSidebarOverlay: NSView {

    /// Told when the pointer or a drag enters and leaves the plate.
    ///
    /// Closures rather than a delegate protocol: there is exactly one owner and
    /// the calls carry no data to speak of.
    var onHoverBegan: ((_ isDrag: Bool) -> Void)?
    var onHoverEnded: ((_ isDrag: Bool) -> Void)?

    private let plate = NSVisualEffectView()
    private var edge: CompactSidebarEdge
    private var edgeConstraint: NSLayoutConstraint?
    private var widthConstraint: NSLayoutConstraint?
    private var trackingArea: NSTrackingArea?
    private var pushOut: CGFloat = 0
    private var content: NSView?

    init(edge: CompactSidebarEdge) {
        self.edge = edge
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        // A plate that is normally absent and only exists in compact mode,
        // because only in compact mode is there a page behind the sidebar for
        // it to sit on.
        plate.material = .sidebar
        plate.blendingMode = .withinWindow
        plate.state = .followsWindowActiveState
        plate.wantsLayer = true
        plate.layer?.cornerRadius = CompactMetrics.plateCornerRadius
        plate.layer?.cornerCurve = .continuous
        plate.layer?.masksToBounds = true
        plate.layer?.borderWidth = CompactMetrics.plateBorderWidth
        plate.translatesAutoresizingMaskIntoConstraints = false
        addSubview(plate)

        // The shadow goes on the container and the corner clip on the plate:
        // a layer cannot both mask its bounds and cast a shadow outside them.
        layer?.shadowRadius = CompactMetrics.plateShadowRadius
        layer?.shadowOffset = CompactMetrics.plateShadowOffset
        layer?.shadowOpacity = CompactMetrics.plateShadowOpacity
        layer?.shadowColor = NSColor.black.cgColor

        NSLayoutConstraint.activate([
            plate.topAnchor.constraint(equalTo: topAnchor),
            plate.leadingAnchor.constraint(equalTo: leadingAnchor),
            plate.trailingAnchor.constraint(equalTo: trailingAnchor),
            plate.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        registerForDraggedTypes([.string, .URL, .fileURL])
        updateBorderColor()
    }

    required init?(coder: NSCoder) {
        fatalError("CompactSidebarOverlay is created in code only")
    }

    /// Updates the docked edge of the sidebar.
    func setEdge(_ newEdge: CompactSidebarEdge) {
        guard edge != newEdge else { return }
        edge = newEdge
        if let container = superview {
            edgeConstraint?.isActive = false
            let newConstraint: NSLayoutConstraint = switch newEdge {
            case .leading: leadingAnchor.constraint(equalTo: container.leadingAnchor)
            case .trailing: trailingAnchor.constraint(equalTo: container.trailingAnchor)
            }
            newConstraint.constant = newEdge == .leading ? -pushOut : pushOut
            newConstraint.isActive = true
            edgeConstraint = newConstraint
            container.layoutSubtreeIfNeeded()
        }
    }

    /// Lays the plate over `container`, inset by the float on three edges.
    ///
    /// The float is applied here rather than by the caller because it is also
    /// what the hidden and revealed offsets are measured against; splitting the
    /// two would let them drift apart by a few points and leave a sliver of
    /// plate visible when it is meant to be gone.
    func install(in container: NSView, float: CGFloat) {
        container.addSubview(self, positioned: .above, relativeTo: nil)

        let edgeConstraint: NSLayoutConstraint = switch edge {
        case .leading: leadingAnchor.constraint(equalTo: container.leadingAnchor)
        case .trailing: trailingAnchor.constraint(equalTo: container.trailingAnchor)
        }
        let widthConstraint = widthAnchor.constraint(equalToConstant: 0)
        self.edgeConstraint = edgeConstraint
        self.widthConstraint = widthConstraint

        NSLayoutConstraint.activate([
            edgeConstraint,
            widthConstraint,
            topAnchor.constraint(equalTo: container.topAnchor, constant: float / 2),
            container.bottomAnchor.constraint(equalTo: bottomAnchor, constant: float)
        ])
    }

    /// Puts the sidebar's own view inside the plate.
    func setContent(_ view: NSView?) {
        content?.removeFromSuperview()
        content = view
        guard let view else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        plate.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: plate.topAnchor),
            view.leadingAnchor.constraint(equalTo: plate.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: plate.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: plate.bottomAnchor)
        ])
    }

    func setWidth(_ width: CGFloat) {
        widthConstraint?.constant = width
    }

    /// Slides the plate to `newPushOut` points outside the window edge.
    ///
    /// The sequence is deliberate and is the whole flicker-avoidance
    /// mechanism: settle the constraint to its final value with implicit
    /// animation switched off, then play the movement as a layer animation
    /// that is removed when it finishes. Animating the constraint instead
    /// leaves the layer one frame behind the layout at the end, and the plate
    /// jumps the last few points when control returns to Auto Layout.
    func setPushOut(_ newPushOut: CGFloat, transition: CompactTransition) {
        let previous = pushOut
        pushOut = newPushOut
        // When docked on the leading edge, pushing out of the window means moving left (-newPushOut).
        // When docked on the trailing edge, pushing out means moving right (+newPushOut).
        edgeConstraint?.constant = edge == .leading ? -newPushOut : newPushOut

        guard transition != .immediate, previous != newPushOut, let layer else {
            superview?.layoutSubtreeIfNeeded()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            superview?.layoutSubtreeIfNeeded()
        }

        // Where the plate was, expressed as an offset from where it now is.
        let travel = newPushOut - previous
        let start = edge == .leading ? travel : -travel
        layer.add(Self.slide(from: start, transition: transition), forKey: "compactSlide")
    }

    /// The movement animation for a transition.
    ///
    /// The reveal curve overshoots, so it cannot be a `CABasicAnimation` with a
    /// timing function -- a bezier cannot leave the interval between its
    /// endpoints. It gets the sampled table instead; the other three curves are
    /// ordinary and get the cheap animation.
    private static func slide(from start: CGFloat, transition: CompactTransition) -> CAAnimation {
        let keyPath = "transform.translation.x"
        if let timing = transition.curve.mediaTimingFunction {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = start
            animation.toValue = 0
            animation.duration = transition.duration
            animation.timingFunction = timing
            return animation
        }
        let samples = CompactRevealCurve.samples()
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = samples.map { start * (1 - $0) }
        animation.keyTimes = (0..<samples.count).map {
            NSNumber(value: Double($0) / Double(samples.count - 1))
        }
        animation.duration = transition.duration
        animation.calculationMode = .linear
        return animation
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        // `.activeInKeyWindow` and not `.activeInActiveApp`: a hover over a
        // background window should not reveal chrome the user cannot use.
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverBegan?(false) }
    override func mouseExited(with event: NSEvent) { onHoverEnded?(false) }

    /// Whether the pointer is genuinely inside the plate right now.
    ///
    /// The re-check the leave path needs: AppKit delivers a mouse-exited when a
    /// drag session begins even though the pointer has not moved, and acting on
    /// it collapses the sidebar out from under the tab being dragged.
    var containsPointer: Bool {
        guard let window, window.isKeyWindow else { return false }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(point)
    }

    // MARK: - Drag hover

    /// Reveals on drag but never accepts the drop. The plate is a container:
    /// whatever inside it wants the drop registers for it itself, and an
    /// ancestor that claimed the drag would take it away from them.
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        onHoverBegan?(true)
        return []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onHoverEnded?(true)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        onHoverEnded?(true)
    }

    // MARK: - Appearance

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorderColor()
    }

    private func updateBorderColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            plate.layer?.borderColor = NSColor.white
                .withAlphaComponent(CompactMetrics.plateBorderOpacity).cgColor
        }
    }
}
