import AppKit

/// What a new space is washed with, chosen in the New Space sheet.
enum SpaceWashChoice: Equatable {
    /// One flat colour.
    ///
    /// A new space starts here, on the colour the palette would have handed it
    /// anyway, so there is no third "Auto" fill: the Spaces pane offers Solid
    /// and Gradient, and choosing a colour is what Customized is for.
    case solid(NSColor)
    /// A two-stop gradient.
    case gradient(SpaceGradient)
}

/// Everything the New Space sheet settles before the space exists.
///
/// A struct rather than a longer closure: the sheet used to hand back three
/// loose values, and every setting added to it changed the shape of the call.
/// The things here are the ones worth deciding while you are naming a space --
/// what it looks like and what it keeps -- and each is a field the Spaces pane
/// already edits afterwards.
struct NewSpaceOptions: Equatable {
    var name: String
    var isPrivate: Bool
    var wash: SpaceWashChoice
    /// Light, dark, or whatever the General pane says.
    var appearance: SpaceAppearanceChoice
    /// How strongly the space's colour washes the chrome, 0...1.
    var washOpacity: Double
    var showsBookmarksBar: Bool

    /// The look this asks for, ready to hand to the session.
    func look(from existing: SpaceLook) -> SpaceLook {
        var look = existing
        // The same three moves the Spaces pane makes for each choice: a preset
        // fixes light or dark and lets no page colour the window; Customized
        // and Website both follow the system, and Website hands the wash to the
        // page. See `SpaceAppearanceChoice`.
        look.appearance = appearance.presetAppearance ?? .system
        look.allowsWebsiteThemeColor = appearance == .website
        look.washOpacity = washOpacity
        look.showsBookmarksBar = showsBookmarksBar
        return look
    }

    /// Whether the space keeps a colour of its own. A preset and Website both
    /// leave it untinted, which is `neutral` -- the pane does the same.
    var keepsItsOwnColour: Bool { appearance == .customized }
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
    var onCreate: ((NewSpaceOptions) -> Void)?

    private let nameField = PanelTextField(placeholder: "Space name")
    private let privateToggle = PanelToggle(isOn: false)
    /// Fill, as the Spaces pane has it: Solid or Gradient, and only under
    /// Customized.
    private let stylePills = SegmentedPills(titles: ["Solid", "Gradient"])
    /// Appearance, as the Spaces pane asks it: the same five choices, under the
    /// same names, from the same type, in the same kind of control. They do not
    /// fit one line of a 300-point sheet, so the pills wrap -- see
    /// `SegmentedPills`.
    private let appearancePills = SegmentedPills(
        titles: SpaceAppearanceChoice.allCases.map(\.title)
    )
    /// Transparency, again as the pane has it: a slider from 0 to 100 and the
    /// percentage beside it.
    private let transparencySlider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let transparencyValue = NSTextField(labelWithString: "0%")
    private let bookmarksToggle = PanelToggle(isOn: false)
    private let preview = SpacePreviewView()
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
    private var transparencyRow = NSView()
    private var styleRow = NSView()
    private var contentStack: NSStackView!

    /// The default the auto/solid colour starts on: the colour the space would
    /// have been given anyway.
    private let suggested: NSColor

    private var styleIndex = 0
    private var appearanceChoice: SpaceAppearanceChoice = .customized
    private var startColour: NSColor
    private var endColour: NSColor
    private var direction: GradientDirection = .down
    private var editingEndColour = false

    private let initialPrivate: Bool

    /// How wide the sheet is.
    ///
    /// Wider than `PanelStyle.width`, and by exactly as much as its widest row
    /// needs: Appearance offers the same five choices the Spaces pane does, and
    /// "Automatic, Light, Dark, Customized, Website" does not fit 300 points.
    /// The card is made to fit the words rather than the words made to fit the
    /// card. Only this sheet is widened; the group panel keeps its own width.
    static var width: CGFloat {
        max(
            PanelStyle.width,
            SegmentedPills.width(forTitles: SpaceAppearanceChoice.allCases.map(\.title))
                + PanelStyle.inset * 2
        )
    }

