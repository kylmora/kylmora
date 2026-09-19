import AppKit

/// Where a point in the picker's field lands, and what colour it stands for.
///
/// Pure, so the maths can be checked without a window: the field is a square
/// of saturation left-to-right and brightness bottom-to-top, the slider a bar
/// of hue left-to-right.
enum ColourPickerMath {
    /// The saturation and brightness a point in a field of `size` stands for.
    /// Points outside the field clamp to its edge, which is what a drag that
    /// leaves the view should do.
    static func components(at point: CGPoint, in size: CGSize) -> (saturation: CGFloat, brightness: CGFloat) {
        guard size.width > 0, size.height > 0 else { return (0, 1) }
        return (
            min(max(point.x / size.width, 0), 1),
            min(max(point.y / size.height, 0), 1)
        )
    }

    /// Where the cursor sits for a saturation and brightness.
    static func point(saturation: CGFloat, brightness: CGFloat, in size: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(saturation, 0), 1) * size.width,
            y: min(max(brightness, 0), 1) * size.height
        )
    }

    /// The hue at a point along a slider `width` points wide, 0...1.
    static func hue(atX x: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        return min(max(x / width, 0), 1)
    }

    /// Where the slider's thumb sits for a hue.
    static func x(forHue hue: CGFloat, width: CGFloat) -> CGFloat {
        min(max(hue, 0), 1) * width
    }

    /// A colour from typed text: `#37f`, `#3377ff`, or the same without the
    /// hash, in any case. Anything else is nothing.
    static func colour(fromTyped text: String) -> NSColor? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") { trimmed.removeFirst() }
        guard trimmed.count == 3 || trimmed.count == 6,
              trimmed.allSatisfy(\.isHexDigit) else { return nil }
        if trimmed.count == 3 {
            trimmed = trimmed.map { "\($0)\($0)" }.joined()
        }
        return NSColor(hexString: "#" + trimmed.lowercased())
    }
}

/// Kylmora's own colour picker: a saturation/brightness field, a hue slider and
/// a hex field, all inside the panel that asked for a colour.
///
/// The stock `NSColorPanel` is a second window in another app's visual
/// language, it opens over the sheet that wanted it, and it stays open after
/// the sheet has gone. Choosing a colour is part of making a space, so it
/// happens in the same card as the rest of it.
@MainActor
final class ColourPickerView: NSView {
    /// Every change as it is dragged, so the preview behind the picker keeps up.
    var onChange: ((NSColor) -> Void)?

    /// The colour the picker is showing.
    private(set) var colour: NSColor = .systemBlue

    private var hue: CGFloat = 0.58
    private var saturation: CGFloat = 1
    private var brightness: CGFloat = 1

    private let field = FieldView()
    private let slider = HueSlider()
    private let hex = PanelTextField(placeholder: "#0a84ff")
    private let well = ColourWell()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        field.onPick = { [weak self] saturation, brightness in
            guard let self else { return }
            self.saturation = saturation
            self.brightness = brightness
            self.publish()
        }
        slider.onPick = { [weak self] hue in
            guard let self else { return }
            self.hue = hue
            self.publish()
        }
        hex.field.delegate = self
        hex.field.isEditable = true

        let bottom = NSStackView(views: [well, hex])
        bottom.orientation = .horizontal
        bottom.alignment = .centerY
        bottom.spacing = 8

        let column = NSStackView(views: [field, slider, bottom])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.widthAnchor.constraint(equalTo: column.widthAnchor),
            field.heightAnchor.constraint(equalToConstant: 92),
            slider.widthAnchor.constraint(equalTo: column.widthAnchor),
            bottom.widthAnchor.constraint(equalTo: column.widthAnchor)
        ])
        show(colour)
    }

    required init?(coder: NSCoder) { fatalError("ColourPickerView is created in code only") }

    /// Puts a colour into the picker without reporting it back: the caller
    /// already knows, and a round trip would fight a drag in progress.
    func show(_ colour: NSColor) {
        guard let converted = colour.usingColorSpace(.sRGB) else { return }
        // A grey has no hue of its own to show, so the slider keeps the one it
        // had rather than snapping to red.
        if converted.saturationComponent > 0.001 {
            hue = converted.hueComponent
        }
        saturation = converted.saturationComponent
        brightness = converted.brightnessComponent
        self.colour = converted
        sync()
        hex.stringValue = converted.hexString
    }

    private func publish() {
        colour = NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
        sync()
        hex.stringValue = colour.hexString
        onChange?(colour)
    }

    private func sync() {
        field.show(hue: hue, saturation: saturation, brightness: brightness)
        slider.show(hue: hue)
        well.colour = colour
    }
}

