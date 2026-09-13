import AppKit

/// A space's gradient wash, resolved down to what the tint view needs: two hex
/// stops and a direction. Equatable on those, not on resolved colours, so a
/// dynamic wash colour rebuilt each frame does not read as a change.
struct WashGradient: Equatable {
    let startHex: String
    let endHex: String
    let direction: GradientDirection
    /// The space's wash strength (0...1), scaling the stops down from full.
    var opacity: CGFloat = 1
}

/// A flat wash of the active space's colour, laid over the chrome's material.
///
/// A separate view rather than a colour on the material itself, because an
/// `NSVisualEffectView` has no tint: setting a background colour on one either
/// does nothing or replaces the vibrancy outright. Painting over it keeps the
/// material -- and the desktop showing through it, and the way it dims when the
/// window goes inactive -- and only shifts the hue.
///
/// It never takes a click: every control it covers is above it in the view
/// hierarchy, but a hit test that stopped here would still swallow drags on the
/// sidebar's empty space.
///
/// The wash is the layer's background colour rather than a `draw(_:)`, because
/// a space switch moves the colour as well as the content: during a swipe the
/// wash is part-way between two spaces' colours, and on release it has to
/// travel the rest of the way in step with the strip. A layer colour can be
/// set to any point between the two and animated to the end; a drawn fill
/// would need its own timer.
@MainActor
final class TintView: NSView {
    /// The colour to paint, already at wash strength (`SpaceTheme.wash(of:)`).
    /// `nil` paints nothing at all, which is the `neutral` space theme: the
    /// window goes back to plain material rather than to a grey wash.
    var wash: NSColor? {
        didSet {
            guard wash != oldValue else { return }
            show(wash, animatedOver: transitionDuration)
        }
    }

    /// A gradient over the same material, for a space washed with two colours
    /// rather than one. When set it supersedes `wash`: the solid layer goes
    /// clear and the gradient paints instead, cross-fading in on a space
    /// change. Nil goes back to the flat `wash`.
    var gradientWash: WashGradient? {
        didSet {
            guard gradientWash != oldValue else { return }
            applyGradient(animated: transitionDuration > 0)
        }
    }

    /// How long a change of `theme` takes to arrive. Zero, except while a
    /// space switch is animating and the colour has to travel with it.
    var transitionDuration: TimeInterval = 0

    private var gradientLayer: CAGradientLayer?

    private static let colourKey = "kylmora.wash"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("TintView is created in code only")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The wash is a dynamic colour, so light and dark resolve differently and
    /// a layer holds only one of them.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        show(wash, animatedOver: 0)
        if gradientWash != nil { applyGradient(animated: false) }
    }

    /// Part-way between this space's colour and another's, for a strip that
    /// has been dragged part-way towards the other space.
    func blend(toward other: NSColor?, fraction: CGFloat) {
        let mix = max(0, min(1, fraction))
        setColour(Self.mixed(resolve(wash), resolve(other), by: mix), animatedOver: 0)
    }

    /// Finishes at this theme, starting from wherever the wash is now.
    ///
    /// The layer is read for its current colour first, so a release after a
    /// drag carries on from the blend the drag left rather than snapping back
    /// to the old colour and starting again.
    func show(_ target: NSColor?, animatedOver duration: TimeInterval) {
        setColour(resolve(target), animatedOver: duration)
    }

    private func setColour(_ colour: CGColor?, animatedOver duration: TimeInterval) {
        guard let layer else { return }
        // A gradient owns the surface while it is set; the solid layer stays
        // clear under it, so a blend or show during a gradient space is inert.
        guard gradientWash == nil else {
            layer.backgroundColor = nil
            return
        }
        let from = layer.presentation()?.backgroundColor ?? layer.backgroundColor
        layer.removeAnimation(forKey: Self.colourKey)
        // The model value first, so this is where the layer stays afterwards.
        layer.backgroundColor = colour
        guard duration > 0, let from, from != colour else { return }

        let move = CABasicAnimation(keyPath: "backgroundColor")
        move.fromValue = from
        move.toValue = colour
        move.duration = duration
        move.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(move, forKey: Self.colourKey)
    }

    /// Keeps the gradient sublayer covering the view; frame changes must not
    /// animate, or a window resize drags the gradient after the content.
    override func layout() {
        super.layout()
        guard let gradientLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.frame = bounds
        CATransaction.commit()
    }

    /// Shows the gradient over the material and clears the solid layer under it,
    /// or fades the gradient away and lets the solid wash back in.
    private func applyGradient(animated: Bool) {
        guard let layer else { return }
        guard let gradient = gradientWash else {
            gradientLayer?.opacity = 0
            // The solid wash owns the surface again.
            setColour(resolve(wash), animatedOver: animated ? transitionDuration : 0)
            return
        }

        let target = gradientLayer ?? {
            let created = CAGradientLayer()
            created.frame = bounds
            // Below any sublayers a caller might add, but above the solid.
            layer.insertSublayer(created, at: 0)
            gradientLayer = created
            return created
        }()

        // Two stops at wash strength, resolved under this view's appearance so
        // light and dark come out right, the same as the solid wash.
        let start = SpaceTheme.wash(of: NSColor(hexString: gradient.startHex) ?? SpaceTheme.default.color, opacity: gradient.opacity)
        let end = SpaceTheme.wash(of: NSColor(hexString: gradient.endHex) ?? SpaceTheme.default.color, opacity: gradient.opacity)
        let points = gradient.direction.layerPoints
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            target.colors = [start.cgColor, end.cgColor]
            target.startPoint = points.start
            target.endPoint = points.end
            target.frame = bounds
            CATransaction.commit()
        }
        // The solid layer steps aside for the gradient.
        layer.backgroundColor = nil
        if animated, target.opacity < 1 {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = target.opacity
            fade.toValue = 1
            fade.duration = transitionDuration
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            target.add(fade, forKey: "kylmora.washGradient")
        }
        target.opacity = 1
    }

    /// The wash as this view will actually paint it, under its own appearance.
    private func resolve(_ wash: NSColor?) -> CGColor? {
        guard let wash else { return nil }
        var resolved: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = wash.cgColor
        }
        return resolved
    }

    /// A straight mix in sRGB, with "no wash" treated as the other colour at
    /// zero alpha so a fade to or from `neutral` thins out rather than jumping.
    private static func mixed(_ a: CGColor?, _ b: CGColor?, by fraction: CGFloat) -> CGColor? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return fraction < 0.5 ? a : b }
        func parts(_ colour: CGColor?, fallback: CGColor?) -> [CGFloat]? {
            if let colour, let converted = colour.converted(to: space, intent: .defaultIntent, options: nil),
               let components = converted.components, components.count == 4 {
                return components
            }
            // Missing on one side: same hue as the other side, fully clear.
            if let fallback, let converted = fallback.converted(to: space, intent: .defaultIntent, options: nil),
               let components = converted.components, components.count == 4 {
                return [components[0], components[1], components[2], 0]
            }
            return nil
        }
        guard let from = parts(a, fallback: b), let to = parts(b, fallback: a) else { return nil }
        let mixed = zip(from, to).map { $0 + ($1 - $0) * fraction }
        return CGColor(colorSpace: space, components: mixed)
    }

    /// Pins a wash over an existing view, filling it.
    @discardableResult
    static func install(over view: NSView, in parent: NSView) -> TintView {
        let tint = TintView()
        parent.addSubview(tint, positioned: .above, relativeTo: view)
        NSLayoutConstraint.activate([
            tint.topAnchor.constraint(equalTo: view.topAnchor),
            tint.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tint.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        return tint
    }
}