    init(suggestedColor: NSColor, initialPrivate: Bool = false,
         onCreate: @escaping (NewSpaceOptions) -> Void) {
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
        appearancePills.onSelect = { [weak self] index in
            self?.appearanceChoice = SpaceAppearanceChoice(rawValue: index) ?? .customized
            self?.refresh()
        }
        transparencySlider.target = self
        transparencySlider.action = #selector(transparencyChanged)
        transparencySlider.translatesAutoresizingMaskIntoConstraints = false
        transparencyValue.font = .systemFont(ofSize: 11)
        transparencyValue.textColor = Style.Colors.tertiaryText
        transparencyValue.alignment = .right
        transparencyValue.translatesAutoresizingMaskIntoConstraints = false
        transparencyValue.widthAnchor.constraint(equalToConstant: 40).isActive = true
        // The preview carries the name as it is typed, so the card is the
        // space being made rather than a generic swatch.
        nameField.field.delegate = self
        directionPicker.onSelect = { [weak self] direction in self?.direction = direction; self?.refresh() }
        fromChip.onClick = { [weak self] in self?.openColourPanel(forEnd: false) }
        toChip.onClick = { [weak self] in self?.openColourPanel(forEnd: true) }

        solidPalette.onPick = { [weak self] colour in self?.chooseSolid(colour) }
        solidPalette.onCustom = { [weak self] in self?.openColourPanel(forEnd: false) }

        colourChips = ColourChips(from: fromChip, to: toChip)
        solidRow = PanelStyle.section("Colours", solidPalette)
        presetsRow = PanelStyle.section("Presets", makePresetGrid())
        colourRow = PanelStyle.section("Gradient colours", colourChips)
        let transparency = NSStackView(views: [transparencySlider, transparencyValue])
        transparency.orientation = .horizontal
        transparency.alignment = .centerY
        transparency.spacing = 8
        transparencyRow = PanelStyle.section("Transparency", transparency)
        styleRow = PanelStyle.section("Fill", stylePills)
        directionRow = PanelStyle.section("Direction", directionPicker)

        let create = PanelButton(title: "Create", kind: .primary) { [weak self] in self?.create() }
        let cancel = PanelButton(title: "Cancel", kind: .secondary) { [weak self] in self?.cancel() }
        let buttons = NSStackView(views: [cancel, create])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.distribution = .fillEqually

        // A name longer than a space may keep cannot be typed here, rather
        // than being accepted and quietly cut when the space is made.
        nameField.field.formatter = LimitedLengthFormatter(limit: Space.maximumNameLength)

        let divider = PanelStyle.divider()
        let sections: [NSView] = [
            heading,
            PanelStyle.section("Name", nameField),
            makePrivateRow(),
            PanelStyle.section("Preview", preview),
            PanelStyle.section("Appearance", appearancePills),
            styleRow,
            solidRow,
            presetsRow,
            colourRow,
            directionRow,
            transparencyRow,
            makeBookmarksRow(),
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

        for section in sections where section === buttons || section is NSStackView {
            section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        divider.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Self.width),
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

    /// Whether the new space opens with a bookmarks bar, in the same shape as
    /// the private row above it.
    private func makeBookmarksRow() -> NSView {
        let title = NSTextField(labelWithString: "Bookmarks bar")
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.textColor = Style.Colors.primaryText
        let subtitle = NSTextField(labelWithString: "Shown under the toolbar in this space")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = Style.Colors.tertiaryText
        let text = NSStackView(views: [title, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let row = NSStackView(views: [text, bookmarksToggle])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bookmarksToggle.setContentHuggingPriority(.required, for: .horizontal)
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
        styleIndex = 0
        startColour = colour
        refresh()
    }

    private func choosePreset(_ preset: GradientPreset) {
        styleIndex = 1
        startColour = NSColor(hexString: preset.startHex) ?? suggested
        endColour = NSColor(hexString: preset.endHex) ?? suggested
        direction = preset.direction
        refresh()
    }

    private func openColourPanel(forEnd: Bool) {
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
            styleIndex = 1
        } else {
            startColour = panel.color
        }
        refresh()
    }

    private func currentChoice() -> SpaceWashChoice {
        styleIndex == 1
            ? .gradient(SpaceGradient(
                startHex: startColour.hexString,
                endHex: endColour.hexString,
                direction: direction
            ))
            : .solid(startColour)
    }

    /// Chooses an appearance as a click on the pills would, so a test can
    /// exercise what each choice shows without driving the control.
    func chooseAppearanceForTesting(_ choice: SpaceAppearanceChoice) {
        appearanceChoice = choice
        refresh()
    }

    @objc private func transparencyChanged() {
        refresh()
    }

    private func create() {
        onCreate?(chosenOptions())
        dismiss(self)
    }

    /// Everything the sheet has settled, as one value.
    ///
    /// Separate from `create` so a test can read it without pressing a button
    /// that dismisses a sheet nobody presented.
    func chosenOptions() -> NewSpaceOptions {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return NewSpaceOptions(
            name: name.isEmpty ? "New Space" : name,
            isPrivate: privateToggle.isOn,
            wash: currentChoice(),
            appearance: appearanceChoice,
            // The pane's slider is transparency: 0% is the full wash, 100%
            // fades it away. What a space stores is the wash, so it is the
            // other way up.
            washOpacity: 1 - transparencySlider.doubleValue / 100,
            showsBookmarksBar: bookmarksToggle.isOn
        )
    }

    private func cancel() {
        dismiss(self)
    }

    /// Just the name, without the full `refresh`: that one resizes the sheet,
    /// and a sheet that resizes on every keystroke is a sheet that jitters.
    fileprivate func refreshPreviewName() {
        preview.look = previewLook()
    }

    /// What the preview is showing: everything the sheet has settled, in the
    /// order the window applies it.
    ///
    /// A space with no colour of its own -- a plain preset, or one waiting for
    /// a page to colour it -- passes no wash at all, which is what makes Light
    /// draw a plain light window rather than a tinted one.
    private func previewLook() -> SpacePreviewLook {
        let typed = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = chosenOptions()
        return SpacePreviewLook(
            appearance: options.appearance.presetAppearance ?? .system,
            wash: options.keepsItsOwnColour ? options.wash : nil,
            washOpacity: options.washOpacity,
            followsPageColour: options.appearance == .website,
            title: typed.isEmpty ? "New Space" : typed,
            tab: "New Tab"
        )
    }

    // MARK: - Sync

    private func refresh() {
        stylePills.select(styleIndex)
        appearancePills.select(appearanceChoice.rawValue)
        transparencyValue.stringValue = "\(Int(transparencySlider.doubleValue.rounded()))%"
        preview.look = previewLook()
        directionPicker.select(direction)
        fromChip.color = startColour
        toChip.color = endColour

        // Auto takes the colour the palette hands out, so it shows no colour
        // controls. Solid picks from the colour palette; Gradient gets the
        // presets, its two-stop chips and a direction.
        // Exactly as the pane hides them: a colour to pick, and a wash to
        // fade, belong to a space that has a colour of its own.
        let customised = appearanceChoice == .customized
        styleRow.isHidden = !customised
        transparencyRow.isHidden = !customised
        let solid = customised && styleIndex == 0
        let gradient = customised && styleIndex == 1
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
        let target = NSSize(width: Self.width, height: height)
        preferredContentSize = target
        view.window?.setContentSize(target)
    }
}

extension NewSpaceSheet: NSTextFieldDelegate {
    /// Every keystroke, so the preview says the name as it is being typed.
    func controlTextDidChange(_ notification: Notification) {
        refreshPreviewName()
    }
}
