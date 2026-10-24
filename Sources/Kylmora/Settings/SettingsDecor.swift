import AppKit

/// A quiet mountain lake, drawn rather than shipped as a picture.
///
/// It sits at the top right of the page behind the pane's title and at the
/// foot of the spine, and it is the thing that makes this window read as
/// Kylmora rather than as a form: calm, cool, a little air. Drawn in code so it
/// is sharp at any size, follows light and dark, and costs nothing to ship.
///
/// It fades out towards its leading and bottom edges, so it never has a border
/// -- it is weather on the canvas, not a photo pasted onto it.
@MainActor
final class SettingsLandscapeView: NSView {
    /// Which edges dissolve into the canvas.
    struct Fade: OptionSet {
        let rawValue: Int
        static let leading = Fade(rawValue: 1 << 0)
        static let bottom = Fade(rawValue: 1 << 1)
        static let top = Fade(rawValue: 1 << 2)
    }

    private let fade: Fade
    /// Whether to draw the pines along the near shore. Off for the small
    /// version in the spine, where they would be a few pixels of noise.
    private let drawsTrees: Bool

    init(fade: Fade = [.leading, .bottom], drawsTrees: Bool = true) {
        self.fade = fade
        self.drawsTrees = drawsTrees
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.isOpaque = false
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsLandscapeView is created in code only")
    }

