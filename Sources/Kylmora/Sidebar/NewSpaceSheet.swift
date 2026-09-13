import AppKit

/// What a new space is washed with, chosen in the New Space sheet.
enum SpaceWashChoice: Equatable {
    /// The next colour the palette hands out; no custom wash.
    case theme
    /// One flat colour.
    case solid(NSColor)
    /// A two-stop gradient.
    case gradient(SpaceGradient)
}

/// The sheet that makes a space: a name, whether it is private, and its colour
/// -- solid or a gradient with a direction, the same picker a group gets.
///
/// The colour is chosen up front rather than left to the settings pane because
/// a space *is* its colour at a glance, so the moment it is made is the
/// moment to pick one. Unlike the group editor this does not apply live --
/// there is no space yet to wash -- so the preview card carries the whole
/// preview and the choice lands on `Create`.
@MainActor
final class NewSpaceSheet: NSViewController {
    var onCreate: ((_ name: String, _ isPrivate: Bool, _ choice: SpaceWashChoice) -> Void)?

    private let nameField = PanelTextField(placeholder: "Space name")
    private let privateToggle = PanelToggle(isOn: false)
    private let stylePills = SegmentedPills(titles: ["Auto", "Solid", "Gradient"])
    private let preview = ThemePreview()
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

    /// The default the auto/solid colour starts on: the colour the space would
    /// have been given anyway.
    private let suggested: NSColor

    private var styleIndex = 0
    private var startColour: NSColor
    private var endColour: NSColor
    private var direction: GradientDirection = .down
    private var editingEndColour = false

    private let initialPrivate: Bool

    init(suggestedColor: NSColor, initialPrivate: Bool = false,
         onCreate: @escaping (String, Bool, SpaceWashChoice) -> Void) {
        self.suggested = suggestedColor
        self.startColour = suggestedColor
        self.endColour = suggestedColor.blended(withFraction: 0.4, of: .black) ?? suggestedColor
        self.initialPrivate = initialPrivate
        self.onCreate = onCreate
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("NewSpaceSheet is created in code only") }

