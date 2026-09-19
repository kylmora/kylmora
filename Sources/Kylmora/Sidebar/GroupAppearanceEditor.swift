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
    /// Everything the sheet settles before the folder exists.
    ///
    /// The same shape `NewSpaceOptions` has, and for the same reason: a folder
    /// made from a menu used to arrive with a name and nothing else, then
    /// needed two more trips through two more menus to get the mark and the
    /// colour it was always going to get.
    struct NewGroup: Equatable {
        var name: String
        var icon: FolderIcon
        var appearance: TabGroupAppearance
    }

    /// Which of the two jobs this panel is doing.
    ///
    /// One controller rather than two, because a new folder is settling
    /// exactly the things an existing one's editor already edits -- plus a
    /// name. A second sheet would be this one with a text field added and
    /// every colour control copied.
    private enum Mode: Equatable {
        /// Changing a folder that exists. Every move applies as it is made.
        case editing
        /// Making one. Nothing applies until Create.
        case creating
    }

    private let mode: Mode
    private let onChange: (TabGroupAppearance) -> Void
    private let onCreate: ((NewGroup) -> Void)?
    /// Editing only: the name was committed, or the mark changed. Both apply
    /// as they are made, like every colour control on the panel.
    private let onRename: ((String) -> Void)?
    private let onIcon: ((FolderIcon) -> Void)?
    private let nameField = PanelTextField(placeholder: "Folder name")
    private let iconWell = IconWell()
    private var icon: FolderIcon = .automatic
    /// The colour a half-set appearance falls back to -- the group's own tint --
    /// so the preview and the chips start on something real.
    private let tint: NSColor
    private var groupName: String

    private var appearance: TabGroupAppearance {
        didSet {
            guard appearance != oldValue else { return }
            // Nothing to apply to while the folder is still being described.
            if mode == .editing { onChange(appearance) }
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
    private let colourPicker = ColourPickerView()
    private var presetTiles: [SwatchTile] = []

    private var presetsRow = NSView()
    private var solidRow = NSView()
    private var colourRow = NSView()
    private var pickerRow = NSView()
    private var directionRow = NSView()
    private var colourChips: ColourChips!
    private var contentStack: NSStackView!

    /// Which chip the picker is driving, so its changes land on the right stop.
    private var editingEndColour = false
    /// Whether the picker is open. It lives in the panel, not in a window of
    /// its own -- see `ColourPickerView`.
    private var showsPicker = false

    /// - Parameters:
    ///   - icon: what the folder wears now. The panel edits it in place, the
    ///     same panel and the same well that put it there when the folder was
    ///     made -- a folder is described in one place whether it exists yet or
    ///     not.
    ///   - onRename: nil for a caller that does not want the name edited here.
    init(appearance: TabGroupAppearance, tint: NSColor, name: String,
         icon: FolderIcon = .automatic,
         onChange: @escaping (TabGroupAppearance) -> Void,
         onRename: ((String) -> Void)? = nil,
         onIcon: ((FolderIcon) -> Void)? = nil) {
        self.mode = .editing
        self.appearance = appearance
        self.tint = tint
        self.groupName = name
        self.icon = icon
        self.onChange = onChange
        self.onCreate = nil
        self.onRename = onRename
        self.onIcon = onIcon
        super.init(nibName: nil, bundle: nil)
    }

    /// The same panel as a New Folder sheet: a name and a mark on top of the
    /// colours, and nothing applied until Create.
    init(creatingWithTint tint: NSColor, onCreate: @escaping (NewGroup) -> Void) {
        self.mode = .creating
        self.appearance = .standard
        self.tint = tint
        self.groupName = ""
        self.onChange = { _ in }
        self.onCreate = onCreate
        self.onRename = nil
        self.onIcon = nil
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

        colourPicker.onChange = { [weak self] colour in self?.pickerChanged(colour) }

        colourChips = ColourChips(from: fromChip, to: toChip)
        solidRow = PanelStyle.section("Colours", solidPalette)
        pickerRow = PanelStyle.section("Custom colour", colourPicker)
        presetsRow = PanelStyle.section("Presets", makePresetGrid())
        colourRow = PanelStyle.section("Gradient colours", colourChips)
        directionRow = PanelStyle.section("Direction", directionPicker)

        // The name is in a field now, in both modes, so the heading says what
        // the panel is rather than repeating what is editable two rows down.
        let title = mode == .creating ? "New Folder" : "Folder"
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        heading.textColor = Style.Colors.primaryText
        heading.lineBreakMode = .byTruncatingTail

        let divider = PanelStyle.divider()

        // Editing ends whenever the user stops; making ends on a button, so
        // the foot of the panel is a different thing in each mode.
        let footer: NSView
        switch mode {
        case .editing:
            footer = PanelButton(title: "Reset to default", kind: .plain) { [weak self] in self?.reset() }
        case .creating:
            let create = PanelButton(title: "Create", kind: .primary) { [weak self] in self?.create() }
            let cancel = PanelButton(title: "Cancel", kind: .secondary) { [weak self] in self?.endSheetOrDismiss() }
            let buttons = NSStackView(views: [cancel, create])
            buttons.orientation = .horizontal
            buttons.spacing = 10
            buttons.distribution = .fillEqually
            footer = buttons
        }

        var sections: [NSView] = [heading]
        // In both modes. The panel that makes a folder and the panel that
        // changes one are the same panel; the only difference is when what it
        // settles takes effect.
        if mode == .creating || onRename != nil || onIcon != nil {
            sections.append(PanelStyle.section("Name", nameRow()))
        }
        sections += [
            preview,
            PanelStyle.section("Fill", fillPills),
            solidRow,
            presetsRow,
            colourRow,
            pickerRow,
            directionRow,
            PanelStyle.section("Edge", elevationPills),
            divider,
            footer
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

        let container = PanelBackdrop()
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

    /// The name and the mark on one line, the way the New Space sheet has it:
    /// the well sits where the folder's own icon will sit, before its name.
    private func nameRow() -> NSView {
        nameField.field.formatter = LimitedLengthFormatter(limit: Space.maximumNameLength)
        nameField.field.stringValue = groupName
        nameField.field.target = self
        nameField.field.action = #selector(nameCommitted)
        // On Return and on leaving the field, not on every keystroke: a folder
        // renamed letter by letter would redraw the sidebar under the panel
        // once per character.
        nameField.field.cell?.sendsActionOnEndEditing = true
        iconWell.onChange = { [weak self] choice in
            guard let self else { return }
            icon = FolderIcon(choice)
            showIcon()
            onIcon?(icon)
        }
        showIcon()
        let row = NSStackView(views: [iconWell, nameField])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    /// A name that is only whitespace is no name, so the field goes back to
    /// what the folder is still called rather than sitting there looking as
    /// though it were accepted -- the same reading the Spaces pane uses.
    @objc private func nameCommitted() {
        let typed = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else {
            nameField.field.stringValue = groupName
            return
        }
        groupName = typed
        onRename?(typed)
    }

    private func showIcon() {
        iconWell.show(image: icon.image(tint: tint), current: icon.asMenuChoice, color: tint)
    }

    private func create() {
        let typed = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        onCreate?(
            NewGroup(
                name: typed.isEmpty ? "New Folder" : typed,
                icon: icon,
                appearance: appearance
            )
        )
        endSheetOrDismiss()
    }

    /// What the sheet has settled, without pressing a button that dismisses a
    /// sheet nobody presented. For tests, as `NewSpaceSheet.chosenOptions` is.
    func chosenGroupForTesting() -> NewGroup {
        let typed = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return NewGroup(
            name: typed.isEmpty ? "New Folder" : typed,
            icon: icon,
            appearance: appearance
        )
    }

    /// The name field, so a sheet can put the caret in it.
    func focusName() {
        view.window?.makeFirstResponder(nameField.field)
    }

    // MARK: - Reaching the controls from a test
    //
    // The panel's own controls are private, and driving AppKit's text editing
    // and menus for real inside a test is a test of AppKit. These four say
    // "the user typed this", "the user committed it", "the user picked that
    // from the menu" -- which is the part worth pinning down.

    var nameForTesting: String { nameField.stringValue }

    func setNameForTesting(_ typed: String) {
        nameField.field.stringValue = typed
    }

    func commitNameForTesting() {
        nameCommitted()
    }

    func chooseIconForTesting(_ choice: IconMenu.Choice) {
        iconWell.onChange?(choice)
    }

    func setIconForTesting(_ icon: FolderIcon) {
        chooseIconForTesting(icon.asChoiceForTestingSupport)
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
        // An open picker follows the palette rather than contradicting it.
        if showsPicker && !editingEndColour { colourPicker.show(colour) }
    }

    private func choosePreset(_ preset: GradientPreset) {
        var next = appearance
        next.fill = .gradient
        next.startColorHex = preset.startHex
        next.endColorHex = preset.endHex
        next.direction = preset.direction
        appearance = next
        if showsPicker {
            colourPicker.show(
                editingEndColour ? appearance.endColor(fallback: tint) : appearance.startColor(fallback: tint)
            )
        }
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

    // MARK: - The colour picker

    /// Opens the picker on a stop, inside the panel. A second click on the
    /// same control closes it.
    private func openColourPanel(forEnd: Bool) {
        if showsPicker && editingEndColour == forEnd {
            showsPicker = false
        } else {
            editingEndColour = forEnd
            showsPicker = true
            colourPicker.show(
                forEnd ? appearance.endColor(fallback: tint) : appearance.startColor(fallback: tint)
            )
        }
        refresh()
    }

    private func pickerChanged(_ colour: NSColor) {
        var next = appearance
        // Picking a colour on a default group turns it solid, so a first pick
        // does something rather than being swallowed.
        if next.fill == .standard { next.fill = .solid }
        if editingEndColour {
            next.endColorValue = colour
            next.fill = .gradient
        } else {
            next.startColorValue = colour
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
        // The picker belongs to whichever stop it was opened on, so it closes
        // with the rows that offer that stop.
        if editingEndColour && !gradient { showsPicker = false }
        pickerRow.isHidden = !showsPicker
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