    /// Decoration: clicks go to whatever is underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 1, bounds.height > 1 else { return }
        guard !fade.isEmpty, let context = NSGraphicsContext.current?.cgContext,
              let mask = Self.fadeMask(fade) else {
            drawScene()
            return
        }
        // The scene is clipped through a soft mask, so its faded edges melt
        // into the canvas. Done here rather than with a layer mask, which a
        // snapshot of the window does not honour.
        context.saveGState()
        context.clip(to: bounds, mask: mask)
        drawScene()
        context.restoreGState()
    }

    private func drawScene() {
        let w = bounds.width, h = bounds.height
        let dark = isDark

        // Sky.
        NSGradient(
            starting: dark ? rgb(0.12, 0.17, 0.30) : rgb(0.74, 0.84, 0.97),
            ending: dark ? rgb(0.07, 0.09, 0.15, 0) : rgb(0.93, 0.96, 1.0, 0)
        )?.draw(in: bounds, angle: -90)

        // A low sun, behind the far range.
        let sun = NSRect(x: w * 0.62, y: h * 0.52, width: w * 0.20, height: w * 0.20)
        NSGradient(
            starting: dark ? rgb(0.55, 0.62, 0.85, 0.35) : rgb(1, 1, 1, 0.9),
            ending: dark ? rgb(0.55, 0.62, 0.85, 0) : rgb(1, 1, 1, 0)
        )?.draw(in: NSBezierPath(ovalIn: sun), relativeCenterPosition: .zero)

        /// A ridge through these points, closed along the bottom of the view.
        func ridge(_ points: [(CGFloat, CGFloat)], _ colour: NSColor, base: CGFloat = 0) {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 0, y: h * base))
            for (x, y) in points { path.line(to: NSPoint(x: w * x, y: h * y)) }
            path.line(to: NSPoint(x: w, y: h * base))
            path.close()
            colour.setFill()
            path.fill()
        }

        // Far range: pale, sharp, snow-lit.
        ridge([(0, 0.42), (0.12, 0.50), (0.22, 0.46), (0.34, 0.66), (0.42, 0.58), (0.52, 0.80),
               (0.60, 0.70), (0.68, 0.76), (0.78, 0.60), (0.88, 0.72), (1, 0.62)],
              dark ? rgb(0.24, 0.30, 0.46) : rgb(0.70, 0.78, 0.92))
        // Snow on the highest peak.
        let snow = NSBezierPath()
        snow.move(to: NSPoint(x: w * 0.47, y: h * 0.70))
        snow.line(to: NSPoint(x: w * 0.52, y: h * 0.80))
        snow.line(to: NSPoint(x: w * 0.565, y: h * 0.735))
        snow.line(to: NSPoint(x: w * 0.53, y: h * 0.75))
        snow.line(to: NSPoint(x: w * 0.50, y: h * 0.72))
        snow.close()
        (dark ? rgb(0.60, 0.66, 0.82, 0.6) : rgb(1, 1, 1, 0.85)).setFill()
        snow.fill()

        // Middle range.
        ridge([(0, 0.30), (0.10, 0.38), (0.24, 0.32), (0.36, 0.48), (0.46, 0.40), (0.58, 0.52),
               (0.70, 0.40), (0.82, 0.50), (0.92, 0.44), (1, 0.50)],
              dark ? rgb(0.17, 0.22, 0.36) : rgb(0.56, 0.67, 0.86))

        // The lake.
        let lakeTop = h * 0.26
        NSGradient(
            starting: dark ? rgb(0.16, 0.21, 0.34) : rgb(0.80, 0.88, 0.98),
            ending: dark ? rgb(0.10, 0.13, 0.22) : rgb(0.70, 0.80, 0.95)
        )?.draw(in: NSRect(x: 0, y: 0, width: w, height: lakeTop), angle: -90)
        // Light on the water.
        (dark ? rgb(0.6, 0.7, 0.9, 0.18) : rgb(1, 1, 1, 0.55)).setFill()
        for (x, y, len) in [(0.55, 0.20, 0.16), (0.62, 0.15, 0.10), (0.48, 0.11, 0.07), (0.70, 0.09, 0.12)] {
            NSBezierPath(
                roundedRect: NSRect(x: w * x, y: h * y, width: w * len, height: max(1, h * 0.008)),
                xRadius: 1, yRadius: 1
            ).fill()
        }

        // Near shore on the right, with pines.
        let shoreColour = dark ? rgb(0.12, 0.16, 0.26) : rgb(0.42, 0.54, 0.72)
        ridge([(0.66, 0.22), (0.74, 0.30), (0.84, 0.36), (0.94, 0.42), (1, 0.46)], shoreColour, base: 0.20)
        guard drawsTrees else { return }
        let pine = dark ? rgb(0.08, 0.11, 0.18) : rgb(0.24, 0.34, 0.48)
        for (x, base, size) in [(0.72, 0.27, 0.10), (0.77, 0.30, 0.14), (0.81, 0.32, 0.11), (0.86, 0.35, 0.18),
                                (0.90, 0.38, 0.13), (0.94, 0.41, 0.20), (0.98, 0.44, 0.15)] {
            drawPine(at: NSPoint(x: w * x, y: h * base), height: h * size, colour: pine)
        }
    }

    /// A pine: three stacked triangles on a short trunk.
    private func drawPine(at foot: NSPoint, height: CGFloat, colour: NSColor) {
        colour.setFill()
        let half = height * 0.24
        for tier in 0..<3 {
            let t = CGFloat(tier)
            let base = foot.y + height * (0.12 + t * 0.24)
            let width = half * (1 - t * 0.22)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: foot.x - width, y: base))
            path.line(to: NSPoint(x: foot.x, y: base + height * 0.46))
            path.line(to: NSPoint(x: foot.x + width, y: base))
            path.close()
            path.fill()
        }
        NSRect(x: foot.x - height * 0.02, y: foot.y, width: height * 0.04, height: height * 0.16).fill()
    }

    /// A small grey ramp, stretched over the view as a clip mask: opaque in the top-trailing
    /// corner, gone at the faded edges.
    private static func fadeMask(_ fade: Fade) -> CGImage? {
        let side = 64
        var pixels = [UInt8](repeating: 0, count: side * side)
        for row in 0..<side {
            // Row 0 is the top of the image.
            let fromTop = CGFloat(row) / CGFloat(side - 1)
            let fromBottom = 1 - fromTop
            for column in 0..<side {
                let fromLeading = CGFloat(column) / CGFloat(side - 1)
                var alpha: CGFloat = 1
                if fade.contains(.leading) { alpha *= min(1, fromLeading / 0.55) }
                if fade.contains(.bottom) { alpha *= min(1, fromBottom / 0.45) }
                if fade.contains(.top) { alpha *= min(1, fromTop / 0.55) }
                // Eased, so the edge melts rather than ramps.
                alpha = alpha * alpha * (3 - 2 * alpha)
                pixels[row * side + column] = UInt8(max(0, min(255, alpha * 255)))
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}

/// The app's icon on a white tile, the way the design puts it everywhere the
/// brand appears: the top of the spine, the default-browser banner.
@MainActor
final class SettingsAppIconTile: SettingsPlateView {
    init(side: CGFloat) {
        super.init(frame: .zero)
        fill = Style.Colors.dynamic(light: .white, dark: NSColor(white: 1, alpha: 0.10))
        stroke = Style.Colors.settingsCardStroke
        cornerRadius = side * 0.26
        elevated = true
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setAccessibilityElement(false)
        addSubview(icon)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: side),
            heightAnchor.constraint(equalToConstant: side),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.92),
            icon.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.92)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsAppIconTile is created in code only")
    }
}

/// The top of the spine: the app's icon, its name, and the line it goes by.
@MainActor
final class SettingsBrandHeader: NSView {
    static let tagline = "Browser that keeps up with you"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        let tile = SettingsAppIconTile(side: 42)
        let name = NSTextField(labelWithString: "Kylmora")
        name.font = .systemFont(ofSize: 17, weight: .bold)
        name.textColor = Style.Colors.primaryText
        let tagline = NSTextField(labelWithString: Self.tagline)
        tagline.font = .systemFont(ofSize: 11)
        tagline.textColor = Style.Colors.secondaryText
        tagline.lineBreakMode = .byTruncatingTail
        tagline.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let words = NSStackView(views: [name, tagline])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 1
        words.translatesAutoresizingMaskIntoConstraints = false

        addSubview(tile)
        addSubview(words)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Style.SettingsUI.brandHeight),
            tile.leadingAnchor.constraint(equalTo: leadingAnchor),
            tile.centerYAnchor.constraint(equalTo: centerYAnchor),
            words.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 10),
            words.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            words.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Kylmora, \(Self.tagline)")
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsBrandHeader is created in code only")
    }
}

