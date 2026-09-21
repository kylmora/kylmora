import AppKit

/// Overlay view that renders mouse gesture trails and real-time action hint badges.
@MainActor
public final class GestureTrailView: NSView {
    /// Points accumulated along the active gesture drag path.
    public private(set) var points: [NSPoint] = []

    /// Current recognized action name, if any.
    public var actionTitle: String? {
        didSet { updateHUD() }
    }

    /// SF Symbol for current recognized action.
    public var actionSymbol: String? {
        didSet { updateHUD() }
    }

    /// Arrow representation of current strokes (e.g. "↓ →").
    public var strokesText: String? {
        didSet { updateHUD() }
    }

    private let hudContainer = NSVisualEffectView()
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        setupHUD()
    }

    public required init?(coder: NSCoder) {
        fatalError("GestureTrailView is code-only")
    }

    private func setupHUD() {
        hudContainer.material = .hudWindow
        hudContainer.blendingMode = .withinWindow
        hudContainer.state = .active
        hudContainer.wantsLayer = true
        hudContainer.layer?.cornerRadius = 10
        hudContainer.layer?.masksToBounds = true
        hudContainer.layer?.borderWidth = 1
        hudContainer.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        hudContainer.isHidden = true

        iconView.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
        iconView.contentTintColor = .labelColor

        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .labelColor

        let stack = NSStackView(views: [iconView, label])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false

        hudContainer.addSubview(stack)
        addSubview(hudContainer)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: hudContainer.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: hudContainer.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: hudContainer.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: hudContainer.bottomAnchor, constant: -8)
        ])
    }

    /// Appends a point to the trail path and triggers redraw.
    public func addPoint(_ point: NSPoint) {
        points.append(point)
        positionHUD(at: point)
        needsDisplay = true
    }

    /// Clears all points and resets HUD.
    public func reset() {
        points.removeAll()
        actionTitle = nil
        actionSymbol = nil
        strokesText = nil
        hudContainer.isHidden = true
        alphaValue = 1.0
        needsDisplay = true
    }

    private func positionHUD(at point: NSPoint) {
        hudContainer.layoutSubtreeIfNeeded()
        let hudSize = hudContainer.fittingSize
        let offset: CGFloat = 20

        var x = point.x + offset
        var y = point.y - hudSize.height - offset

        // Keep inside bounds
        if x + hudSize.width > bounds.maxX - 10 {
            x = point.x - hudSize.width - offset
        }
        if y < bounds.minY + 10 {
            y = point.y + offset
        }

        hudContainer.frame = NSRect(x: max(10, x), y: max(10, y), width: hudSize.width, height: hudSize.height)
    }

    private func updateHUD() {
        guard let title = actionTitle, !title.isEmpty else {
            hudContainer.isHidden = true
            return
        }

        let symbol = actionSymbol ?? "hand.draw"
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)

        if let strokes = strokesText, !strokes.isEmpty {
            label.stringValue = "\(strokes)  \(title)"
        } else {
            label.stringValue = title
        }

        hudContainer.isHidden = false
        if let last = points.last {
            positionHUD(at: last)
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard points.count >= 2 else { return }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        let path = NSBezierPath()
        path.move(to: points[0])
        for i in 1..<points.count {
            path.line(to: points[i])
        }

        path.lineWidth = 4.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        // Soft outer glow
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.controlAccentColor.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 6.0
        shadow.shadowOffset = .zero
        shadow.set()

        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }

    /// Fades out the trail smoothly and executes completion callback.
    ///
    /// `completion` is `@MainActor @Sendable` because it has to cross into
    /// AppKit's completion block, which is imported as `@Sendable`. A plain
    /// `(() -> Void)?` cannot be sent there without risking a data race.
    public func fadeOut(duration: TimeInterval = 0.22, completion: (@MainActor @Sendable () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // AppKit runs this block on the main thread, but it is imported as
            // `@Sendable`, so the compiler cannot prove it. Assume what is true
            // rather than hop to the actor and leave the trail up an extra turn.
            MainActor.assumeIsolated {
                self?.removeFromSuperview()
                self?.reset()
                completion?()
            }
        })
    }
}
