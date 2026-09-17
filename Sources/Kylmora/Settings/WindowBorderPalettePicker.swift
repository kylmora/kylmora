import AppKit

/// The grid of colour runs a space's border is chosen from.
///
/// Each run is shown as it will look: a pill filled with the gradient, its
/// name underneath, and a tick on the chosen one. A pop-up of names would
/// make the user imagine "Cosmic"; this shows it.
@MainActor
final class WindowBorderPalettePicker: NSView {
    var onSelect: ((WindowBorder.Palette) -> Void)?

    private(set) var selected: WindowBorder.Palette = .glow
    private var swatches: [(WindowBorder.Palette, Swatch)] = []

    static let columns = 4
    static let pillSize = NSSize(width: 68, height: 26)
    static let columnSpacing: CGFloat = 22
    static let rowSpacing: CGFloat = 10

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        let grid = NSGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.columnSpacing = Self.columnSpacing
        grid.rowSpacing = Self.rowSpacing
        grid.xPlacement = .center

        var row: [NSView] = []
        for palette in WindowBorder.Palette.allCases {
            let swatch = Swatch(palette: palette)
            swatch.onClick = { [weak self] in self?.choose(palette) }
            swatches.append((palette, swatch))
            row.append(swatch)
            if row.count == Self.columns {
                grid.addRow(with: row)
                row = []
            }
        }
        if !row.isEmpty { grid.addRow(with: row) }
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor)
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel("Border colours")
        show(.glow)
    }

    required init?(coder: NSCoder) {
        fatalError("WindowBorderPalettePicker is created in code only")
    }

    /// Moves the tick without reporting a choice.
    func show(_ palette: WindowBorder.Palette) {
        selected = palette
        for (candidate, swatch) in swatches { swatch.isSelected = candidate == palette }
    }

    /// Whether the runs are shown as gradients or as the one colour the
    /// solid style takes from each.
    func showSolid(_ solid: Bool) {
        for (_, swatch) in swatches { swatch.showsSolid = solid }
    }

    var isEnabled = true {
        didSet { for (_, swatch) in swatches { swatch.isEnabled = isEnabled } }
    }

    private func choose(_ palette: WindowBorder.Palette) {
        show(palette)
        onSelect?(palette)
    }

    /// One pill and its name.
    @MainActor
    private final class Swatch: NSControl {
        var onClick: (() -> Void)?
        var isSelected = false {
            didSet { if isSelected != oldValue { needsDisplay = true } }
        }
        var showsSolid = false {
            didSet { if showsSolid != oldValue { needsDisplay = true } }
        }
        override var isEnabled: Bool {
            didSet { needsDisplay = true }
        }

        private let palette: WindowBorder.Palette
        private static let labelHeight: CGFloat = 16

        init(palette: WindowBorder.Palette) {
            self.palette = palette
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                widthAnchor.constraint(equalToConstant: WindowBorderPalettePicker.pillSize.width),
                heightAnchor.constraint(equalToConstant: WindowBorderPalettePicker.pillSize.height + Self.labelHeight)
            ])
            setAccessibilityElement(true)
            setAccessibilityRole(.radioButton)
            setAccessibilityLabel(palette.title)
            toolTip = palette.title
        }

        required init?(coder: NSCoder) {
            fatalError("Swatch is created in code only")
        }

        override func accessibilityValue() -> Any? { isSelected }

        override func draw(_ dirtyRect: NSRect) {
            let pillSize = WindowBorderPalettePicker.pillSize
            let pill = NSRect(x: 0, y: bounds.height - pillSize.height, width: pillSize.width, height: pillSize.height)
            let path = NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2)
            if showsSolid {
                palette.solidColor.setFill()
                path.fill()
            } else if let gradient = NSGradient(colors: palette.stops) {
                gradient.draw(in: path, angle: 0)
            }

            if isSelected {
                let symbol = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 12, weight: .bold))
                if let symbol {
                    let side: CGFloat = 12
                    let at = NSRect(x: pill.midX - side / 2, y: pill.midY - side / 2, width: side, height: side)
                    // White over the colour, with a dark halo so it also reads
                    // over Silver and Fire & Ice's white stop.
                    NSGraphicsContext.saveGraphicsState()
                    let shadow = NSShadow()
                    shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
                    shadow.shadowBlurRadius = 2
                    shadow.set()
                    let tinted = symbol.tinted(.white)
                    tinted.draw(in: at)
                    NSGraphicsContext.restoreGraphicsState()
                }
            }

            let label = NSAttributedString(string: palette.title, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: isEnabled ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor
            ])
            let size = label.size()
            label.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (Self.labelHeight - size.height) / 2))

            if !isEnabled {
                NSColor.windowBackgroundColor.withAlphaComponent(0.5).setFill()
                path.fill()
            }
        }

        /// The squeeze the swatch gives under a click. See `SpringPress`.
        private lazy var press = SpringPress(view: self)

        override func mouseDown(with event: NSEvent) {
            guard isEnabled else { return }
            if acceptsSpringPress { press.flick() }
            onClick?()
        }

        override func accessibilityPerformPress() -> Bool {
            guard isEnabled else { return false }
            onClick?()
            return true
        }
    }
}

