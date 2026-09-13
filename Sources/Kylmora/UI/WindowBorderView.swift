import AppKit
import QuartzCore

/// The rim a space draws around the window.
///
/// It sits above everything else in the window, inset by nothing, and is
/// clipped to the window's own rounded corners by a mask with the same
/// radius and corner curve (`Style.Metrics.windowCornerRadius`). The
/// mask is a plain layer with a border rather than a stroked path, because a
/// layer border follows `cornerCurve` and a `CGPath` cannot: the window's
/// corner is a continuous curve, and a circular ring inside it leaves a
/// sliver of window showing at every corner.
///
/// Two coats, not one. During a space swipe the rim fades from this space's
/// border towards the neighbour's in step with the drag, which needs both on
/// screen at once. On release the incoming coat finishes fading in over the
/// same duration as the strip, so the rim arrives with the space rather than
/// snapping before or after it.
///
/// A gradient border sweeps around the window by rotating a conic gradient
/// under the ring: the gradient is a square as wide as the window's diagonal,
/// so no corner of the ring ever reaches past its edge. Reduce Motion stops
/// the sweep, whatever the space asked for.
///
/// It never takes a click. Nothing is under it that should be unreachable.
@MainActor
final class WindowBorderView: NSView {
    /// The corner the rim is clipped to. The window's, normally; zero in
    /// full screen, where the window has no corners.
    var cornerRadius: CGFloat = Style.Metrics.windowCornerRadius {
        didSet { if cornerRadius != oldValue { relayoutCoats() } }
    }

    /// What is shown, or arriving.
    private(set) var border: WindowBorder = .none

