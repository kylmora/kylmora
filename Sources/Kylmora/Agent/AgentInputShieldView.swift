import AppKit
import QuartzCore

/// What a page under the agent's control looks like, after ego lite's actor overlay.
///
/// While the agent drives:
/// - a 3pt blue stroke with rounded corners and a soft inner glow that
///   breathes on a 4s cycle mark the page as busy;
/// - the user's pointer is fenced off. Hovering tints the page with the scrim
///   gradient and shows the not-allowed cursor, and clicks and scrolls are
///   swallowed. The agent's own events go to the web view directly, so the
///   fence never blocks them;
/// - a floating pill at the top says what the agent is doing and offers
///   "Take over".
///
/// While the user holds control, the fence and the glow go away and the pill
/// offers to give the task back.
@MainActor
final class AgentInputShieldView: NSView {
    private let stroke = CAShapeLayer()
    private let glow = CAShapeLayer()
    private let scrim = CAGradientLayer()
    private let bar = AgentTaskBar()
    private var tracking: NSTrackingArea?
    private var fenced = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true

        scrim.colors = AgentOverlayPalette.scrim.map(\.cgColor)
        scrim.locations = [0.07, 0.45, 0.88]
        // 77° in CSS: nearly left-to-right, rising slightly.
        scrim.startPoint = CGPoint(x: 0, y: 0.61)
        scrim.endPoint = CGPoint(x: 1, y: 0.39)
        scrim.opacity = 0
        layer?.addSublayer(scrim)

        // Filled so it casts its shadow; the fill itself hides under the stroke.
        glow.fillColor = AgentOverlayPalette.glow.cgColor
        glow.shadowColor = AgentOverlayPalette.glow.cgColor
        glow.shadowRadius = 22
        glow.shadowOffset = .zero
        glow.shadowOpacity = 1
        glow.fillRule = .evenOdd
        layer?.addSublayer(glow)

        stroke.fillColor = nil
        stroke.strokeColor = AgentOverlayPalette.border.cgColor
        stroke.lineWidth = 3
        layer?.addSublayer(stroke)

        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            bar.centerXAnchor.constraint(equalTo: centerXAnchor),
            bar.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
        ])

        isHidden = true
        NotificationCenter.default.addObserver(
            forName: .agentHandoffStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncToState() }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("AgentInputShieldView is created in code only")
    }

    /// Fills the web view it guards, under the agent's cursor.
    func attach(to webView: NSView) {
        if superview !== webView {
            removeFromSuperview()
            frame = webView.bounds
            autoresizingMask = [.width, .height]
        }
        webView.addSubview(self, positioned: .above, relativeTo: nil)
        syncToState()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrim.frame = bounds
        stroke.frame = bounds
        glow.frame = bounds
        let edge = bounds.insetBy(dx: 1.5, dy: 1.5)
        stroke.path = CGPath(roundedRect: edge, cornerWidth: 6, cornerHeight: 6, transform: nil)
        // An inner glow: the shadow of a thick frame hugging the edges, of
        // which only the inward half is inside the clipped bounds.
        let frame = CGMutablePath()
        frame.addRect(bounds.insetBy(dx: -40, dy: -40))
        frame.addRoundedRect(in: bounds.insetBy(dx: 3, dy: 3), cornerWidth: 6, cornerHeight: 6)
        glow.path = frame
        CATransaction.commit()
    }

    func syncToState() {
        let manager = AgentHandoffManager.shared
        switch manager.currentState {
        case .idle:
            isHidden = true
            fenced = false
        case .agentDriving(let task):
            isHidden = false
            fenced = true
            stroke.isHidden = false
            glow.isHidden = false
            startBreathing()
            bar.showDriving(task: task)
        case .userInControl(let reason, let requestedByAgent):
            isHidden = false
            fenced = false
            stroke.isHidden = true
            glow.isHidden = true
            glow.removeAllAnimations()
            setScrimVisible(false)
            bar.showUserInControl(reason: reason, requestedByAgent: requestedByAgent)
        }
        window?.invalidateCursorRects(for: self)
    }

    /// pulse-opacity: 0.6 → 0 over the first third, holds, then back.
    private func startBreathing() {
        guard glow.animation(forKey: "breathe") == nil else { return }
        let breathe = CAKeyframeAnimation(keyPath: "opacity")
        breathe.values = [0.6, 0, 0, 0.6]
        breathe.keyTimes = [0, 0.3333, 0.6666, 1]
        breathe.timingFunctions = [
            CAMediaTimingFunction(controlPoints: 0.33, 0, 0.67, 1),
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(controlPoints: 0.33, 0, 0.67, 1),
        ]
        breathe.duration = 4
        breathe.repeatCount = .infinity
        glow.opacity = 0.6
        glow.add(breathe, forKey: "breathe")
    }

    private func setScrimVisible(_ visible: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        scrim.opacity = visible ? 1 : 0
        CATransaction.commit()
    }

    // MARK: - The fence

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        if let hit = bar.hitTest(local) { return hit }
        return fenced && bounds.contains(local) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { if fenced { setScrimVisible(true) } }
    override func mouseExited(with event: NSEvent) { setScrimVisible(false) }
    override func cursorUpdate(with event: NSEvent) {
        if fenced { NSCursor.operationNotAllowed.set() } else { super.cursorUpdate(with: event) }
    }
    override func resetCursorRects() {
        if fenced { addCursorRect(bounds, cursor: .operationNotAllowed) }
    }

    override func mouseDown(with event: NSEvent) { bar.nudge() }
    override func rightMouseDown(with event: NSEvent) { bar.nudge() }
    override func otherMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The floating pill: what the agent is doing, and the hand-off button.