private extension NSImage {
    /// A template symbol filled with one colour, for drawing over an
    /// arbitrary background where the control tint would be wrong.
    func tinted(_ colour: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            colour.set()
            rect.fill()
            self.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
        return image
    }
}

/// A slider that snaps to a few named stops, with the names under the track.
///
/// The names are what make it a choice rather than a number: "Thin" and
/// "Thick" mean something, "0.0" and "2.0" do not.
@MainActor
final class SettingsStopSlider: NSView {
    var onChange: ((Int) -> Void)?

    let slider = NSSlider()
    private let labels: [NSView]

    /// `NSSlider` moves for an assistive client's value change or increment
    /// but does not send its action for either, so a VoiceOver user could
    /// move the knob and change nothing. The slider's accessibility element
    /// is its cell, so the cell is what reports every move.
    private final class AccessibleSliderCell: NSSliderCell {
        private func report() {
            guard let control = controlView as? NSControl else { return }
            control.sendAction(control.action, to: control.target)
        }

        override func setAccessibilityValue(_ accessibilityValue: Any?) {
            super.setAccessibilityValue(accessibilityValue)
            report()
        }

        override func accessibilityPerformIncrement() -> Bool {
            let done = super.accessibilityPerformIncrement()
            report()
            return done
        }

        override func accessibilityPerformDecrement() -> Bool {
            let done = super.accessibilityPerformDecrement()
            report()
            return done
        }
    }

    /// - Parameter stops: one label per stop, in order. A label may be a
    ///   string or an SF Symbol name prefixed with `symbol:`.
    init(stops: [String], width: CGFloat = 320) {
        labels = stops.map { stop in
            if stop.hasPrefix("symbol:") {
                let name = String(stop.dropFirst("symbol:".count))
                let view = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage())
                view.contentTintColor = .secondaryLabelColor
                view.symbolConfiguration = .init(pointSize: 11, weight: .regular)
                view.setAccessibilityElement(false)
                return view
            }
            let label = NSTextField(labelWithString: stop)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.setAccessibilityElement(false)
            return label
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        slider.cell = AccessibleSliderCell()
        slider.minValue = 0
        slider.maxValue = Double(stops.count - 1)
        slider.numberOfTickMarks = stops.count
        slider.allowsTickMarkValuesOnly = true
        slider.tickMarkPosition = .below
        slider.isContinuous = false
        slider.target = self
        slider.action = #selector(moved)
        slider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(slider)
        for label in labels {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }

        var constraints = [
            widthAnchor.constraint(equalToConstant: width),
            slider.topAnchor.constraint(equalTo: topAnchor),
            slider.leadingAnchor.constraint(equalTo: leadingAnchor),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: 42)
        ]
        // A tick sits half a knob in from each end of the track; the label
        // under it is centred on the tick, and the outer two lean in so the
        // words stay inside the row.
        let knob: CGFloat = 10
        for (index, label) in labels.enumerated() {
            let fraction = CGFloat(index) / CGFloat(max(labels.count - 1, 1))
            let centre = NSLayoutConstraint(
                item: label, attribute: .centerX, relatedBy: .equal,
                toItem: slider, attribute: .trailing, multiplier: max(fraction, 0.001), constant: 0
            )
            centre.constant = knob - fraction * 2 * knob
            if fraction == 0 {
                constraints.append(label.leadingAnchor.constraint(equalTo: leadingAnchor))
            } else {
                constraints.append(centre)
            }
            constraints.append(label.topAnchor.constraint(equalTo: slider.bottomAnchor, constant: 2))
        }
        NSLayoutConstraint.activate(constraints)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsStopSlider is created in code only")
    }

    var stop: Int {
        get { Int(slider.doubleValue.rounded()) }
        set { slider.doubleValue = Double(newValue) }
    }

    var isEnabled: Bool {
        get { slider.isEnabled }
        set {
            slider.isEnabled = newValue
            for label in labels {
                (label as? NSTextField)?.textColor = newValue ? .secondaryLabelColor : .tertiaryLabelColor
                (label as? NSImageView)?.contentTintColor = newValue ? .secondaryLabelColor : .tertiaryLabelColor
            }
        }
    }

    @objc private func moved() {
        onChange?(stop)
    }
}
