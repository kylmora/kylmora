import AppKit

/// The shared look of the appearance panels -- the group editor and the New
/// Space sheet. One place for the panel's width, rhythm and accent so the two
/// read as the same designed surface rather than two forms.
///
/// The layout is deliberately not a stock macOS form (a column of right-aligned
/// captions with controls beside them). It is a hero preview over a stack of
/// captioned sections, each caption a small upper-case label above a full-width
/// control, which is what makes the panel Kylmora's own rather than the system's.
@MainActor
enum PanelStyle {
    /// The content width both panels lay out to.
    static let width: CGFloat = 300
    static let inset: CGFloat = 18
    /// Between one section and the next.
    static let sectionGap: CGFloat = 16
    /// Between a section's caption and its control.
    static let captionGap: CGFloat = 8
    static let corner: CGFloat = 10

    /// Kylmora's own accent, not the system one: a fixed indigo, so a primary
    /// button and a selection do not change with the user's system accent
    /// setting -- the panel is meant to look the same on every Mac.
    static let accent = NSColor(srgbRed: 0.42, green: 0.36, blue: 0.90, alpha: 1)

    /// A section: a small upper-case caption over its control, full width.
    static func section(_ caption: String, _ content: NSView) -> NSView {
        let label = NSTextField(labelWithAttributedString: captionString(caption))
        label.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [label, content])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = captionGap
        stack.translatesAutoresizingMaskIntoConstraints = false
        // The control fills the section's width; the caption hugs its text.
        content.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
        content.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        return stack
    }

    /// The caption's letters: upper-case, tracked out, quiet.
    static func captionString(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: Style.Colors.tertiaryText,
            .kern: 0.8
        ])
    }

    /// A hairline divider, for the space above the footer button.
    static func divider() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.separatorColor.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }
}

/// The surface a panel's controls are drawn on.
///
/// An opaque plate, and one that refuses vibrancy. The group editor is shown in
/// an `NSPopover`, whose backdrop is a translucent material: in dark mode that
/// material is a mid grey, and the panel's own greys -- a pill track, an
/// unselected label -- landed within a few per cent of it. Measured on screen,
/// "Solid" against its track came out at about 1.02:1, which is not dim, it is
/// invisible. Vibrancy made it worse by blending what little was left into the
/// backdrop.
///
/// The sheet version of the same controls never had the problem because a sheet
/// has an opaque background. This gives the popover one too, so a control is
/// read against a known surface rather than against whatever is behind the
/// window.
@MainActor
final class PanelBackdrop: NSView {
    /// Custom-drawn chrome, not vibrant material. See above.
    override var allowsVibrancy: Bool { false }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Style.Colors.panelSurface.setFill()
        dirtyRect.fill()
    }
}

/// A pill button drawn from scratch: an accent-filled primary or a quiet
/// secondary, both with a rounded fill and a hover lift. Replaces `NSButton`,
/// whose bezel is the native look the panels are getting away from.
@MainActor
final class PanelButton: NSControl {
    enum Kind { case primary, secondary, plain }

    var onClick: (() -> Void)?
    private let kind: Kind
    private let title: String
    private var trackingArea: NSTrackingArea?
    private var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }
    private var isPressed = false { didSet { if isPressed != oldValue { needsDisplay = true } } }

    init(title: String, kind: Kind, onClick: (() -> Void)? = nil) {
        self.title = title
        self.kind = kind
        self.onClick = onClick
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: kind == .plain ? 24 : 30).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("PanelButton is created in code only") }

    override var intrinsicContentSize: NSSize {
        let width = (title as NSString).size(withAttributes: [.font: titleFont]).width
        return NSSize(width: width + (kind == .plain ? 8 : 28), height: kind == .plain ? 24 : 30)
    }

    private var titleFont: NSFont { .systemFont(ofSize: 12.5, weight: kind == .primary ? .semibold : .medium) }

    override func draw(_ dirtyRect: NSRect) {
        let radius: CGFloat = 8
        if kind != .plain {
            let fill: NSColor
            switch kind {
            case .primary: fill = isPressed ? PanelStyle.accent.blended(withFraction: 0.2, of: .black)! : PanelStyle.accent
            case .secondary: fill = isHovered ? Style.Colors.controlHoverFill : Style.Colors.controlFill
            case .plain: fill = .clear
            }
            fill.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
        let colour: NSColor
        switch kind {
        case .primary: colour = .white
        case .secondary: colour = Style.Colors.primaryText
        case .plain: colour = isHovered ? Style.Colors.primaryText : Style.Colors.secondaryText
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: colour]
        let text = title as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    /// The squeeze the swatch gives under a click. See `SpringPress`.
    private lazy var press = SpringPress(view: self)

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        if acceptsSpringPress { press.down() }
    }
    override func mouseUp(with event: NSEvent) {
        isPressed = false
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        // Released off the swatch is not a click, so it settles back without
        // the bounce -- the same distinction a folder header draws between a
        // toggle and a drag.
        if inside { press.up() } else { press.cancel() }
        if inside { onClick?() }
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

/// A text field on a rounded fill, no bezel: the field itself is borderless and
/// the rounded plate behind it is drawn here, so it matches the pills and tiles
/// instead of the system's inset white box.
@MainActor
final class PanelTextField: NSView {
    let field = NSTextField()

    var stringValue: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    init(placeholder: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        heightAnchor.constraint(equalToConstant: 32).isActive = true

        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 13)
        field.textColor = Style.Colors.primaryText
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            field.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        updatePlate()
    }

    required init?(coder: NSCoder) { fatalError("PanelTextField is created in code only") }

    /// A layer's background is a fixed `CGColor` and does not follow the
    /// appearance on its own, so the plate is re-resolved whenever the
    /// appearance changes.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updatePlate()
    }

    private func updatePlate() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Style.Colors.controlFill.cgColor
        }
    }
}

/// A rounded on/off switch with a sliding knob, drawn here rather than an
/// `NSButton` checkbox. Paired with a caption by the caller.
@MainActor
final class PanelToggle: NSControl {
    var onToggle: ((Bool) -> Void)?
    private(set) var isOn: Bool

    init(isOn: Bool) {
        self.isOn = isOn
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 38),
            heightAnchor.constraint(equalToConstant: 22)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("PanelToggle is created in code only") }

    func setOn(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = bounds
        (isOn ? PanelStyle.accent : Style.Colors.controlTrackFill).setFill()
        NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2).fill()
        let d = track.height - 4
        let x = isOn ? track.maxX - d - 2 : track.minX + 2
        let knob = NSBezierPath(ovalIn: NSRect(x: x, y: 2, width: d, height: d))
        NSColor.white.setFill()
        knob.fill()
        // A white knob on an off track is white on pale grey in light mode, so
        // the knob carries an edge of its own. Off only: the accent behind an
        // on knob already separates it.
        guard !isOn else { return }
        Style.Colors.controlRing.setStroke()
        knob.lineWidth = 1
        knob.stroke()
    }

    private func flip() {
        isOn.toggle()
        needsDisplay = true
        setAccessibilityValue(isOn)
        onToggle?(isOn)
    }

    /// The squeeze the toggle gives under a click. See `SpringPress`.
    private lazy var press = SpringPress(view: self)

    override func mouseDown(with event: NSEvent) {
        if acceptsSpringPress { press.flick() }
        flip()
    }
    override func accessibilityPerformPress() -> Bool { flip(); return true }
}