extension ColourPickerView: NSTextFieldDelegate {
    /// Typed hex, as it is typed: six digits is a colour, anything shorter is
    /// someone still typing and is left alone.
    func controlTextDidChange(_ notification: Notification) {
        guard let typed = ColourPickerMath.colour(fromTyped: hex.stringValue),
              let converted = typed.usingColorSpace(.sRGB) else { return }
        if converted.saturationComponent > 0.001 { hue = converted.hueComponent }
        saturation = converted.saturationComponent
        brightness = converted.brightnessComponent
        colour = converted
        sync()
        onChange?(converted)
    }
}

/// The saturation/brightness square: the hue at full strength, washed white to
/// the left and black to the bottom, with a ring where the colour is.
@MainActor
private final class FieldView: NSView {
    var onPick: ((CGFloat, CGFloat) -> Void)?

    private var hue: CGFloat = 0
    private var saturation: CGFloat = 1
    private var brightness: CGFloat = 1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("FieldView is created in code only") }

    func show(hue: CGFloat, saturation: CGFloat, brightness: CGFloat) {
        self.hue = hue
        self.saturation = saturation
        self.brightness = brightness
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        path.addClip()

        NSColor(hue: hue, saturation: 1, brightness: 1, alpha: 1).setFill()
        bounds.fill()
        NSGradient(colors: [.white, NSColor(white: 1, alpha: 0)])?
            .draw(in: bounds, angle: 0)
        NSGradient(colors: [.black, NSColor(white: 0, alpha: 0)])?
            .draw(in: bounds, angle: 90)

        // The cursor: a white ring with a dark hairline, so it is visible on a
        // pale corner as well as a dark one.
        let point = ColourPickerMath.point(
            saturation: saturation, brightness: brightness, in: bounds.size
        )
        let ring = NSRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)
        NSColor.white.setStroke()
        let circle = NSBezierPath(ovalIn: ring)
        circle.lineWidth = 2
        circle.stroke()
        NSColor(white: 0, alpha: 0.35).setStroke()
        let edge = NSBezierPath(ovalIn: ring.insetBy(dx: -1, dy: -1))
        edge.lineWidth = 1
        edge.stroke()
    }

    override func mouseDown(with event: NSEvent) { pick(event) }
    override func mouseDragged(with event: NSEvent) { pick(event) }

    private func pick(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let picked = ColourPickerMath.components(at: point, in: bounds.size)
        onPick?(picked.saturation, picked.brightness)
    }
}

/// The hue bar under the field.
@MainActor
private final class HueSlider: NSView {
    var onPick: ((CGFloat) -> Void)?

    private var hue: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 16).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("HueSlider is created in code only") }

    func show(hue: CGFloat) {
        self.hue = hue
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let bar = bounds.insetBy(dx: 0, dy: 3)
        NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2).addClip()
        let stops = stride(from: CGFloat(0), through: 1, by: 1.0 / 12).map {
            NSColor(hue: $0, saturation: 1, brightness: 1, alpha: 1)
        }
        NSGradient(colors: stops)?.draw(in: bar, angle: 0)

        // The thumb rides the bar rather than sitting on it, so the track is
        // not broken by a plate the width of a finger.
        let x = ColourPickerMath.x(forHue: hue, width: bounds.width)
        let thumb = NSRect(x: min(max(x - 7, 0), bounds.width - 14), y: 1, width: 14, height: 14)
        NSColor(hue: hue, saturation: 1, brightness: 1, alpha: 1).setFill()
        NSBezierPath(ovalIn: thumb).fill()
        NSColor.white.setStroke()
        let ring = NSBezierPath(ovalIn: thumb.insetBy(dx: 1.5, dy: 1.5))
        ring.lineWidth = 2.5
        ring.stroke()
    }

    override func mouseDown(with event: NSEvent) { pick(event) }
    override func mouseDragged(with event: NSEvent) { pick(event) }

    private func pick(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onPick?(ColourPickerMath.hue(atX: point.x, width: bounds.width))
    }
}

/// The colour as it stands, beside the hex field.
@MainActor
private final class ColourWell: NSView {
    var colour: NSColor = .systemBlue { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 32),
            heightAnchor.constraint(equalToConstant: 32)
        ])
    }

    required init?(coder: NSCoder) { fatalError("ColourWell is created in code only") }

    override func draw(_ dirtyRect: NSRect) {
        let plate = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        colour.setFill()
        plate.fill()
        Style.Colors.controlRing.setStroke()
        plate.lineWidth = 1
        plate.stroke()
    }
}
