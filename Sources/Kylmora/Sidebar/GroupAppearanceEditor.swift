import AppKit

/// The custom editor behind a group's three-dot: a live preview, a row of
/// one-tap gradient presets, and hand-drawn controls for fill, colours,
/// direction and edge -- none of them a stock `NSColorWell` or
/// `NSSegmentedControl`, so the whole panel reads as Kylmora's own chrome.
///
/// Every change applies immediately (there is no OK button): the preview at the
/// top and the sidebar behind the popover are both the preview. It reports a
/// whole `TabGroupAppearance` on each change and holds no reference to the
/// group, so the caller owns when a change is saved.
@MainActor
final class GroupAppearanceEditor: NSViewController {
    private let onChange: (TabGroupAppearance) -> Void
    /// The colour a half-set appearance falls back to -- the group's own tint --
    /// so the preview and the chips start on something real.
    private let tint: NSColor
    private let groupName: String

    private var appearance: TabGroupAppearance {
        didSet {
            guard appearance != oldValue else { return }
            onChange(appearance)
            refresh()
        }
    }

    private let preview = ThemePreview()
    private let fillPills = SegmentedPills(titles: ["Default", "Solid", "Gradient"])
    private let elevationPills = SegmentedPills(titles: ["Flat", "Soft", "Bold"])
    private let directionPicker = DirectionPicker()
    private let fromChip = ColorChip(label: "Start colour")
    private let toChip = ColorChip(label: "End colour")
    private let solidPalette = SolidPalette()
    private var presetTiles: [SwatchTile] = []

    private var presetsRow = NSView()
    private var solidRow = NSView()
    private var colourRow = NSView()
    private var directionRow = NSView()
    private var colourChips: ColourChips!
    private var contentStack: NSStackView!

    /// Which chip the colour panel is driving, so its changes land on the right
    /// stop. Nil when the panel is not ours.
    private var editingEndColour = false

    init(appearance: TabGroupAppearance, tint: NSColor, name: String,
         onChange: @escaping (TabGroupAppearance) -> Void) {
        self.appearance = appearance
        self.tint = tint
        self.groupName = name
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("GroupAppearanceEditor is created in code only")
    }

    private static let presets = GradientPreset.all

    // MARK: - Layout

