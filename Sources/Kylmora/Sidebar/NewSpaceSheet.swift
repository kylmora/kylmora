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
    /// The emoji, symbol or picture the space is born wearing. Decided here
    /// rather than only afterwards in Settings because naming a space and
    /// marking it are the same thought.
    var icon: SpaceIcon = .automatic
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
    private let iconWell = IconWell()
    /// What the well is showing. Held rather than read back off the well,
    /// because the well is a view and this is the sheet's answer.
    private var icon: SpaceIcon = .automatic
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
    private let colourPicker = ColourPickerView()
    private var presetTiles: [SwatchTile] = []

    private var presetsRow = NSView()
    private var solidRow = NSView()
    private var colourRow = NSView()
    private var directionRow = NSView()
    private var colourChips: ColourChips!
    private var transparencyRow = NSView()
    private var styleRow = NSView()
    private var pickerRow = NSView()
    private var contentStack: NSStackView!
    private var heading: NSTextField!
    private var footer: NSStackView!
    private var scroll: NSScrollView!
    /// The sheet's own scroll indicator: a 3-point hairline down the right
    /// edge, there the whole time the sections overflow.
    ///
    /// The system's scroller is an overlay -- fat, grey, and only on screen
    /// while the wheel is turning -- so at rest a sheet with more to read
    /// looked exactly like one without, and in motion it sat on top of the
    /// controls. This one says the same thing without touching anything.
    private let indicator = SlimScrollIndicator()

    /// Between the heading and the first section.
    private static let headingGap: CGFloat = 18

    /// A stack that fills from the top: an `NSScrollView`'s document view sits
    /// at the bottom-left otherwise, so the sections would hang off the bottom
    /// of the clip and the first one would be cut off the moment they are
    /// taller than the sheet.
    private final class TopDownStackView: NSStackView {
        override var isFlipped: Bool { true }
    }

    /// The default the auto/solid colour starts on: the colour the space would
    /// have been given anyway.
    private let suggested: NSColor

    private var styleIndex = 0
    private var appearanceChoice: SpaceAppearanceChoice = .customized
    private var startColour: NSColor
    private var endColour: NSColor
    private var direction: GradientDirection = .down
    private var editingEndColour = false
    /// Whether the picker is open, and on which stop.
    ///
    /// Open from the start: the colour a new space is given is one the palette
    /// suggested, not one of the twelve, so the wheel comes up ringed -- and a
    /// ringed wheel with nothing under it looks like a control that did
    /// nothing. The picker is part of the sheet, so it is there when the sheet
    /// is. Clicking the wheel (or a gradient chip) closes and reopens it.
    private var showsPicker = true

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
        preview.heightAnchor.constraint(equalToConstant: 80).isActive = true

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

        colourPicker.onChange = { [weak self] colour in self?.pickerChanged(colour) }
        colourPicker.show(startColour)

        colourChips = ColourChips(from: fromChip, to: toChip)
        solidRow = PanelStyle.section("Colours", solidPalette)
        pickerRow = PanelStyle.section("Custom colour", colourPicker)
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
        // Everything between the heading and the buttons scrolls; the heading
        // and the buttons themselves do not, so Cancel and Create are always
        // where you left them however tall the sections turn out to be.
        let sections: [NSView] = [
            PanelStyle.section("Name", nameRow()),
            makePrivateRow(),
            PanelStyle.section("Preview", preview),
            PanelStyle.section("Appearance", appearancePills),
            styleRow,
            solidRow,
            presetsRow,
            colourRow,
            pickerRow,
            directionRow,
            transparencyRow,
            makeBookmarksRow()
        ]
        let stack = TopDownStackView(views: sections)
        contentStack = stack
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = PanelStyle.sectionGap
        stack.translatesAutoresizingMaskIntoConstraints = false

        for section in sections where section is NSStackView {
            section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let scroll = NSScrollView()
        self.scroll = scroll
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        // Ours instead of the system's; see `indicator`.
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .none
        scroll.documentView = stack
        // A scroll view has no size of its own to defend: it is the one thing
        // in the sheet that gives way when the cap bites.
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let footer = NSStackView(views: [divider, buttons])
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 12
        footer.translatesAutoresizingMaskIntoConstraints = false
        self.footer = footer
        self.heading = heading
        heading.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true
        buttons.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true

        let container = NSView()
        container.addSubview(heading)
        container.addSubview(scroll)
        container.addSubview(indicator)
        container.addSubview(footer)
        let inset = PanelStyle.inset
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Self.width),

            heading.topAnchor.constraint(equalTo: container.topAnchor, constant: inset),
            heading.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -inset),

            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: Self.headingGap),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),

            footer.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: PanelStyle.sectionGap),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -inset),

            indicator.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            indicator.topAnchor.constraint(equalTo: scroll.topAnchor),
            indicator.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            indicator.widthAnchor.constraint(equalToConstant: SlimScrollIndicator.width),

            // The sections are as wide as the clip less the indicator's lane,
            // so nothing is ever drawn under it.
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.widthAnchor.constraint(
                equalTo: scroll.contentView.widthAnchor,
                constant: -SlimScrollIndicator.lane
            ),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor)
        ])
        view = container
        watchScrolling()
        refresh()
    }

    /// Follows the scroll, so the indicator is where the content is.
    private func watchScrolling() {
        guard let scroll else { return }
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidScroll),
            name: NSView.boundsDidChangeNotification,
            object: scroll.contentView
        )
    }

    @objc private func scrollViewDidScroll() { updateIndicator() }

    private func updateIndicator() {
        guard let scroll, let document = scroll.documentView else { return }
        let metrics = ScrollIndicatorMetrics.thumb(
            content: document.bounds.height,
            visible: scroll.contentView.bounds.height,
            offset: scroll.contentView.bounds.origin.y,
            track: scroll.bounds.height
        )
        indicator.show(metrics)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        resizeToFit()
        view.window?.makeFirstResponder(nameField.field)
    }

    /// A title and subtitle on the left, the toggle on the right -- one row,
    /// full width.
    /// The name and the mark on one line: the well sits where the space's dot
    /// will sit, immediately before its name, so the row is a preview of the
    /// thing being made.
    private func nameRow() -> NSView {
        iconWell.onChange = { [weak self] choice in
            guard let self else { return }
            self.icon = SpaceIcon(choice)
            self.showIcon()
        }
        showIcon()
        let row = NSStackView(views: [iconWell, nameField])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    /// The well in the colour the sheet has settled on, so a symbol chosen
    /// here is drawn in the colour it will actually be drawn in.
    private func showIcon() {
        iconWell.show(
            image: icon.image(color: startColour, title: nameField.stringValue, side: IconWell.side),
            current: icon.asMenuChoice,
            color: startColour
        )
    }

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
        // An open picker follows the palette rather than contradicting it.
        if showsPicker && !editingEndColour { colourPicker.show(colour) }
        refresh()
    }

    private func choosePreset(_ preset: GradientPreset) {
        styleIndex = 1
        startColour = NSColor(hexString: preset.startHex) ?? suggested
        endColour = NSColor(hexString: preset.endHex) ?? suggested
        direction = preset.direction
        if showsPicker { colourPicker.show(editingEndColour ? endColour : startColour) }
        refresh()
    }

    /// Opens the picker on a stop, in this card. A second click on the same
    /// control closes it again.
    private func openColourPanel(forEnd: Bool) {
        if showsPicker && editingEndColour == forEnd {
            showsPicker = false
        } else {
            editingEndColour = forEnd
            showsPicker = true
            colourPicker.show(forEnd ? endColour : startColour)
        }
        refresh()
        // On a capped sheet the picker can open below the fold, which looks
        // like nothing happened. Bring it into view once the row is laid out.
        if showsPicker {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.showsPicker else { return }
                self.pickerRow.scrollToVisible(self.pickerRow.bounds)
            }
        }
    }

    private func pickerChanged(_ colour: NSColor) {
        if editingEndColour {
            endColour = colour
            styleIndex = 1
        } else {
            startColour = colour
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
            icon: icon,
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
        // The well takes the space's colour, so a symbol chosen before the
        // colour was settled is redrawn in the colour that was settled after.
        showIcon()

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
        // The picker belongs to whichever stop it was opened on, so it closes
        // with the rows that offer that stop.
        if !customised || (editingEndColour && !gradient) { showsPicker = false }
        pickerRow.isHidden = !showsPicker
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
    ///
    /// Capped at a share of the screen: on a Mac set to larger text the same
    /// sections come out tall enough to run off the bottom, taking Cancel and
    /// Create with them. Past the cap the sections scroll instead -- see
    /// `SheetFit`.
    private func resizeToFit() {
        guard isViewLoaded, let contentStack, let heading, let footer else { return }
        view.layoutSubtreeIfNeeded()
        // The container's own `fittingSize` reports whatever height the sheet
        // window forces on it; the stack's fitting size is the true content
        // height, with hidden sections collapsed. Size the sheet to that,
        // plus the chrome that does not scroll.
        let content = 2 * PanelStyle.inset
            + heading.fittingSize.height + Self.headingGap
            + contentStack.fittingSize.height
            + PanelStyle.sectionGap + footer.fittingSize.height
        let screen = view.window?.screen
            ?? view.window?.sheetParent?.screen
            ?? NSScreen.main
        let height = SheetFit.height(
            content: content,
            screen: screen?.visibleFrame.height ?? 0,
            window: view.window?.sheetParent?.frame.height ?? 0
        )
        let target = NSSize(width: Self.width, height: height)
        preferredContentSize = target
        view.window?.setContentSize(target)
        updateIndicator()
    }

}

extension NewSpaceSheet: NSTextFieldDelegate {
    /// Every keystroke, so the preview says the name as it is being typed.
    func controlTextDidChange(_ notification: Notification) {
        refreshPreviewName()
    }
}

/// Where the scroll indicator's thumb goes, and how long it is.
///
/// Pure, so the arithmetic can be checked without a scroll view: a thumb as
/// long a share of the track as the visible part is of the content, slid down
/// the track in proportion to how far the content has been scrolled.
enum ScrollIndicatorMetrics {
    /// Never shorter than this, or a long sheet gets a thumb too small to see.
    static let minimumThumb: CGFloat = 24

    struct Thumb: Equatable {
        /// Nothing to indicate: everything is on screen.
        var isHidden: Bool
        /// From the top of the track.
        var offset: CGFloat
        var length: CGFloat
    }

    static func thumb(
        content: CGFloat,
        visible: CGFloat,
        offset: CGFloat,
        track: CGFloat,
        minimum: CGFloat = minimumThumb
    ) -> Thumb {
        guard content > visible + 0.5, visible > 0, track > 0 else {
            return Thumb(isHidden: true, offset: 0, length: 0)
        }
        let length = min(track, max(minimum, track * visible / content))
        let travelled = min(max(offset / (content - visible), 0), 1)
        return Thumb(
            isHidden: false,
            offset: (track - length) * travelled,
            length: length
        )
    }
}

/// A hairline scroll indicator: three points wide, rounded, always there while
/// there is more to read, and never in the way of what it is indicating.
@MainActor
final class SlimScrollIndicator: NSView {
    /// The bar itself.
    static let width: CGFloat = 3
    /// The lane kept clear for it, bar included, so no control is drawn under
    /// it and it never overlaps the sections the way the system's does.
    static let lane: CGFloat = 10

    private var thumb = ScrollIndicatorMetrics.Thumb(isHidden: true, offset: 0, length: 0)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("SlimScrollIndicator is created in code only") }

    /// Decoration: the wheel and every click belong to what is underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ thumb: ScrollIndicatorMetrics.Thumb) {
        guard thumb != self.thumb else { return }
        self.thumb = thumb
        isHidden = thumb.isHidden
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !thumb.isHidden else { return }
        // Measured from the top: the content's first line is the track's top.
        let rect = NSRect(
            x: 0,
            y: bounds.height - thumb.offset - thumb.length,
            width: bounds.width,
            height: thumb.length
        )
        Style.Colors.controlTrackFill.setFill()
        NSBezierPath(
            roundedRect: rect, xRadius: bounds.width / 2, yRadius: bounds.width / 2
        ).fill()
    }

    /// The fill is a fixed `NSColor` resolved at draw; a change of appearance
    /// has to redraw it.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
