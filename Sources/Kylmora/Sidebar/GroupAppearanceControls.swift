import AppKit

// The hand-drawn controls the group appearance editor is built from. None is a
// stock AppKit control: they share `Style`'s radii, fills and text colours
// so the panel reads as one surface rather than a form.

/// A live preview of the group's plate: the chosen fill and rim, with a mock
/// header row and one tab row over it so it reads as a group and not a swatch.
///
/// Flipped, so a direction angle lands the same way here as it does in the
/// sidebar's (flipped) plate rows -- "top to bottom" runs top to bottom in both.
@MainActor
final class ThemePreview: NSView {
    private var theme: TabGroupAppearance = .standard
    private var tint: NSColor = .controlAccentColor

    /// Words to draw in place of the mock bars.
    ///
    /// The bars say "something is written here" without saying what, which in
    /// a group's editor is right -- the group already has its rows behind the
    /// sheet. In the New Space sheet there is nothing behind it, and two grey
    /// bars on a coloured card read as a thing that failed to load. Given the
    /// name being typed and a tab under it, the same card reads as the sidebar
    /// this space is about to have.
    var labels: (title: String, tab: String)? {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Preview")
    }

    required init?(coder: NSCoder) { fatalError("ThemePreview is created in code only") }

    func show(_ appearance: TabGroupAppearance, tint: NSColor) {
        self.theme = appearance
        self.tint = tint
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = Style.Metrics.folderPlateCornerRadius
        let plate = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)

        // A checker under the plate would be louder than the sidebar it stands
        // in for; a plain low panel fill is closer to the real backdrop.
        Style.Colors.folderPlateFill.setFill()
        NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius).fill()

        if let gradient = theme.gradient(fallback: Style.Colors.folderPlateFill) {
            gradient.draw(in: path, angle: theme.direction.angle)
        }
        if let rim = theme.elevation.rim {
            let inset = plate.insetBy(dx: rim.width / 2, dy: rim.width / 2)
            let rimPath = NSBezierPath(roundedRect: inset, xRadius: radius, yRadius: radius)
            rimPath.lineWidth = rim.width
            NSColor(white: 1, alpha: rim.alpha).setStroke()
            rimPath.stroke()
        }

        // A mock header (a filled dot and a bar) and a mock tab under it, so the
        // preview shows what the colour sits behind.
        let readable = theme.fill == .standard ? Style.Colors.secondaryText : bestTextColour()
        drawMockRow(
            y: plate.minY + 18, barWidth: 96, filledDot: true, colour: readable,
            text: labels?.title, weight: .semibold
        )
        drawMockRow(
            y: plate.minY + 46, barWidth: 74, filledDot: false,
            colour: readable.withAlphaComponent(0.7), text: labels?.tab, weight: .regular
        )
    }

    private func drawMockRow(
        y: CGFloat,
        barWidth: CGFloat,
        filledDot: Bool,
        colour: NSColor,
        text: String?,
        weight: NSFont.Weight
    ) {
        let x: CGFloat = 18
        let dotRect = NSRect(x: x, y: y - 5, width: 10, height: 10)
        colour.setFill()
        if filledDot {
            NSBezierPath(ovalIn: dotRect).fill()
        } else {
            let ring = NSBezierPath(ovalIn: dotRect.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            colour.setStroke()
            ring.stroke()
        }

        guard let text, !text.isEmpty else {
            let bar = NSRect(x: x + 18, y: y - 3.5, width: barWidth, height: 7)
            NSBezierPath(roundedRect: bar, xRadius: 3.5, yRadius: 3.5).fill()
            return
        }

        // Clipped to what is left of the card, and ellipsised: a name near the
        // limit must not run off the edge of its own preview.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let drawn = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: weight),
            .foregroundColor: colour,
            .paragraphStyle: paragraph
        ])
        let height = drawn.size().height
        drawn.draw(in: NSRect(
            x: x + 18,
            y: y - height / 2,
            width: max(0, bounds.width - (x + 18) - 18),
            height: height
        ))
    }

    /// White or near-black, whichever reads better over the middle of the fill.
    private func bestTextColour() -> NSColor {
        let mid = theme.startColor(fallback: tint)
            .blended(withFraction: 0.5, of: theme.endColor(fallback: tint)) ?? tint
        let srgb = mid.usingColorSpace(.sRGB) ?? mid
        let luma = 0.299 * srgb.redComponent + 0.587 * srgb.greenComponent + 0.114 * srgb.blueComponent
        return luma > 0.6 ? NSColor(white: 0.1, alpha: 0.9) : NSColor(white: 1, alpha: 0.95)
    }
}

