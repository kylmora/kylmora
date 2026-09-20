import AppKit

/// The Task Manager's cards, drawn in the same vocabulary as the Settings
/// window: a continuous-cornered plate lifted off a washed canvas, a caption
/// tracked out above it, the space's own hue on whatever is live.
///
/// This window used to be a system-grey box with an `NSTableView` and three
/// push buttons in it -- the task manager every app has. Nothing about it said
/// Kylmora. What it says now it says with the same plates, hairlines and
/// colours the rest of the browser is made of, so it reads as a room in the
/// same house rather than as a panel that wandered in.
@MainActor
class ActivityCardView: SettingsPlateView {
    /// The caption over the card's contents: small, tracked out, quiet. The
    /// same treatment the Settings spine gives "APPEARANCE".
    private let caption = NSTextField(labelWithString: "")
    /// What a card puts under its caption. Subclasses and callers fill it.
    let body = NSStackView()

    init(caption title: String) {
        super.init(frame: .zero)
        fill = Style.Colors.settingsCard
        stroke = Style.Colors.settingsCardStroke
        cornerRadius = Style.SettingsUI.cardRadius
        elevated = true

        caption.attributedStringValue = NSAttributedString(
            string: title.uppercased(),
            attributes: [
                .font: Style.Fonts.settingsGroup,
                .foregroundColor: Style.Colors.tertiaryText,
                .kern: 1.0
            ]
        )
        caption.translatesAutoresizingMaskIntoConstraints = false
        caption.setAccessibilityElement(false)
        addSubview(caption)

        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 6
        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(body)

        let padding = Style.SettingsUI.cardPadding
        NSLayoutConstraint.activate([
            caption.topAnchor.constraint(equalTo: topAnchor, constant: padding - 2),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            caption.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -padding),
            body.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 8),
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("ActivityCardView is created in code only")
    }

    func setCaption(_ title: String) {
        let attributes = caption.attributedStringValue.attributes(at: 0, effectiveRange: nil)
        caption.attributedStringValue = NSAttributedString(string: title.uppercased(), attributes: attributes)
    }
}

/// One number, big, with two minutes of it behind.
///
/// The three across the top of the window -- CPU, memory, GPU -- and the shape
/// is the same whichever scope is in front: the whole browser, one space, one
/// page. Learning to read the card once is enough.
@MainActor
final class ActivityMetricCard: ActivityCardView {
    private let valueLabel = NSTextField(labelWithString: "—")
    private let detailLabel = NSTextField(labelWithString: "")
    private let ceilingLabel = NSTextField(labelWithString: "")
    private let graph = UsageGraphView()

    var tint: NSColor {
        didSet {
            valueLabel.textColor = tint
            graph.tint = tint
        }
    }