@MainActor
final class AgentTaskBar: NSVisualEffectView {
    private let status = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let icon = NSImageView()
    private let button = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        appearance = NSAppearance(named: .vibrantDark)
        wantsLayer = true
        layer?.cornerRadius = 17
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true

        icon.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        icon.contentTintColor = .white

        status.font = .systemFont(ofSize: 12.5, weight: .medium)
        status.textColor = .white
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        button.bezelStyle = .rounded
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 12
        button.layer?.cornerCurve = .continuous
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        button.contentTintColor = .white
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(buttonClicked)
        button.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [spinner, icon, status, button])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 5, left: 12, bottom: 5, right: 5)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: 34),
            button.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("AgentTaskBar is created in code only")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func showDriving(task: String) {
        spinner.isHidden = false
        spinner.startAnimation(nil)
        icon.isHidden = true
        status.stringValue = task.isEmpty ? "Agent is working" : task
        configureButton(title: "Take over", symbol: "hand.raised.fill", tint: NSColor.white.withAlphaComponent(0.18))
    }

    func showUserInControl(reason: String, requestedByAgent: Bool) {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        icon.isHidden = false
        icon.image = NSImage(systemSymbolName: requestedByAgent ? "person.fill.questionmark" : "person.fill", accessibilityDescription: nil)
        status.stringValue = requestedByAgent ? "Your turn: \(reason)" : "You're in control — the agent is paused"
        configureButton(title: "Give back to agent", symbol: "sparkles", tint: AgentOverlayPalette.border)
    }

    /// A click on the fenced page points the user at the button.
    func nudge() {
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0, -5, 5, -3, 3, 0]
        shake.duration = 0.32
        layer?.add(shake, forKey: "nudge")
    }

    private func configureButton(title: String, symbol: String, tint: NSColor) {
        button.attributedTitle = NSAttributedString(string: "  \(title)  ", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        button.layer?.backgroundColor = tint.cgColor
    }

    @objc private func buttonClicked() {
        let manager = AgentHandoffManager.shared
        if manager.isUserControlling {
            manager.giveBackToAgent()
        } else {
            manager.takeOverByUser()
        }
    }
}