    override func loadView() {
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.heightAnchor.constraint(equalToConstant: 96).isActive = true

        fillPills.onSelect = { [weak self] index in self?.chooseFill(index) }
        elevationPills.onSelect = { [weak self] index in self?.chooseElevation(index) }
        directionPicker.onSelect = { [weak self] direction in self?.choose(direction: direction) }
        fromChip.onClick = { [weak self] in self?.openColourPanel(forEnd: false) }
        toChip.onClick = { [weak self] in self?.openColourPanel(forEnd: true) }

        solidPalette.onPick = { [weak self] colour in self?.chooseSolid(colour) }
        solidPalette.onCustom = { [weak self] in self?.openColourPanel(forEnd: false) }

        colourChips = ColourChips(from: fromChip, to: toChip)
        solidRow = PanelStyle.section("Colours", solidPalette)
        presetsRow = PanelStyle.section("Presets", makePresetGrid())
        colourRow = PanelStyle.section("Gradient colours", colourChips)
        directionRow = PanelStyle.section("Direction", directionPicker)

        let heading = NSTextField(labelWithString: groupName.isEmpty ? "Group" : groupName)
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        heading.textColor = Style.Colors.primaryText
        heading.lineBreakMode = .byTruncatingTail

        let reset = PanelButton(title: "Reset to default", kind: .plain) { [weak self] in self?.reset() }
        let divider = PanelStyle.divider()

        let sections: [NSView] = [
            heading,
            preview,
            PanelStyle.section("Fill", fillPills),
            solidRow,
            presetsRow,
            colourRow,
            directionRow,
            PanelStyle.section("Edge", elevationPills),
            divider,
            reset
        ]
        let stack = NSStackView(views: sections)
        contentStack = stack
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = PanelStyle.sectionGap
        stack.setCustomSpacing(14, after: heading)
        stack.setCustomSpacing(12, after: divider)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Everything but the heading and the plain reset button spans the panel.
        for section in sections where section === preview || section is NSStackView {
            section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        divider.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: PanelStyle.width),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: PanelStyle.inset),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -PanelStyle.inset),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: PanelStyle.inset),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -PanelStyle.inset)
        ])
        view = container
        refresh()
    }

    /// The eight preset gradients, two rows of four, filling the section width.
    private func makePresetGrid() -> NSView {
        var tiles: [NSView] = []
        for preset in Self.presets {
            let start = NSColor(hexString: preset.startHex) ?? tint
            let end = NSColor(hexString: preset.endHex) ?? tint
            let tile = SwatchTile(look: .gradient(start, end, preset.direction.angle), label: preset.name)
            tile.onClick = { [weak self] in self?.choosePreset(preset) }
            presetTiles.append(tile)
            tiles.append(tile)
        }
        let top = NSStackView(views: Array(tiles.prefix(4)))
        let bottom = NSStackView(views: Array(tiles.suffix(from: 4)))
        for line in [top, bottom] {
            line.orientation = .horizontal
            line.spacing = 8
            line.distribution = .fillEqually
        }
        let column = NSStackView(views: [top, bottom])
        column.orientation = .vertical
        column.spacing = 8
        column.alignment = .leading
        column.translatesAutoresizingMaskIntoConstraints = false
        top.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        bottom.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return column
    }

    // MARK: - Choices

    private func chooseFill(_ index: Int) {
        var next = appearance
        switch index {
        case 1: next.fill = .solid
        case 2: next.fill = .gradient
        default: next.fill = .standard
        }
        // A fresh colour starts on the group's tint; a fresh gradient's second
        // stop is a darker shade so it reads as a gradient at once.
        if next.fill != .standard, next.startColorHex == nil {
            next.startColorValue = tint
        }
        if next.fill == .gradient, next.endColorHex == nil {
            next.endColorValue = next.startColor(fallback: tint).blended(withFraction: 0.4, of: .black) ?? tint
        }
        appearance = next
    }

    private func chooseSolid(_ colour: NSColor) {
        var next = appearance
        next.fill = .solid
        next.startColorValue = colour
        appearance = next
    }

    private func choosePreset(_ preset: GradientPreset) {
        var next = appearance
        next.fill = .gradient
        next.startColorHex = preset.startHex
        next.endColorHex = preset.endHex
        next.direction = preset.direction
        appearance = next
    }

    private func choose(direction: TabGroupAppearance.Direction) {
        var next = appearance
        next.direction = direction
        appearance = next
    }

    private func chooseElevation(_ index: Int) {
        let all = TabGroupAppearance.Elevation.allCases
        guard all.indices.contains(index) else { return }
        var next = appearance
        next.elevation = all[index]
        appearance = next
    }

    @objc private func reset() {
        appearance = .standard
    }

    // MARK: - Colour panel

    private func openColourPanel(forEnd: Bool) {
        editingEndColour = forEnd
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(panelColourChanged(_:)))
        panel.showsAlpha = false
        panel.color = forEnd ? appearance.endColor(fallback: tint) : appearance.startColor(fallback: tint)
        panel.orderFront(nil)
    }

    @objc private func panelColourChanged(_ panel: NSColorPanel) {
        var next = appearance
        // Picking a colour on a default group turns it solid, so a first pick
        // does something rather than being swallowed.
        if next.fill == .standard { next.fill = .solid }
        if editingEndColour {
            next.endColorValue = panel.color
            next.fill = .gradient
        } else {
            next.startColorValue = panel.color
        }
        appearance = next
    }

    // MARK: - Sync

    /// Writes the current appearance onto every control and shows only the rows
    /// the chosen fill uses.
    private func refresh() {
        preview.show(appearance, tint: tint)
        let fillIndex: Int
        switch appearance.fill {
        case .standard: fillIndex = 0
        case .solid: fillIndex = 1
        case .gradient: fillIndex = 2
        }
        fillPills.select(fillIndex)
        elevationPills.select(TabGroupAppearance.Elevation.allCases.firstIndex(of: appearance.elevation) ?? 0)
        directionPicker.select(appearance.direction)
        fromChip.color = appearance.startColor(fallback: tint)
        toChip.color = appearance.endColor(fallback: tint)

        // The active preset, if the colours match one exactly.
        for (tile, preset) in zip(presetTiles, Self.presets) {
            tile.isSelected = appearance.fill == .gradient
                && appearance.startColorHex?.lowercased() == preset.startHex
                && appearance.endColorHex?.lowercased() == preset.endHex
        }

        let solid = appearance.fill == .solid
        let gradient = appearance.fill == .gradient
        // Solid picks from the colour palette; Gradient gets the presets, its
        // two-stop chips and a direction.
        solidRow.isHidden = !solid
        presetsRow.isHidden = !gradient
        colourRow.isHidden = !gradient
        directionRow.isHidden = !gradient
        colourChips.showsEnd(gradient)
        if solid { solidPalette.select(appearance.startColor(fallback: tint)) }

        // Hidden sections change the content's height; the popover resizes to
        // follow rather than leaving its stack stretched with gaps. The stack's
        // own fitting size is the true content height (the container's reports
        // whatever height it is currently given).
        guard isViewLoaded, let contentStack else { return }
        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(
            width: PanelStyle.width,
            height: contentStack.fittingSize.height + 2 * PanelStyle.inset
        )
    }
}

/// The two colour chips with an arrow between, left-aligned under the `Colours`
/// caption. The arrow and the end chip hide together for a solid fill, which
/// has only one colour.
@MainActor
final class ColourChips: NSView {
    private let arrow = NSTextField(labelWithString: "→")
    private let to: ColorChip

    init(from: ColorChip, to: ColorChip) {
        self.to = to
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        arrow.font = .systemFont(ofSize: 13)
        arrow.textColor = Style.Colors.tertiaryText
        let stack = NSStackView(views: [from, arrow, to])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("ColourChips is created in code only") }

    /// Shows the second colour, or hides it and the arrow for a solid fill.
    func showsEnd(_ shows: Bool) {
        arrow.isHidden = !shows
        to.isHidden = !shows
    }
}