    init(caption: String, tint: NSColor, floorCeiling: Double) {
        self.tint = tint
        super.init(caption: caption)

        // Monospaced digits, or the number jogs sideways every two seconds as
        // the glyph widths change under it.
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        valueLabel.textColor = tint

        detailLabel.font = Style.Fonts.settingsNote
        detailLabel.textColor = Style.Colors.tertiaryText
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // The top of the graph, written where the top of the graph is. Without
        // it a line at half height means nothing: half of what?
        ceilingLabel.font = Style.Fonts.settingsNote
        ceilingLabel.textColor = Style.Colors.tertiaryText
        ceilingLabel.alignment = .right
        ceilingLabel.setAccessibilityElement(false)

        graph.tint = tint
        graph.floorCeiling = floorCeiling
        graph.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSStackView(views: [valueLabel, NSView(), ceilingLabel])
        heading.orientation = .horizontal
        heading.alignment = .lastBaseline
        heading.translatesAutoresizingMaskIntoConstraints = false

        body.addArrangedSubview(heading)
        body.addArrangedSubview(detailLabel)
        body.addArrangedSubview(graph)
        body.setCustomSpacing(8, after: detailLabel)
        NSLayoutConstraint.activate([
            heading.widthAnchor.constraint(equalTo: body.widthAnchor),
            detailLabel.widthAnchor.constraint(equalTo: body.widthAnchor),
            graph.widthAnchor.constraint(equalTo: body.widthAnchor),
            graph.heightAnchor.constraint(greaterThanOrEqualToConstant: 46)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("ActivityMetricCard is created in code only")
    }

    /// - Parameter ceilingSuffix: what the number at the top of the graph is
    ///   measured in -- "%" or "MB" -- since the same card draws both.
    func show(value: String, detail: String, history: UsageHistory, ceilingSuffix: String) {
        valueLabel.stringValue = value
        detailLabel.stringValue = detail
        detailLabel.toolTip = detail
        graph.show(history)
        ceilingLabel.stringValue = ceilingSuffix.isEmpty
            ? ""
            : "\(Int(graph.ceiling.rounded()))\(ceilingSuffix)"
        setAccessibilityLabel("\(value). \(detail)")
    }

    /// For the GPU card on a Mac whose driver publishes nothing. The card
    /// stays: one that came and went would be worse than one that says why it
    /// is empty.
    func showUnavailable(detail: String) {
        valueLabel.stringValue = "—"
        detailLabel.stringValue = detail
        ceilingLabel.stringValue = ""
        graph.show(UsageHistory())
        setAccessibilityLabel("Unavailable. \(detail)")
    }
}

/// A ranked list of bars: spaces by what they cost, or pages.
///
/// A bar per row rather than a pie, because the question is "which is the big
/// one and by how much", and a length answers that where an angle does not.
@MainActor
final class ActivityBarListView: NSView {
    private let rows = NSStackView()
    private let empty = NSTextField(labelWithString: "Nothing to show yet")

    /// Selecting a bar, for the chart of spaces: the bars double as a way in.
    var onSelect: ((UUID) -> Void)?
    var tint: NSColor = .controlAccentColor
    /// What stands in for the bars when there are none. Set by the scope, so
    /// an empty chart says why it is empty.
    var emptyMessage = "Nothing to show yet" {
        didSet { empty.stringValue = emptyMessage }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 7
        rows.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rows)

        empty.font = Style.Fonts.settingsNote
        empty.textColor = Style.Colors.tertiaryText
        empty.translatesAutoresizingMaskIntoConstraints = false
        empty.isHidden = true
        addSubview(empty)

        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: topAnchor),
            rows.leadingAnchor.constraint(equalTo: leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor),
            empty.topAnchor.constraint(equalTo: topAnchor),
            empty.leadingAnchor.constraint(equalTo: leadingAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("ActivityBarListView is created in code only")
    }

    func show(_ bars: [ActivityBar]) {
        // Rebuilt rather than updated in place. Two seconds is a long time
        // between frames and the set can change completely -- a space closed, a
        // new heaviest page -- so keeping row views around to reuse would be
        // bookkeeping in exchange for nothing a person could see.
        for view in rows.arrangedSubviews {
            rows.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        empty.isHidden = !bars.isEmpty
        for bar in bars {
            let row = BarRow(bar: bar, tint: tint) { [weak self] in self?.onSelect?(bar.id) }
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
    }

    /// A label, a track with a fill in it, and the number at the end.
    @MainActor
    private final class BarRow: NSView {
        private let bar: ActivityBar
        private let tint: NSColor
        private let onClick: () -> Void
        private var isHovered = false { didSet { needsDisplay = true } }
        private var trackingArea: NSTrackingArea?

        init(bar: ActivityBar, tint: NSColor, onClick: @escaping () -> Void) {
            self.bar = bar
            self.tint = tint
            self.onClick = onClick
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false

            let label = NSTextField(labelWithString: bar.label)
            label.font = Style.Fonts.settingsRow
            label.textColor = bar.isDimmed ? Style.Colors.tertiaryText : Style.Colors.primaryText
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let value = NSTextField(labelWithString: bar.caption)
            value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            value.textColor = Style.Colors.secondaryText
            value.alignment = .right
            value.setContentHuggingPriority(.required, for: .horizontal)

            let heading = NSStackView(views: [label, value])
            heading.orientation = .horizontal
            heading.alignment = .firstBaseline
            heading.translatesAutoresizingMaskIntoConstraints = false
            addSubview(heading)

            NSLayoutConstraint.activate([
                heading.topAnchor.constraint(equalTo: topAnchor),
                heading.leadingAnchor.constraint(equalTo: leadingAnchor),
                heading.trailingAnchor.constraint(equalTo: trailingAnchor),
                heightAnchor.constraint(equalToConstant: 30)
            ])
            setAccessibilityRole(.button)
            setAccessibilityLabel("\(bar.label), \(bar.caption)")
        }

        required init?(coder: NSCoder) {
            fatalError("BarRow is created in code only")
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) { isHovered = true }
        override func mouseExited(with event: NSEvent) { isHovered = false }

        override func mouseDown(with event: NSEvent) {
            if acceptsSpringPress { press.flick() }
            onClick()
        }

        override func accessibilityPerformPress() -> Bool {
            onClick()
            return true
        }

        private lazy var press = SpringPress(view: self)

        override func draw(_ dirtyRect: NSRect) {
            let track = NSRect(x: 0, y: 0, width: bounds.width, height: 6)
            let radius = track.height / 2
            Style.Colors.graphGrid.setFill()
            NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

            let width = max(track.height, track.width * CGFloat(min(max(bar.fraction, 0), 1)))
            let filled = NSRect(x: 0, y: 0, width: width, height: track.height)
            // A dimmed bar is one outside the scope you are in: still drawn, so
            // the comparison survives, but not competing with the one you
            // chose.
            let colour = bar.isDimmed ? tint.withAlphaComponent(0.28) : tint
            (isHovered ? colour.blended(withFraction: 0.2, of: .white) ?? colour : colour).setFill()
            NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
        }
    }
}

/// One bar cut into slices, with a legend under it.
///
/// For "where the memory goes": the app, the pages, the GPU helper. Three
/// numbers that add up to a fourth are the one case where a proportion says
/// more than three separate figures, and the one case a stacked bar is for.
@MainActor
final class ActivityCompositionView: NSView {
    private var slices: [ActivityBar] = []
    private let legend = NSStackView()
    /// The colours the slices take, in order. The same three every time, so
    /// the legend is learnable.
    private static let palette: [NSColor] = [.systemIndigo, .systemTeal, .systemPink]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        legend.orientation = .horizontal
        legend.alignment = .centerY
        legend.spacing = 14
        legend.translatesAutoresizingMaskIntoConstraints = false
        addSubview(legend)
        NSLayoutConstraint.activate([
            legend.leadingAnchor.constraint(equalTo: leadingAnchor),
            legend.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            legend.bottomAnchor.constraint(equalTo: bottomAnchor),
            legend.heightAnchor.constraint(equalToConstant: 16),
            heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("ActivityCompositionView is created in code only")
    }

    func show(_ slices: [ActivityBar]) {
        self.slices = slices
        for view in legend.arrangedSubviews {
            legend.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, slice) in slices.enumerated() {
            legend.addArrangedSubview(
                key(slice.label, value: slice.caption, colour: Self.palette[index % Self.palette.count])
            )
        }
        legend.addArrangedSubview(NSView())
        needsDisplay = true
        setAccessibilityLabel(slices.map { "\($0.label) \($0.caption)" }.joined(separator: ", "))
    }

    private func key(_ name: String, value: String, colour: NSColor) -> NSView {
        let dot = SettingsPlateView()
        dot.fill = colour
        dot.cornerRadius = 3
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6)
        ])
        let label = NSTextField(labelWithString: "\(name)  \(value)")
        label.font = Style.Fonts.settingsNote
        label.textColor = Style.Colors.secondaryText
        let row = NSStackView(views: [dot, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 5
        return row
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSRect(x: 0, y: bounds.height - 12, width: bounds.width, height: 12)
        let radius: CGFloat = 6
        Style.Colors.graphGrid.setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        guard !slices.isEmpty else { return }
        // Clipped to the rounded track, so the slices inherit its ends rather
        // than each needing a shape of its own.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).addClip()
        var x = track.minX
        for (index, slice) in slices.enumerated() {
            let width = track.width * CGFloat(min(max(slice.fraction, 0), 1))
            Self.palette[index % Self.palette.count].setFill()
            NSRect(x: x, y: track.minY, width: width, height: track.height).fill()
            x += width
            // A hairline of the card behind, so two slices of similar colour
            // do not read as one.
            Style.Colors.settingsCard.setFill()
            NSRect(x: x - 0.5, y: track.minY, width: 1, height: track.height).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// A run of label-and-number pairs, two to a line.
///
/// The detail a graph cannot carry: how many tabs, how many are asleep, how
/// many WebKit processes they are spread across, the worst the scope has been
/// in the last two minutes.
@MainActor
final class ActivityStatGridView: NSView {
    private let grid = NSGridView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 7
        grid.columnSpacing = 10
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("ActivityStatGridView is created in code only")
    }

    func show(_ pairs: [(String, String)]) {
        // Taking a row out of an `NSGridView` leaves its views in the view
        // hierarchy -- they stop being laid out and keep being drawn, so the
        // numbers pile up on top of each other, one refresh on top of the
        // last. The views have to go as well as the row.
        while grid.numberOfRows > 0 {
            let row = grid.row(at: 0)
            for index in 0..<row.numberOfCells {
                row.cell(at: index).contentView?.removeFromSuperview()
            }
            grid.removeRow(at: 0)
        }
        // Two pairs to a line: four rows of two reads faster than eight rows of
        // one, and the card stays the height of the chart beside it.
        for chunk in stride(from: 0, to: pairs.count, by: 2) {
            let left = pairs[chunk]
            let right = chunk + 1 < pairs.count ? pairs[chunk + 1] : nil
            grid.addRow(with: [
                name(left.0), number(left.1),
                name(right?.0 ?? ""), number(right?.1 ?? "")
            ])
        }
        setAccessibilityLabel(pairs.map { "\($0.0) \($0.1)" }.joined(separator: ", "))
    }

    private func name(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = Style.Fonts.settingsNote
        label.textColor = Style.Colors.tertiaryText
        return label
    }

    private func number(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        label.textColor = Style.Colors.primaryText
        return label
    }
}
