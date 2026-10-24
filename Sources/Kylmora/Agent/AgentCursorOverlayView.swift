import AppKit
import QuartzCore

/// The agent's own pointer, drawn natively over the page.
///
/// It lives in the browser's view tree, not the page's DOM, so the site can't see
/// it, can't restyle it, and doesn't lose it on navigation. The motion follows
/// ego lite's (Chromium's) magic cursor:
/// - travel takes distance ÷ speed, clamped to a minimum and maximum duration,
///   eased with cubic-bezier(0.6, 0, 0.4, 1);
/// - the first appearance glides in from the nearer top corner;
/// - a click squeezes it to 85% for 400ms;
/// - after 200ms at rest it bobs gently, so a waiting agent reads as alive.
///
/// The current action label rides beside it in a dark pill.
@MainActor
final class AgentCursorOverlayView: NSView {
    static let speedPointsPerMs: CGFloat = 1.6
    static let minTravel: TimeInterval = 0.18
    static let maxTravel: TimeInterval = 0.70
    static let travelTiming = CAMediaTimingFunction(controlPoints: 0.6, 0, 0.4, 1)

    private let pointer = CAShapeLayer()
    private let labelPill = CALayer()
    private let labelText = CATextLayer()
    private var restTimer: Timer?
    private var hideTimer: Timer?
    private(set) var position: CGPoint?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        buildLayers()
        isHidden = true
        // The cursor is the agent's hand: it leaves when the agent lets go.
        NotificationCenter.default.addObserver(
            forName: .agentHandoffStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !AgentHandoffManager.shared.isAgentDriving, !self.isHidden else { return }
                self.dismiss()
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("AgentCursorOverlayView is created in code only")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func buildLayers() {
        // The classic arrow, tip at (0, 0), 24pt tall.
        let arrow = CGMutablePath()
        arrow.move(to: CGPoint(x: 0, y: 0))
        arrow.addLine(to: CGPoint(x: 0, y: 19))
        arrow.addLine(to: CGPoint(x: 4.6, y: 14.8))
        arrow.addLine(to: CGPoint(x: 7.8, y: 22))
        arrow.addLine(to: CGPoint(x: 11, y: 20.6))
        arrow.addLine(to: CGPoint(x: 7.9, y: 13.6))
        arrow.addLine(to: CGPoint(x: 14, y: 13.6))
        arrow.closeSubpath()

        pointer.path = arrow
        pointer.bounds = CGRect(x: 0, y: 0, width: 14, height: 22)
        pointer.anchorPoint = .zero
        pointer.fillColor = AgentOverlayPalette.cursorFill.cgColor
        pointer.strokeColor = NSColor.white.cgColor
        pointer.lineWidth = 1.5
        pointer.lineJoin = .round
        pointer.shadowColor = AgentOverlayPalette.cursorGlow.cgColor
        pointer.shadowOpacity = 1
        pointer.shadowRadius = 5
        pointer.shadowOffset = CGSize(width: 2, height: 3)

        labelPill.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        labelPill.cornerRadius = 9
        labelPill.cornerCurve = .continuous
        labelPill.anchorPoint = .zero

        labelText.font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        labelText.fontSize = 11.5
        labelText.foregroundColor = NSColor.white.cgColor
        labelText.alignmentMode = .left
        labelText.truncationMode = .end
        labelText.anchorPoint = .zero
        labelPill.addSublayer(labelText)

        layer?.addSublayer(labelPill)
        layer?.addSublayer(pointer)
        labelPill.isHidden = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        labelText.contentsScale = scale
        pointer.contentsScale = scale
    }

    /// Fills the web view it decorates.
    func attach(to webView: NSView) {
        guard superview !== webView else {
            webView.addSubview(self, positioned: .above, relativeTo: nil)
            return
        }
        removeFromSuperview()
        frame = webView.bounds
        autoresizingMask = [.width, .height]
        webView.addSubview(self, positioned: .above, relativeTo: nil)
    }

    /// How long travelling to `target` will take, at the magic cursor's speed.
    static func travelDuration(from start: CGPoint, to target: CGPoint) -> TimeInterval {
        let distance = hypot(target.x - start.x, target.y - start.y)
        let duration = TimeInterval(distance / speedPointsPerMs) / 1000
        return min(maxTravel, max(minTravel, duration))
    }

    /// Where the cursor starts from on its first appearance: the top corner on
    /// the target's side, so it visibly arrives rather than popping in.
    func entryPoint(toward target: CGPoint) -> CGPoint {
        position ?? CGPoint(x: target.x < bounds.midX ? 0 : bounds.maxX, y: 0)
    }

    /// Travels along `path` (view points, first point excluded) over `duration`.
    func travel(along path: [CGPoint], duration: TimeInterval, label: String?) {
        guard let destination = path.last else { return }
        show(label: label)
        let start = entryPoint(toward: destination)
        stopResting()

        let curve = CGMutablePath()
        curve.move(to: start)
        path.forEach { curve.addLine(to: $0) }

        let motion = CAKeyframeAnimation(keyPath: "position")
        motion.path = curve
        motion.duration = duration
        motion.calculationMode = .paced
        motion.timingFunction = Self.travelTiming

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pointer.position = destination
        pointer.add(motion, forKey: "travel")
        CATransaction.commit()
        position = destination
        layoutLabel(animatedOver: duration)
        scheduleRest(after: duration)
    }

    /// Jumps without travelling, e.g. when the page scrolled under the cursor.
    func place(at point: CGPoint, label: String? = nil) {
        show(label: label)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pointer.removeAnimation(forKey: "travel")
        pointer.position = point
        CATransaction.commit()
        position = point
        layoutLabel(animatedOver: 0)
        scheduleRest(after: 0)
    }

    /// The press: a quick squeeze and a 2pt dip, 400ms ease-out.
    func pulseClick() {
        stopResting()
        let squeeze = CAKeyframeAnimation(keyPath: "transform")
        let pressed = CATransform3DConcat(CATransform3DMakeScale(0.85, 0.85, 1), CATransform3DMakeTranslation(0, 2, 0))
        squeeze.values = [CATransform3DIdentity, pressed, CATransform3DIdentity].map { NSValue(caTransform3D: $0) }
        squeeze.keyTimes = [0, 0.4, 1]
        squeeze.duration = 0.4
        squeeze.timingFunction = CAMediaTimingFunction(name: .easeOut)
        pointer.add(squeeze, forKey: "click")
        scheduleRest(after: 0.4)
    }

    func setLabel(_ label: String?) {
        show(label: label)
        layoutLabel(animatedOver: 0)
    }

    /// Fades out; the next `travel` glides back in from where it left off.
    func dismiss() {
        hideTimer?.invalidate()
        stopResting()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.alphaValue == 0 else { return }
                self.isHidden = true
            }
        }
    }

    private func show(label: String?) {
        hideTimer?.invalidate()
        isHidden = false
        alphaValue = 1
        if let label {
            labelText.string = label
            labelPill.isHidden = label.isEmpty
        }
    }

    private func layoutLabel(animatedOver duration: TimeInterval) {
        guard let position, !labelPill.isHidden, let text = labelText.string as? String else { return }
        let font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        let width = min(280, ceil((text as NSString).size(withAttributes: [.font: font]).width))
        let size = CGSize(width: width + 20, height: 18)
        labelText.frame = CGRect(x: 10, y: 2, width: width, height: 15)

        // Beside the arrow's tail, flipped to the left near the right edge.
        var origin = CGPoint(x: position.x + 18, y: position.y + 16)
        if origin.x + size.width > bounds.maxX - 8 { origin.x = position.x - size.width - 6 }
        origin.y = min(origin.y, bounds.maxY - size.height - 6)

        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(Self.travelTiming)
        CATransaction.setDisableActions(duration == 0)
        labelPill.bounds = CGRect(origin: .zero, size: size)
        labelPill.position = origin
        CATransaction.commit()
    }

    private func scheduleRest(after delay: TimeInterval) {
        restTimer?.invalidate()
        restTimer = Timer.scheduledTimer(withTimeInterval: delay + 0.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.startResting() }
        }
    }

    private func startResting() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let bob = CAKeyframeAnimation(keyPath: "transform.translation.y")
        bob.values = [0, -4, 4, -4]
        bob.keyTimes = [0, 0.19, 0.6, 1]
        bob.duration = 3.95
        bob.repeatCount = .infinity
        bob.timingFunctions = Array(repeating: CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1), count: 3)
        pointer.add(bob, forKey: "rest")
    }

    private func stopResting() {
        restTimer?.invalidate()
        pointer.removeAnimation(forKey: "rest")
    }
}

/// ego lite's actor-overlay colours.
enum AgentOverlayPalette {
    static let border = NSColor(srgbRed: 0x1B / 255, green: 0x6E / 255, blue: 0xF3 / 255, alpha: 1)
    static let glow = NSColor(srgbRed: 0x4C / 255, green: 0x8D / 255, blue: 0xF6 / 255, alpha: 1)
    static let cursorFill = NSColor(srgbRed: 0x1B / 255, green: 0x6E / 255, blue: 0xF3 / 255, alpha: 1)
    static let cursorGlow = NSColor(srgbRed: 79 / 255, green: 161 / 255, blue: 1, alpha: 1)
    static let scrim: [NSColor] = [
        NSColor(srgbRed: 0x7C / 255, green: 0xAC / 255, blue: 0xF8 / 255, alpha: 0x3D / 255),
        NSColor(srgbRed: 0x0B / 255, green: 0x57 / 255, blue: 0xD0 / 255, alpha: 0x3D / 255),
        NSColor(srgbRed: 0x1B / 255, green: 0x6E / 255, blue: 0xF3 / 255, alpha: 0x3D / 255),
    ]
}