/// The pane's name, large, and a line under it saying what the page is for.
@MainActor
final class SettingsPageHeader: NSView {
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        title.font = Style.Fonts.settingsTitle
        title.textColor = Style.Colors.primaryText
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = .systemFont(ofSize: 14)
        subtitle.textColor = Style.Colors.secondaryText
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [title, subtitle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        // A stack refuses to clip its views by default, which held a long
        // subtitle at full width and ran it under the scenery's line.
        stack.setClippingResistancePriority(.defaultLow, for: .horizontal)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsPageHeader is created in code only")
    }

    func show(title: String, subtitle: String) {
        self.title.stringValue = title
        self.subtitle.stringValue = subtitle
        setAccessibilityLabel(title)
    }

    /// What the header says, for a test.
    var shownTitle: String { title.stringValue }
}

/// One section of a pane, as the design draws it: a panel holding a pastel
/// tile, the section's name and a line about it, then the card of rows.
///
/// The form puts a section's cards into `stack` instead of onto the page, so a
/// pane declares rows exactly as it always has and they land inside.
@MainActor
final class SettingsSectionPanel: SettingsPlateView {
    let stack = NSStackView()
    let title: String

    /// A panel with no header of its own: the form puts the section's
    /// heading in as the first thing in `stack`. Every pane that names its
    /// sections with a plain title gets the same panel General's do.
    init(plainTitled title: String) {
        self.title = title
        super.init(frame: .zero)
        dress()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.defaultHigh, for: .vertical)
        addSubview(stack)
        let padding = Style.SettingsUI.sectionPanelPadding
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: padding + 2),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
    }

    private func dress() {
        fill = Style.Colors.settingsSectionPanel
        stroke = Style.Colors.settingsCardStroke
        cornerRadius = Style.SettingsUI.sectionPanelRadius
        elevated = true
    }

    /// A panel whose every row a pane has hidden goes too, rather than
    /// leaving an empty plate with a heading in it.
    override func layout() {
        refreshEmptiness()
        super.layout()
    }

    override func viewWillDraw() {
        refreshEmptiness()
        super.viewWillDraw()
    }

    private func refreshEmptiness() {
        let content = stack.arrangedSubviews.filter { ($0 as? SettingsFormRow)?.style != .header }
        guard !content.isEmpty else { return }
        let empty = content.allSatisfy(\.isHidden)
        if isHidden != empty { isHidden = empty }
    }

    init(title: String, subtitle: String?, symbolName: String, tint: NSColor) {
        self.title = title
        super.init(frame: .zero)
        dress()

        let side = Style.SettingsUI.sectionTileSide
        let tile = SettingsPlateView()
        tile.fill = tint.withAlphaComponent(0.16)
        tile.cornerRadius = 13
        let glyph = NSImageView()
        glyph.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        glyph.contentTintColor = tint
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.setAccessibilityElement(false)
        tile.addSubview(glyph)

        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 17, weight: .bold)
        name.textColor = Style.Colors.primaryText
        let words = NSStackView(views: [name])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 3
        words.translatesAutoresizingMaskIntoConstraints = false
        if let subtitle {
            let line = NSTextField(wrappingLabelWithString: subtitle)
            line.font = .systemFont(ofSize: 12.5)
            line.textColor = Style.Colors.secondaryText
            line.maximumNumberOfLines = 2
            line.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            words.addArrangedSubview(line)
        }

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(tile)
        header.addSubview(words)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Holds its content's height, so a panel stretched beside a taller
        // one keeps its card at the top instead of sliding it to the foot.
        stack.setHuggingPriority(.defaultHigh, for: .vertical)

        addSubview(header)
        addSubview(stack)
        let padding = Style.SettingsUI.sectionPanelPadding
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: side),
            tile.heightAnchor.constraint(equalToConstant: side),
            glyph.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: tile.centerYAnchor),

            header.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding + 4),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            tile.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            tile.topAnchor.constraint(equalTo: header.topAnchor),
            header.bottomAnchor.constraint(greaterThanOrEqualTo: tile.bottomAnchor),
            words.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 16),
            words.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor),
            words.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            words.topAnchor.constraint(greaterThanOrEqualTo: header.topAnchor),
            header.bottomAnchor.constraint(greaterThanOrEqualTo: words.bottomAnchor),

            stack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -padding)
        ])
        // Only a ceiling at the foot, and the panel otherwise as short as it
        // can be: a panel stretched to match a taller one beside it keeps its
        // rows at the top and leaves the air below them.
        let shortest = heightAnchor.constraint(equalToConstant: 0)
        shortest.priority = .init(1)
        shortest.isActive = true
        // The header is as tall as its tile, or its words if they run longer,
        // and never stretched to soak up a taller neighbour's height.
        let snug = header.bottomAnchor.constraint(equalTo: tile.bottomAnchor)
        snug.priority = .defaultHigh
        snug.isActive = true

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsSectionPanel is created in code only")
    }

    override var isFlipped: Bool { true }
}