    private var front = Coat()
    private var back = Coat()
    private var reduceMotionObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
        wantsLayer = true
        layer?.addSublayer(back.container)
        layer?.addSublayer(front.container)
        front.container.opacity = 1
        back.container.opacity = 0
        reduceMotionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayoutCoats() }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("WindowBorderView is created in code only")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        relayoutCoats()
    }

    /// The glass coat resolves to different colours in light and dark.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        relayoutCoats()
    }

    private func relayoutCoats() {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for coat in [front, back] {
            coat.layout(in: bounds, cornerRadius: cornerRadius, appearance: effectiveAppearance, reduceMotion: reduceMotion)
        }
    }

    // MARK: - Showing and blending

    /// Finishes at this border, starting from wherever the coats are now.
    func show(_ target: WindowBorder, animatedOver duration: TimeInterval) {
        if target != border {
            // The neighbour coat may already be part-way in from a drag
            // towards it. Reconfigure it in place if it is showing the same
            // border, so the fade carries on from there.
            if back.border != target {
                back.configure(target)
                relayoutCoats()
            }
            swap(&front, &back)
            border = target
        }
        Self.fade(front.container, to: 1, over: duration)
        Self.fade(back.container, to: 0, over: duration)
        retire(back, after: duration)
    }

    /// Once an outgoing coat has faded out it is emptied, so a gradient
    /// nobody can see is not left sweeping under the ring. Unless a drag has
    /// brought it back in the meantime, in which case it is not outgoing.
    private func retire(_ coat: Coat, after duration: TimeInterval) {
        let clear = { [weak self] in
            guard let self, coat === back, coat.container.opacity == 0, coat.border != .none else { return }
            coat.configure(.none)
            relayoutCoats()
        }
        if duration > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: clear)
        } else {
            clear()
        }
    }

    /// Part-way between this space's rim and a neighbour's, for a strip
    /// dragged part-way towards the neighbour.
    func blend(toward other: WindowBorder?, fraction: CGFloat) {
        let target = other ?? .none
        if back.border != target {
            back.configure(target)
            relayoutCoats()
        }
        let mix = Float(max(0, min(1, fraction)))
        Self.fade(front.container, to: 1 - mix, over: 0)
        Self.fade(back.container, to: mix, over: 0)
    }

    private static let fadeKey = "kylmora.border.fade"

    private static func fade(_ layer: CALayer, to opacity: Float, over duration: TimeInterval) {
        let from = layer.presentation()?.opacity ?? layer.opacity
        layer.removeAnimation(forKey: fadeKey)
        layer.opacity = opacity
        guard duration > 0, from != opacity else { return }
        let move = CABasicAnimation(keyPath: "opacity")
        move.fromValue = from
        move.toValue = opacity
        move.duration = duration
        move.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(move, forKey: fadeKey)
    }

    // MARK: - A coat

    /// One border, drawn: a paint layer showing through a ring-shaped mask.
    @MainActor
    private final class Coat {
        let container = CALayer()
        private let ring = CALayer()
        private let paint = CAGradientLayer()
        private(set) var border: WindowBorder = .none

        private static let sweepKey = "kylmora.border.sweep"

        init() {
            container.mask = ring
            container.addSublayer(paint)
            container.isHidden = true
            ring.backgroundColor = nil
            ring.borderColor = NSColor.black.cgColor
            ring.cornerCurve = .continuous
            paint.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            // Implicit animations on frame and colour changes would make a
            // resize lag the window by a quarter second.
            container.actions = ["bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
            ring.actions = ["bounds": NSNull(), "position": NSNull(), "borderWidth": NSNull(), "cornerRadius": NSNull()]
            paint.actions = ["bounds": NSNull(), "position": NSNull(), "colors": NSNull(), "locations": NSNull(), "transform": NSNull()]
        }

        func configure(_ border: WindowBorder) {
            self.border = border
        }

        func layout(in bounds: CGRect, cornerRadius: CGFloat, appearance: NSAppearance, reduceMotion: Bool) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }

            container.frame = bounds
            container.isHidden = !border.isVisible
            guard border.isVisible else {
                paint.removeAnimation(forKey: Self.sweepKey)
                return
            }

            ring.frame = bounds
            ring.cornerRadius = cornerRadius
            ring.borderWidth = border.thickness.points

            // A square on the diagonal, so a rotation never shows a corner
            // of the paint inside the ring.
            let side = (bounds.width * bounds.width + bounds.height * bounds.height).squareRoot()
            paint.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            paint.position = CGPoint(x: bounds.midX, y: bounds.midY)

            switch border.style {
            case .none:
                break
            case .solid:
                paint.type = .axial
                let colour = border.palette.solidColor.cgColor
                paint.colors = [colour, colour]
                paint.locations = nil
            case .glass:
                paint.type = .axial
                paint.startPoint = CGPoint(x: 0.5, y: 1)
                paint.endPoint = CGPoint(x: 0.5, y: 0)
                paint.colors = Self.glassColours(for: appearance)
                paint.locations = nil
            case .gradient:
                paint.type = .conic
                paint.startPoint = CGPoint(x: 0.5, y: 0.5)
                paint.endPoint = CGPoint(x: 1, y: 0.5)
                // The first colour again at the end, so the sweep closes on
                // itself rather than showing a seam where it started.
                var stops = border.palette.stops.map(\.cgColor)
                stops.append(stops[0])
                paint.colors = stops
                paint.locations = (0..<stops.count).map { NSNumber(value: Double($0) / Double(stops.count - 1)) }
            }

            let animated = border.isAnimated && !reduceMotion
            if animated {
                if paint.animation(forKey: Self.sweepKey) == nil {
                    let sweep = CABasicAnimation(keyPath: "transform.rotation.z")
                    sweep.fromValue = 0
                    sweep.toValue = -2 * Double.pi
                    sweep.duration = border.animation.secondsPerRevolution
                    sweep.repeatCount = .infinity
                    sweep.isRemovedOnCompletion = false
                    paint.add(sweep, forKey: Self.sweepKey)
                } else if let running = paint.animation(forKey: Self.sweepKey) as? CABasicAnimation,
                          running.duration != border.animation.secondsPerRevolution {
                    paint.removeAnimation(forKey: Self.sweepKey)
                    let sweep = running.copy() as! CABasicAnimation
                    sweep.duration = border.animation.secondsPerRevolution
                    paint.add(sweep, forKey: Self.sweepKey)
                }
            } else {
                paint.removeAnimation(forKey: Self.sweepKey)
                paint.transform = CATransform3DIdentity
            }
        }

        /// A frosted rim: lighter at the top, as glass catches light from
        /// above. White over a dark window, black over a light one, where
        /// white would vanish into the surface.
        private static func glassColours(for appearance: NSAppearance) -> [CGColor] {
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let base: CGFloat = isDark ? 1 : 0
            return [
                NSColor(white: base, alpha: isDark ? 0.55 : 0.22).cgColor,
                NSColor(white: base, alpha: isDark ? 0.22 : 0.08).cgColor
            ]
        }
    }
}
