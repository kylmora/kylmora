import AppKit

/// The row of colour swatches a space's colour is chosen from.
///
/// A row of circles, then one colour well: the eight are the choices that
/// are known to survive being washed over a dark material, side by side so
/// they can be compared, and the well at the end is for the user who wants
/// something else anyway. Picking from the well selects the `custom` theme.
@MainActor
final class SpaceThemePicker: NSView {
    var onSelect: ((SpaceTheme) -> Void)?
    /// A colour chosen from the well.
    var onCustomColor: ((NSColor) -> Void)?

    private let wheel = WheelSwatch()

    private(set) var selected: SpaceTheme = .default {
        didSet {
            guard selected != oldValue else { return }
            for (theme, swatch) in swatches { swatch.isSelected = theme == selected }
        }
    }

    private var swatches: [(SpaceTheme, Swatch)] = []

    /// Diameter of one swatch, and the gap between two.
    static let swatchSide: CGFloat = 22
    static let spacing: CGFloat = 8

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        var views: [NSView] = []
        for theme in SpaceTheme.palette {
            let swatch = Swatch(theme: theme)
            swatch.onClick = { [weak self] in self?.choose(theme) }
            swatches.append((theme, swatch))
            views.append(swatch)
        }
        wheel.onClick = { [weak self] in self?.openColorPanel() }
        views.append(wheel)

        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = Self.spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        // A bare `NSView`/`NSControl` subclass is not an accessibility element
        // until it says so: without this the whole row is missing from the
        // hierarchy, so VoiceOver cannot reach the colours at all.
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel("Theme colour")
        show(.default)
    }

    required init?(coder: NSCoder) {
        fatalError("SpaceThemePicker is created in code only")
    }

    /// Moves the ring without reporting a choice, for loading an existing
    /// space into the editor.
    func show(_ theme: SpaceTheme) {
        selected = theme
        for (candidate, swatch) in swatches { swatch.isSelected = candidate == theme }
    }

    /// Remembers the custom colour, for the panel to start from.
    func showCustomColor(_ colour: NSColor?) {
        wheel.customColor = colour
        wheel.isSelected = selected == .custom
    }

    /// The system colour panel, which reports through `changeColor(_:)`
    /// while it is up. Opened from here rather than an `NSColorWell` so the
    /// swatch row stays a row of circles with one more circle at the end.
    private func openColorPanel() {
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(panelColorChanged(_:)))
        panel.showsAlpha = false
        panel.color = wheel.customColor ?? selected.color
        panel.orderFront(nil)
    }

    @objc private func panelColorChanged(_ sender: NSColorPanel) {
        wheel.customColor = sender.color
        show(.custom)
        wheel.isSelected = true
        onCustomColor?(sender.color)
    }

    private func choose(_ theme: SpaceTheme) {
        show(theme)
        wheel.isSelected = false
        onSelect?(theme)
    }

    /// The last swatch: a wheel of every hue, which stands for "any other
    /// colour" and shows the chosen one once there is one.
    @MainActor
    private final class WheelSwatch: NSControl {
        var onClick: (() -> Void)?
        var customColor: NSColor? {
            didSet { needsDisplay = true }
        }
        var isSelected = false {
            didSet { if isSelected != oldValue { needsDisplay = true } }
        }

        init() {
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                widthAnchor.constraint(equalToConstant: SpaceThemePicker.swatchSide),
                heightAnchor.constraint(equalToConstant: SpaceThemePicker.swatchSide)
            ])
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityLabel("Custom colour")
            toolTip = "Custom colour"
        }

        required init?(coder: NSCoder) {
            fatalError("WheelSwatch is created in code only")
        }

        override func draw(_ dirtyRect: NSRect) {
            let inset: CGFloat = isSelected ? 3 : 0
            let disc = bounds.insetBy(dx: inset, dy: inset)
            if let customColor {
                customColor.setFill()
                NSBezierPath(ovalIn: disc).fill()
            } else {
                // A wheel: twelve hues around the disc.
                let centre = NSPoint(x: disc.midX, y: disc.midY)
                let radius = disc.width / 2
                for step in 0..<12 {
                    let start = CGFloat(step) * 30
                    let wedge = NSBezierPath()
                    wedge.move(to: centre)
                    wedge.appendArc(withCenter: centre, radius: radius, startAngle: start, endAngle: start + 30.5)
                    wedge.close()
                    NSColor(hue: CGFloat(step) / 12, saturation: 0.85, brightness: 0.95, alpha: 1).setFill()
                    wedge.fill()
                }
            }
            guard isSelected else { return }
            (customColor ?? .labelColor).setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            ring.stroke()
        }

        /// The squeeze the swatch gives under a click. See `SpringPress`.
        private lazy var press = SpringPress(view: self)

        override func mouseDown(with event: NSEvent) {
            if acceptsSpringPress { press.flick() }
            onClick?()
        }

        override func accessibilityPerformPress() -> Bool {
            onClick?()
            return true
        }
    }

    /// One circle, with a ring around it when it is the chosen one.
    @MainActor
    private final class Swatch: NSControl {
        var onClick: (() -> Void)?
        var isSelected = false {
            didSet { if isSelected != oldValue { needsDisplay = true } }
        }

        private let theme: SpaceTheme

        init(theme: SpaceTheme) {
            self.theme = theme
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                widthAnchor.constraint(equalToConstant: SpaceThemePicker.swatchSide),
                heightAnchor.constraint(equalToConstant: SpaceThemePicker.swatchSide)
            ])
            setAccessibilityElement(true)
            setAccessibilityRole(.radioButton)
            setAccessibilityLabel(theme.title)
            toolTip = theme.title
        }

        required init?(coder: NSCoder) {
            fatalError("Swatch is created in code only")
        }

        override func accessibilityValue() -> Any? { isSelected }

        override func draw(_ dirtyRect: NSRect) {
            // The ring is drawn outside the fill rather than around it, so a
            // selected swatch is the same size as an unselected one. A swatch
            // that grows when picked makes the whole row shuffle sideways.
            let inset: CGFloat = isSelected ? 3 : 0
            theme.color.setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: inset, dy: inset)).fill()

            guard isSelected else { return }
            theme.color.setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            ring.stroke()
        }

        /// The squeeze the swatch gives under a click. See `SpringPress`.
        private lazy var press = SpringPress(view: self)

        override func mouseDown(with event: NSEvent) {
            if acceptsSpringPress { press.flick() }
            onClick?()
        }

        override func accessibilityPerformPress() -> Bool {
            onClick?()
            return true
        }
    }
}