    override func loadView() {
        let heading = NSTextField(labelWithString: "New Space")
        heading.font = .systemFont(ofSize: 17, weight: .bold)
        heading.textColor = Style.Colors.primaryText

        privateToggle.setOn(initialPrivate)

        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.heightAnchor.constraint(equalToConstant: 92).isActive = true

        stylePills.onSelect = { [weak self] index in self?.chooseStyle(index) }
        directionPicker.onSelect = { [weak self] direction in self?.direction = direction; self?.refresh() }
        fromChip.onClick = { [weak self] in self?.openColourPanel(forEnd: false) }
        toChip.onClick = { [weak self] in self?.openColourPanel(forEnd: true) }

        solidPalette.onPick = { [weak self] colour in self?.chooseSolid(colour) }
        solidPalette.onCustom = { [weak self] in self?.openColourPanel(forEnd: false) }

        colourChips = ColourChips(from: fromChip, to: toChip)
        solidRow = PanelStyle.section("Colours", solidPalette)
        presetsRow = PanelStyle.section("Presets", makePresetGrid())
        colourRow = PanelStyle.section("Gradient colours", colourChips)
        directionRow = PanelStyle.section("Direction", directionPicker)

        let create = PanelButton(title: "Create", kind: .primary) { [weak self] in self?.create() }
        let cancel = PanelButton(title: "Cancel", kind: .secondary) { [weak self] in self?.cancel() }
        let buttons = NSStackView(views: [cancel, create])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.distribution = .fillEqually

        let divider = PanelStyle.divider()
        let sections: [NSView] = [
            heading,
            PanelStyle.section("Name", nameField),
            makePrivateRow(),
            preview,
            PanelStyle.section("Colour style", stylePills),
            solidRow,
            presetsRow,
            colourRow,
            directionRow,
            divider,
            buttons
        ]
        let stack = NSStackView(views: sections)
        contentStack = stack
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = PanelStyle.sectionGap
        stack.setCustomSpacing(18, after: heading)
        stack.setCustomSpacing(12, after: divider)
        stack.translatesAutoresizingMaskIntoConstraints = false

        for section in sections where section === preview || section === buttons || section is NSStackView {
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

    override func viewDidAppear() {
        super.viewDidAppear()
        resizeToFit()
        view.window?.makeFirstResponder(nameField.field)
    }

    /// A title and subtitle on the left, the toggle on the right -- one row,
    /// full width.
    private func makePrivateRow() -> NSView {
        let title = NSTextField(labelWithString: "Private space")
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.textColor = Style.Colors.primaryText
        let subtitle = NSTextField(labelWithString: "Nothing is written to disk")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = Style.Colors.tertiaryText
        let text = NSStackView(views: [title, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let row = NSStackView(views: [text, privateToggle])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        privateToggle.setContentHuggingPriority(.required, for: .horizontal)
        return row
    }

    /// The eight preset gradients, two rows of four, filling the section width.
    private func makePresetGrid() -> NSView {
        var tiles: [NSView] = []
        for preset in GradientPreset.all {
            let start = NSColor(hexString: preset.startHex) ?? suggested
            let end = NSColor(hexString: preset.endHex) ?? suggested
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

    private func chooseStyle(_ index: Int) {
        styleIndex = index
        refresh()
    }

    private func chooseSolid(_ colour: NSColor) {
        styleIndex = 1
        startColour = colour
        refresh()
    }

    private func choosePreset(_ preset: GradientPreset) {
        styleIndex = 2
        startColour = NSColor(hexString: preset.startHex) ?? suggested
        endColour = NSColor(hexString: preset.endHex) ?? suggested
        direction = preset.direction
        refresh()
    }

    private func openColourPanel(forEnd: Bool) {
        // A colour on the Auto style turns it Solid, so a first pick sticks.
        if styleIndex == 0 { styleIndex = 1 }
        editingEndColour = forEnd
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(panelColourChanged(_:)))
        panel.showsAlpha = false
        panel.color = forEnd ? endColour : startColour
        panel.orderFront(nil)
    }

    @objc private func panelColourChanged(_ panel: NSColorPanel) {
        if editingEndColour {
            endColour = panel.color
            styleIndex = 2
        } else {
            startColour = panel.color
            if styleIndex == 0 { styleIndex = 1 }
        }
        refresh()
    }

    private func currentChoice() -> SpaceWashChoice {
        switch styleIndex {
        case 1: return .solid(startColour)
        case 2: return .gradient(SpaceGradient(startHex: startColour.hexString, endHex: endColour.hexString, direction: direction))
        default: return .theme
        }
    }

    private func create() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        onCreate?(name.isEmpty ? "New Space" : name, privateToggle.isOn, currentChoice())
        dismiss(self)
    }

    private func cancel() {
        dismiss(self)
    }

    // MARK: - Sync

    private func refresh() {
        stylePills.select(styleIndex)
        directionPicker.select(direction)
        fromChip.color = startColour
        toChip.color = endColour

        // The preview shows the chosen colour: a solid for Auto and Solid, the
        // gradient for Gradient.
        let appearance: TabGroupAppearance = styleIndex == 2
            ? TabGroupAppearance(fill: .gradient, startColorHex: startColour.hexString, endColorHex: endColour.hexString, direction: direction)
            : TabGroupAppearance(fill: .solid, startColorHex: startColour.hexString)
        preview.show(appearance, tint: suggested)

        // Auto takes the colour the palette hands out, so it shows no colour
        // controls. Solid picks from the colour palette; Gradient gets the
        // presets, its two-stop chips and a direction.
        let solid = styleIndex == 1
        let gradient = styleIndex == 2
        solidRow.isHidden = !solid
        presetsRow.isHidden = !gradient
        colourRow.isHidden = !gradient
        directionRow.isHidden = !gradient
        colourChips.showsEnd(gradient)
        if solid { solidPalette.select(startColour) }
        for (tile, preset) in zip(presetTiles, GradientPreset.all) {
            tile.isSelected = gradient
                && startColour.hexString == preset.startHex
                && endColour.hexString == preset.endHex
        }

        resizeToFit()
    }

    /// Hidden sections change the content's height; the sheet's own window has
    /// to follow. `preferredContentSize` grows a sheet but will not shrink it,
    /// so the window is resized directly, its top edge kept in place.
    private func resizeToFit() {
        guard isViewLoaded, let contentStack else { return }
        view.layoutSubtreeIfNeeded()
        // The container's own `fittingSize` reports whatever height the sheet
        // window forces on it; the stack's fitting size is the true content
        // height, with hidden sections collapsed. Size the sheet to that.
        let height = contentStack.fittingSize.height + 2 * PanelStyle.inset
        let target = NSSize(width: PanelStyle.width, height: height)
        preferredContentSize = target
        view.window?.setContentSize(target)
    }
}