/// A rounded segmented control: a low track, a lifted thumb behind the chosen
/// segment, and a label per segment. Stands in for `NSSegmentedControl`, which
/// draws a bezel that is wrong for this chrome.
@MainActor
final class SegmentedPills: NSView {
    var onSelect: ((Int) -> Void)?
    private(set) var selectedIndex = 0

    private let titles: [String]
    private var segmentRects: [NSRect] = []
    /// Air either side of a title inside its pill.
    private static let titlePadding: CGFloat = 12

    /// What this control needs to lay `titles` out on one line, so a panel can
    /// be built wide enough to hold it rather than the words being squeezed.
    static func width(forTitles titles: [String]) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        return titles.reduce(0) { total, title in
            total + ceil((title as NSString).size(withAttributes: [.font: font]).width)
                + titlePadding * 2
        }
    }

    init(titles: [String]) {
        self.titles = titles
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
    }

    /// What a title needs, so a pill is as wide as its word rather than as wide
    /// as its share of the control.
    private func width(of title: String) -> CGFloat {
        Self.width(forTitles: [title])
    }

    required init?(coder: NSCoder) { fatalError("SegmentedPills is created in code only") }

    /// Moves the thumb without reporting a choice, for loading a value in.
    func select(_ index: Int) {
        guard titles.indices.contains(index), index != selectedIndex else { return }
        selectedIndex = index
        needsDisplay = true
    }

    /// Each pill is either its share of the control or its own word, whichever
    /// is larger.
    ///
    /// Equal shares are right for three short words -- the pills read as one
    /// control rather than as separate buttons. They are wrong for five long
    /// ones: "Automatic, Light, Dark, Customized, Website" is what the Spaces
    /// pane offers and so what the New Space sheet offers, and an equal share
    /// of that sheet is 68 points where "Customized" needs 85. So a control
    /// whose words do not fit their shares gives each word the room it needs,
    /// and whoever placed it gives the control the width that adds up to --
    /// `NewSpaceSheet.width` is that sum.
    override func layout() {
        super.layout()
        guard bounds.width > 0 else { return }
        let widths = titles.map(width(of:))
        let share = bounds.width / CGFloat(titles.count)

        guard let widest = widths.max(), widest > share else {
            segmentRects = titles.indices.map {
                NSRect(x: CGFloat($0) * share, y: 0, width: share, height: bounds.height)
            }
            return
        }

        var x: CGFloat = 0
        segmentRects = widths.map { width in
            defer { x += width }
            return NSRect(x: x, y: 0, width: width, height: bounds.height)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius: CGFloat = 7
        Style.Colors.folderPlateFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        if segmentRects.indices.contains(selectedIndex) {
            let thumb = segmentRects[selectedIndex].insetBy(dx: 2, dy: 2)
            Style.Colors.rowSelectedFill.setFill()
            NSBezierPath(roundedRect: thumb, xRadius: radius - 2, yRadius: radius - 2).fill()
        }

        for (index, rect) in segmentRects.enumerated() {
            let selected = index == selectedIndex
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11.5, weight: selected ? .semibold : .regular),
                .foregroundColor: selected ? Style.Colors.primaryText : Style.Colors.secondaryText
            ]
            let text = titles[index] as NSString
            let size = text.size(withAttributes: attributes)
            let point = NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
            text.draw(at: point, withAttributes: attributes)
        }
    }

    /// Where each pill was placed, so a test can check that no word was given
    /// less room than it needs.
    var segmentFramesForTesting: [NSRect] { segmentRects }

    /// The squeeze the track gives under a click. See `SpringPress`.
    ///
    /// The whole track squeezes, not the one segment that was hit: the track is
    /// the control, and a single segment shrinking inside a fixed frame would
    /// read as the segment coming loose rather than as the control yielding.
    private lazy var press = SpringPress(view: self)

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = segmentRects.firstIndex(where: { $0.contains(point) }) else { return }
        if acceptsSpringPress { press.flick() }
        if index != selectedIndex {
            selectedIndex = index
            needsDisplay = true
        }
        onSelect?(index)
    }
}

/// A rounded tile filled with a gradient, a solid colour, or nothing, ringed
/// when it is the chosen one. The preset swatches and the "default" tile.
@MainActor
final class SwatchTile: NSControl {
    enum Look {
        case none
        case solid(NSColor)
        case gradient(NSColor, NSColor, CGFloat)
    }

    var onClick: (() -> Void)?
    var isSelected = false {
        didSet { if isSelected != oldValue { needsDisplay = true } }
    }

    private let look: Look

    init(look: Look, label: String) {
        self.look = look
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 26).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        toolTip = label
    }

    required init?(coder: NSCoder) { fatalError("SwatchTile is created in code only") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let radius: CGFloat = 7
        let tile = bounds.insetBy(dx: 1.5, dy: 1.5)
        let path = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)
        switch look {
        case .none:
            Style.Colors.folderPlateFill.setFill()
            path.fill()
            NSColor.tertiaryLabelColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        case .solid(let colour):
            colour.setFill()
            path.fill()
        case .gradient(let start, let end, let angle):
            NSGradient(starting: start, ending: end)?.draw(in: path, angle: angle)
        }
        guard isSelected else { return }
        let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: radius + 1, yRadius: radius + 1)
        Style.Colors.primaryText.setStroke()
        ring.lineWidth = 1.5
        ring.stroke()
    }

    /// The squeeze the swatch gives under a click. See `SpringPress`.
    private lazy var press = SpringPress(view: self)

    override func mouseDown(with event: NSEvent) {
        if acceptsSpringPress { press.flick() }
        onClick?()
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

/// A single colour, drawn as a filled circle with a ring while the panel is
/// editing it. Opens the shared colour panel through `onClick` rather than
/// being an `NSColorWell`, so it can be a plain circle.
@MainActor
final class ColorChip: NSControl {
    var onClick: (() -> Void)?
    var color: NSColor = .controlAccentColor {
        didSet { needsDisplay = true }
    }

    init(label: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 30),
            heightAnchor.constraint(equalToConstant: 30)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        toolTip = label
    }

    required init?(coder: NSCoder) { fatalError("ColorChip is created in code only") }

    override func draw(_ dirtyRect: NSRect) {
        let disc = bounds.insetBy(dx: 2, dy: 2)
        color.setFill()
        NSBezierPath(ovalIn: disc).fill()
        // A soft ring so a chip the colour of the panel is still a disc, and a
        // hint that it is tappable.
        NSColor(white: 1, alpha: 0.3).setStroke()
        let edge = NSBezierPath(ovalIn: disc.insetBy(dx: 0.5, dy: 0.5))
        edge.lineWidth = 1
        edge.stroke()
    }

    /// The squeeze the swatch gives under a click. See `SpringPress`.
    private lazy var press = SpringPress(view: self)

    override func mouseDown(with event: NSEvent) {
        if acceptsSpringPress { press.flick() }
        onClick?()
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

/// The six gradient directions as arrow cells in a rounded track, the chosen
/// one lifted onto a thumb -- the same shape as `SegmentedPills`, with glyphs
/// instead of words.
@MainActor
final class DirectionPicker: NSView {
    var onSelect: ((TabGroupAppearance.Direction) -> Void)?

    private let directions = TabGroupAppearance.Direction.allCases
    private var selected: TabGroupAppearance.Direction = .down
    private var cellRects: [NSRect] = []
    private var arrows: [NSImageView] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        wantsLayer = true
        for direction in directions {
            let view = NSImageView()
            view.image = NSImage(systemSymbolName: direction.symbolName, accessibilityDescription: direction.title)
            view.imageScaling = .scaleProportionallyDown
            view.contentTintColor = Style.Colors.secondaryText
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            arrows.append(view)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel("Gradient direction")
    }

    required init?(coder: NSCoder) { fatalError("DirectionPicker is created in code only") }

    func select(_ direction: TabGroupAppearance.Direction) {
        guard direction != selected else { return }
        selected = direction
        updateTints()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let width = bounds.width / CGFloat(directions.count)
        cellRects = directions.indices.map { NSRect(x: CGFloat($0) * width, y: 0, width: width, height: bounds.height) }
        for (view, rect) in zip(arrows, cellRects) {
            view.frame = NSRect(x: rect.midX - 8, y: rect.midY - 8, width: 16, height: 16)
        }
        updateTints()
    }

    private func updateTints() {
        for (view, direction) in zip(arrows, directions) {
            view.contentTintColor = direction == selected ? Style.Colors.primaryText : Style.Colors.secondaryText
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius: CGFloat = 7
        Style.Colors.folderPlateFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        guard let index = directions.firstIndex(of: selected), cellRects.indices.contains(index) else { return }
        let thumb = cellRects[index].insetBy(dx: 2, dy: 2)
        Style.Colors.rowSelectedFill.setFill()
        NSBezierPath(roundedRect: thumb, xRadius: radius - 2, yRadius: radius - 2).fill()
    }

    /// The squeeze the track gives under a click. See `SpringPress`.
    private lazy var press = SpringPress(view: self)

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = cellRects.firstIndex(where: { $0.contains(point) }) else { return }
        if acceptsSpringPress { press.flick() }
        let direction = directions[index]
        if direction != selected {
            selected = direction
            updateTints()
            needsDisplay = true
        }
        onSelect?(direction)
    }
}

/// A named two-stop gradient with a direction that suits it, for the one-tap
/// preset rows in the group and space editors. Curated rather than random: each
/// is a pair the eye reads as one wash.
struct GradientPreset: Equatable {
    let name: String
    let startHex: String
    let endHex: String
    let direction: GradientDirection

    static let all: [GradientPreset] = [
        GradientPreset(name: "Sunset", startHex: "#ff7e5f", endHex: "#feb47b", direction: .downRight),
        GradientPreset(name: "Ocean", startHex: "#2193b0", endHex: "#6dd5ed", direction: .right),
        GradientPreset(name: "Grape", startHex: "#654ea3", endHex: "#a44cff", direction: .down),
        GradientPreset(name: "Forest", startHex: "#11998e", endHex: "#38ef7d", direction: .downRight),
        GradientPreset(name: "Fire", startHex: "#f12711", endHex: "#f5af19", direction: .down),
        GradientPreset(name: "Sky", startHex: "#4facfe", endHex: "#00f2fe", direction: .right),
        GradientPreset(name: "Bloom", startHex: "#c94b9c", endHex: "#f7a1c4", direction: .right),
        GradientPreset(name: "Slate", startHex: "#3a4452", endHex: "#1c1f26", direction: .down)
    ]
}

/// One dot in the solid-colour palette: a filled circle, or a hue wheel that
/// stands for "choose any colour". Ringed when it is the chosen one.
@MainActor
final class SolidSwatch: NSControl {
    enum Kind: Equatable { case colour(NSColor); case wheel }

    var onClick: (() -> Void)?
    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }
    /// For the wheel: the custom colour to show in place of the hue ring once
    /// one has been picked. Nil draws the hue ring.
    var customColour: NSColor? { didSet { needsDisplay = true } }

    private let kind: Kind

    init(kind: Kind, label: String) {
        self.kind = kind
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 26).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        toolTip = label
    }

    required init?(coder: NSCoder) { fatalError("SolidSwatch is created in code only") }

    override func draw(_ dirtyRect: NSRect) {
        // A centred disc, the same size selected or not, so the row does not
        // shuffle when the ring appears.
        let side = min(bounds.width, bounds.height) - 4
        let disc = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        switch kind {
        case .colour(let colour):
            colour.setFill()
            NSBezierPath(ovalIn: disc).fill()
        case .wheel:
            if let customColour {
                customColour.setFill()
                NSBezierPath(ovalIn: disc).fill()
            } else {
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
        }
        guard isSelected else { return }
        Style.Colors.primaryText.setStroke()
        let ring = NSBezierPath(ovalIn: disc.insetBy(dx: -3, dy: -3))
        ring.lineWidth = 2
        ring.stroke()
    }

    /// The squeeze the swatch gives under a click. See `SpringPress`.
    private lazy var press = SpringPress(view: self)

    override func mouseDown(with event: NSEvent) {
        if acceptsSpringPress { press.flick() }
        onClick?()
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

/// The solid-colour section: a grid of curated colours and, last, a wheel that
/// opens the colour panel for anything else.
@MainActor
final class SolidPalette: NSView {
    var onPick: ((NSColor) -> Void)?
    var onCustom: (() -> Void)?

    /// Two-dozen colours across the spectrum, plus a few neutrals -- enough to
    /// pick from without the panel, spread so no two read as the same.
    static let colours: [String] = [
        "#ff3b30", "#ff375f", "#ff2d55", "#ff6482", "#ff9500", "#ff6b00",
        "#ffb340", "#ffcc00", "#ffd60a", "#34c759", "#30d158", "#00c7be",
        "#00b894", "#5ac8fa", "#32ade6", "#007aff", "#0a84ff", "#5856d6",
        "#af52de", "#bf5af2", "#a2845e", "#8e8e93", "#2c2c2e"
    ]

    private var swatches: [(hex: String, view: SolidSwatch)] = []
    private let wheel = SolidSwatch(kind: .wheel, label: "Choose colour\u{2026}")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        var cells: [NSView] = []
        for hex in Self.colours {
            let colour = NSColor(hexString: hex) ?? .gray
            let swatch = SolidSwatch(kind: .colour(colour), label: hex)
            swatch.onClick = { [weak self] in self?.onPick?(colour) }
            swatches.append((hex, swatch))
            cells.append(swatch)
        }
        wheel.onClick = { [weak self] in self?.onCustom?() }
        cells.append(wheel)

        // Six to a row, wrapping down; the wheel is the last cell.
        let rows = stride(from: 0, to: cells.count, by: 6).map { start -> NSStackView in
            let row = NSStackView(views: Array(cells[start..<min(start + 6, cells.count)]))
            row.orientation = .horizontal
            row.spacing = 8
            row.distribution = .fillEqually
            return row
        }
        // A short last row still lays its cells out at full-row width.
        if let last = rows.last, last.views.count < 6 {
            for _ in last.views.count..<6 { last.addArrangedSubview(NSView()) }
        }
        let column = NSStackView(views: rows)
        column.orientation = .vertical
        column.spacing = 8
        column.alignment = .leading
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        for row in rows { row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
    }

    required init?(coder: NSCoder) { fatalError("SolidPalette is created in code only") }

    /// Rings the swatch matching `colour`, or the wheel (showing the colour)
    /// when it is not one of the palette's.
    func select(_ colour: NSColor?) {
        let hex = colour?.hexString
        var matched = false
        for (swatchHex, view) in swatches {
            let isMatch = swatchHex == hex
            view.isSelected = isMatch
            matched = matched || isMatch
        }
        wheel.customColour = (matched || colour == nil) ? nil : colour
        wheel.isSelected = !matched && colour != nil
    }
}
