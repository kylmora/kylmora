import AppKit
import Combine

/// The Spaces pane: the list of spaces, and an editor for the selected one.
///
/// List and editor on one page rather than a push navigation, which would push into a
/// detail screen, which suits a full-height settings window; ours is a panel,
/// and at this size a push would hide the list you are comparing against while
/// you pick a colour for one of its rows.
@MainActor
final class SpacesSettingsViewController: NSViewController {
    private let session: BrowserSession
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let nameField = NSTextField()
    private let picker = SpaceThemePicker()
    private let borderSummary = NSTextField(labelWithString: "")
    private let appearanceControl = NSSegmentedControl(labels: AppearanceChoice.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    /// Under Customized: a solid colour, or a two-stop gradient.
    private let fillControl = NSSegmentedControl(labels: ["Solid", "Gradient"], trackingMode: .selectOne, target: nil, action: nil)
    private let gradientStartWell = NSColorWell()
    private let gradientEndWell = NSColorWell()
    private let directionControl = NSSegmentedControl()
    private let transparencySlider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let transparencyValueLabel = NSTextField(labelWithString: "0%")
    private let toolbarInFullScreen = NSButton(checkboxWithTitle: "Always show toolbar in full screen", target: nil, action: nil)
    private let sidebarInFullScreen = NSButton(checkboxWithTitle: "Auto-show sidebar in full screen", target: nil, action: nil)
    private let opaqueInFullScreen = NSButton(checkboxWithTitle: "Disable transparency for full screen windows", target: nil, action: nil)
    private let bookmarksBarStyle = NSPopUpButton()
    private let showsBookmarksBar = NSButton(checkboxWithTitle: "Show bookmarks bar", target: nil, action: nil)
    private let defaultFont = NSPopUpButton()
    private let deleteButton = NSButton(title: "Delete Space\u{2026}", target: nil, action: nil)
    private let detailLabel = NSTextField(labelWithString: "")
    private var cancellables: Set<AnyCancellable> = []

    /// The rows shown only for a customised space, kept so they can be hidden
    /// while a plain appearance is selected. `fillRow` picks solid vs gradient;
    /// the theme-colour rows belong to Solid, the gradient rows to Gradient.
    private var fillRow: NSGridRow?
    private var themeColorRow: NSGridRow?
    private var themeColorNoteRow: NSGridRow?
    private var gradientColorsRow: NSGridRow?
    private var gradientDirectionRow: NSGridRow?
    private var gradientNoteRow: NSGridRow?
    private var transparencyRow: NSGridRow?
    private var transparencyNoteRow: NSGridRow?
    /// The Window border row, its note and the hairline above it, shown only
    /// for a customised space (the rim is drawn in the space's own colours).
    private var borderSeparatorRow: NSGridRow?
    private var borderRow: NSGridRow?
    private var borderNoteRow: NSGridRow?

    /// Kept by identity, not by index: a delete or a reorder moves indices, and
    /// the editor must not silently start pointing at a different space.
    private var editing: Space?

    init(session: BrowserSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("SpacesSettingsViewController is created in code only")
    }

    override func loadView() {
        let form = SettingsForm()
        view = SettingsScrollingPane(form: form)
        buildLayout(in: form)
        session.changes
            .sink { [weak self] change in
                guard case .spaces = change else { return }
                self?.reload()
            }
            .store(in: &cancellables)
        select(session.activeSpace)
    }

    // MARK: - Layout

    private func buildLayout(in form: SettingsForm) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("space"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 28
        tableView.style = .inset
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.heightAnchor.constraint(equalToConstant: 130).isActive = true

        let createButton = NSButton(title: "Create Space\u{2026}", target: self, action: #selector(createSpace))
        let privateButton = NSButton(title: "Create Private Space\u{2026}", target: self, action: #selector(createPrivateSpace))
        // Delete sits with Create, under the list it acts on, rather than
        // stranded at the foot of the pane. Set apart from the create actions
        // so the destructive one is not next to them by a hair.
        deleteButton.target = self
        deleteButton.action = #selector(deleteSpace)
        deleteButton.bezelStyle = .rounded
        let buttons = NSStackView(views: [createButton, privateButton, deleteButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.setCustomSpacing(20, after: privateButton)

        let list = NSStackView(views: [SettingsForm.fill(scrollView), buttons])
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 8
        form.addRow("Spaces", list)
        form.addNote("Every space keeps its own cookies, logins and site data, so the same site can be signed in as a different account in each one. The window takes the colour of whichever space is in front.")

        form.addSeparator()

        nameField.target = self
        nameField.action = #selector(nameCommitted)
        form.addRow("Space name", SettingsForm.fill(nameField))
        form.addNote(detailLabel)

        appearanceControl.target = self
        appearanceControl.action = #selector(appearanceChoiceChanged)
        appearanceControl.segmentStyle = .rounded
        appearanceControl.setAccessibilityLabel("Appearance")
        form.addRow("Appearance", appearanceControl)
        form.addNote("A plain window in that appearance; Automatic follows the General pane. Customized gives this space a colour of its own; Website lets the front page's own colour wash the window. Both follow the system for light and dark.")

        // Under Customized: a solid colour or a gradient.
        fillControl.target = self
        fillControl.action = #selector(fillModeChanged)
        fillControl.segmentStyle = .rounded
        fillControl.setAccessibilityLabel("Fill")
        fillRow = form.addRow("Fill", fillControl)

        picker.onSelect = { [weak self] theme in
            guard let self, let editing else { return }
            session.setTheme(theme, for: editing)
        }
        picker.onCustomColor = { [weak self] colour in
            guard let self, let editing else { return }
            session.setCustomColor(colour, for: editing)
        }
        themeColorRow = form.addRow("Theme color", picker, alignment: .center)
        themeColorNoteRow = form.addNote("The colour this space washes the window with, so a glance at any corner says which identity is in front.")

        for well in [gradientStartWell, gradientEndWell] {
            well.target = self
            well.action = #selector(gradientColorChanged)
            well.translatesAutoresizingMaskIntoConstraints = false
            well.widthAnchor.constraint(equalToConstant: 48).isActive = true
            well.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        gradientStartWell.setAccessibilityLabel("Gradient start colour")
        gradientEndWell.setAccessibilityLabel("Gradient end colour")
        let toLabel = NSTextField(labelWithString: "to")
        toLabel.textColor = .secondaryLabelColor
        gradientColorsRow = form.addRow("Gradient", [gradientStartWell, toLabel, gradientEndWell])

        directionControl.segmentCount = GradientDirection.allCases.count
        directionControl.trackingMode = .selectOne
        directionControl.segmentStyle = .rounded
        for (index, direction) in GradientDirection.allCases.enumerated() {
            directionControl.setImage(NSImage(systemSymbolName: direction.symbolName, accessibilityDescription: direction.title), forSegment: index)
            directionControl.setWidth(30, forSegment: index)
            directionControl.setToolTip(direction.title, forSegment: index)
        }
        directionControl.target = self
        directionControl.action = #selector(gradientDirectionChanged)
        directionControl.setAccessibilityLabel("Gradient direction")
        gradientDirectionRow = form.addRow("Direction", directionControl)
        gradientNoteRow = form.addNote("Two colours washed across the window, in the direction you pick.")

        // Transparency applies to whichever fill is chosen -- solid or gradient.
        transparencySlider.target = self
        transparencySlider.action = #selector(transparencyChanged)
        transparencySlider.isContinuous = true
        transparencySlider.translatesAutoresizingMaskIntoConstraints = false
        transparencySlider.widthAnchor.constraint(equalToConstant: 220).isActive = true
        transparencySlider.setAccessibilityLabel("Transparency")
        transparencyValueLabel.textColor = .secondaryLabelColor
        transparencyValueLabel.alignment = .right
        transparencyValueLabel.translatesAutoresizingMaskIntoConstraints = false
        transparencyValueLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true
        transparencyRow = form.addRow("Transparency", [transparencySlider, transparencyValueLabel])
        transparencyNoteRow = form.addNote("How much the window shows through the colour. 0% is the full wash; 100% fades it away.")

        borderSeparatorRow = form.addSeparator()

        borderSummary.textColor = .secondaryLabelColor
        borderSummary.lineBreakMode = .byTruncatingTail
        let customizeBorder = NSButton(title: "Customize\u{2026}", target: self, action: #selector(customizeBorder))
        borderRow = form.addRow("Window border", [borderSummary, customizeBorder])
        borderNoteRow = form.addNote("A rim around the window in this space's colours, so a glance at any corner says which identity is in front.")

        form.addSeparator()

        for box in [toolbarInFullScreen, sidebarInFullScreen, opaqueInFullScreen, showsBookmarksBar] {
            box.target = self
            box.action = #selector(lookChanged)
        }
        let fullScreen = NSStackView(views: [toolbarInFullScreen, sidebarInFullScreen, opaqueInFullScreen])
        fullScreen.orientation = .vertical
        fullScreen.alignment = .leading
        fullScreen.spacing = 8
        form.addRow("Full screen", fullScreen)

        bookmarksBarStyle.addItems(withTitles: BookmarksBarStyle.allCases.map(\.title))
        bookmarksBarStyle.target = self
        bookmarksBarStyle.action = #selector(lookChanged)
        bookmarksBarStyle.setAccessibilityLabel("Bookmarks bar style")
        form.addRow("Bookmarks bar", bookmarksBarStyle)
        form.addContinuation(showsBookmarksBar)

        defaultFont.target = self
        defaultFont.action = #selector(fontChanged)
        defaultFont.setAccessibilityLabel("Default font")
        let customizeFonts = NSButton(title: "Customize\u{2026}", target: self, action: #selector(customizeFonts))
        defaultFont.translatesAutoresizingMaskIntoConstraints = false
        defaultFont.widthAnchor.constraint(equalToConstant: 290).isActive = true
        form.addRow("Default font", [defaultFont, customizeFonts])
        form.addNote("What a page is set in when it does not choose its own fonts.")
    }

    // MARK: - State

    /// Rebuilds the list and reloads the editor, keeping the same space
    /// selected across a rename or a recolour.
    func reload() {
        let keep = editing
        tableView.reloadData()
        if let keep, session.spaces.contains(where: { $0 === keep }) {
            select(keep)
        } else {
            select(session.activeSpace)
        }
    }

    /// Opens a space in the editor. Public so the space menu's "Space
    /// Settings" can land on the one the user was looking at.
    func select(_ space: Space) {
        editing = space
        if let index = session.spaces.firstIndex(where: { $0 === space }) {
            tableView.selectRowIndexes([index], byExtendingSelection: false)
        }
        nameField.stringValue = space.name
        picker.show(space.theme)
        picker.showCustomColor(space.look.customColor)
        showBorder(space.border)
        showLook(space.look)
        updateColorControls(for: space)
        // The last space is the whole browser; there is nothing to fall back
        // to if it goes.
        deleteButton.isEnabled = session.spaces.count > 1

        let count = space.tabs.count
        let tabs = count == 1 ? "1 tab" : "\(count) tabs"
        if space.isPrivate {
            detailLabel.stringValue = "Private. Nothing this space browses is written to disk. \(tabs)."
        } else {
            detailLabel.stringValue = "Its own cookies and logins. \(tabs)."
        }
    }

    /// One line saying what the rim is, next to the button that edits it.
    private func showBorder(_ border: WindowBorder) {
        switch border.style {
        case .none:
            borderSummary.stringValue = "None"
        case .glass:
            borderSummary.stringValue = "Glass, \(border.thickness.title.lowercased())"
        case .solid, .gradient:
            var parts = [border.style.title, border.palette.title, border.thickness.title.lowercased()]
            if border.isAnimated { parts.append(border.animation.title.lowercased()) }
            borderSummary.stringValue = parts.joined(separator: ", ")
        }
    }

    /// Loads a look into the controls without reporting a change.
    private func showLook(_ look: SpaceLook) {
        toolbarInFullScreen.state = look.alwaysShowsToolbarInFullScreen ? .on : .off
        sidebarInFullScreen.state = look.autoShowsSidebarInFullScreen ? .on : .off
        opaqueInFullScreen.state = look.isOpaqueInFullScreen ? .on : .off
        showsBookmarksBar.state = look.showsBookmarksBar ? .on : .off
        bookmarksBarStyle.selectItem(at: BookmarksBarStyle.allCases.firstIndex(of: look.bookmarksBarStyle) ?? 0)
        showFont(look.fonts)
    }

    /// The font pop-up lists every family on the machine, with the space's
    /// own first if it is not among them (a font since removed still names
    /// what the space asked for).
    private func showFont(_ fonts: WebFonts) {
        let families = NSFontManager.shared.availableFontFamilies.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        defaultFont.removeAllItems()
        defaultFont.addItems(withTitles: families)
        if !families.contains(fonts.standardFamily) {
            defaultFont.insertItem(withTitle: fonts.standardFamily, at: 0)
        }
        defaultFont.selectItem(withTitle: fonts.standardFamily)
    }

    /// The look the controls currently describe, over the space's own.
    private func editedLook(from base: SpaceLook) -> SpaceLook {
        var look = base
        // Appearance and website-colour are owned by the Appearance control's
        // own action (`appearanceChoiceChanged`); these controls leave them be.
        look.alwaysShowsToolbarInFullScreen = toolbarInFullScreen.state == .on
        look.autoShowsSidebarInFullScreen = sidebarInFullScreen.state == .on
        look.isOpaqueInFullScreen = opaqueInFullScreen.state == .on
        look.showsBookmarksBar = showsBookmarksBar.state == .on
        let styles = BookmarksBarStyle.allCases
        look.bookmarksBarStyle = styles[min(max(bookmarksBarStyle.indexOfSelectedItem, 0), styles.count - 1)]
        return look
    }

    /// Reflects the space's appearance and colour: the four appearance
    /// segments, and, while customised, the solid/gradient fill and its
    /// controls. Only the rows for the current fill are shown.
    private func updateColorControls(for space: Space) {
        let choice = AppearanceChoice.of(space)
        appearanceControl.selectedSegment = choice.rawValue

        let customised = choice == .customized
        let hasGradient = space.look.gradient != nil
        let solid = customised && !hasGradient
        let gradient = customised && hasGradient

        fillRow?.isHidden = !customised
        fillControl.selectedSegment = hasGradient ? 1 : 0

        themeColorRow?.isHidden = !solid
        themeColorNoteRow?.isHidden = !solid

        gradientColorsRow?.isHidden = !gradient
        gradientDirectionRow?.isHidden = !gradient
        gradientNoteRow?.isHidden = !gradient

        // Transparency is a property of the chosen colour, so it shows for both
        // fills whenever the space is customised.
        transparencyRow?.isHidden = !customised
        transparencyNoteRow?.isHidden = !customised

        // The window border is drawn in the space's own colours, so it belongs
        // with Customized too -- hidden for the plain presets and Website.
        borderSeparatorRow?.isHidden = !customised
        borderRow?.isHidden = !customised
        borderNoteRow?.isHidden = !customised
        let transparency = (1 - space.look.washOpacity) * 100
        transparencySlider.doubleValue = transparency
        transparencyValueLabel.stringValue = "\(Int(transparency.rounded()))%"

        if let stops = space.look.gradient {
            gradientStartWell.color = stops.startColor
            gradientEndWell.color = stops.endColor
            directionControl.selectedSegment = GradientDirection.allCases.firstIndex(of: stops.direction) ?? 0
        }
    }

    // MARK: - Actions

    /// The Appearance segments. Automatic/Light/Dark paint a plain, untinted
    /// window and hide the colour row; Customized unlocks the space's own
    /// colour and lets the window follow the system for light and dark.
    @objc private func appearanceChoiceChanged() {
        guard let editing else { return }
        let choice = AppearanceChoice(rawValue: appearanceControl.selectedSegment) ?? .automatic
        switch choice {
        case .automatic, .light, .dark:
            var look = editing.look
            look.appearance = choice.presetAppearance ?? .system
            look.allowsWebsiteThemeColor = false
            session.setLook(look, for: editing)
            // Untinted: a preset carries no colour of its own.
            session.setTheme(.neutral, for: editing)
        case .customized:
            var look = editing.look
            look.appearance = .system
            look.allowsWebsiteThemeColor = false
            session.setLook(look, for: editing)
            // Start on a colour to customise: restore a remembered custom one,
            // else the default swatch. A space that already has a colour keeps it.
            if !editing.theme.tintsChrome {
                session.setTheme(editing.look.customColor != nil ? .custom : .default, for: editing)
            }
        case .website:
            var look = editing.look
            look.appearance = .system
            look.allowsWebsiteThemeColor = true
            session.setLook(look, for: editing)
            // The page supplies the colour: the space carries none of its own.
            session.setTheme(.neutral, for: editing)
        }
        select(editing)
    }

    /// Solid vs gradient, within Customized. Turning on the gradient seeds one
    /// from the space's current colour; turning it off drops the gradient and
    /// leaves the solid colour underneath (restoring one if there is none).
    @objc private func fillModeChanged() {
        guard let editing else { return }
        if fillControl.selectedSegment == 1 {
            if editing.look.gradient == nil {
                let start = editing.color
                let end = start.blended(withFraction: 0.4, of: .black) ?? start
                let seed = SpaceGradient(startHex: start.hexString, endHex: end.hexString, direction: .down)
                session.setSpaceGradient(seed, for: editing)
            }
        } else {
            session.setSpaceGradient(nil, for: editing)
            if !editing.theme.tintsChrome {
                session.setTheme(editing.look.customColor != nil ? .custom : .default, for: editing)
            }
        }
        select(editing)
    }

    @objc private func gradientColorChanged() {
        guard let editing, let stops = editing.look.gradient else { return }
        let updated = SpaceGradient(
            startHex: gradientStartWell.color.hexString,
            endHex: gradientEndWell.color.hexString,
            direction: stops.direction
        )
        session.setSpaceGradient(updated, for: editing)
    }

    @objc private func gradientDirectionChanged() {
        guard let editing, let stops = editing.look.gradient else { return }
        let directions = GradientDirection.allCases
        let direction = directions[min(max(directionControl.selectedSegment, 0), directions.count - 1)]
        let updated = SpaceGradient(startHex: stops.startHex, endHex: stops.endHex, direction: direction)
        session.setSpaceGradient(updated, for: editing)
    }

    @objc private func transparencyChanged() {
        guard let editing else { return }
        let transparency = transparencySlider.doubleValue
        transparencyValueLabel.stringValue = "\(Int(transparency.rounded()))%"
        var look = editing.look
        look.washOpacity = 1 - transparency / 100
        session.setLook(look, for: editing)
    }

    @objc private func lookChanged() {
        guard let editing else { return }
        let look = editedLook(from: editing.look)
        session.setLook(look, for: editing)
        showLook(look)
    }

    @objc private func fontChanged() {
        guard let editing, let family = defaultFont.titleOfSelectedItem else { return }
        var look = editing.look
        look.fonts.standardFamily = family
        session.setLook(look, for: editing)
    }

    @objc private func customizeFonts() {
        guard let editing else { return }
        let sheet = WebFontsViewController(fonts: editing.look.fonts)
        sheet.onDone = { [weak self, weak editing] fonts in
            guard let self, let editing else { return }
            var look = editing.look
            look.fonts = fonts
            session.setLook(look, for: editing)
            showFont(fonts)
        }
        presentAsSheet(sheet)
    }

    @objc private func customizeBorder() {
        guard let editing else { return }
        presentAsSheet(WindowBorderViewController(session: session, space: editing))
    }

    @objc private func nameCommitted() {
        guard let editing else { return }
        session.rename(editing, to: nameField.stringValue)
        // A rejected name -- empty, or unchanged -- must not be left sitting in
        // the field as though it had been accepted.
        nameField.stringValue = editing.name
    }

    @objc private func createSpace() { create(isPrivate: false) }
    @objc private func createPrivateSpace() { create(isPrivate: true) }

    private func create(isPrivate: Bool) {
        let name = isPrivate ? "Private" : "New Space"
        let space = session.addSpace(named: name, isPrivate: isPrivate)
        reload()
        select(space)
        view.window?.makeFirstResponder(nameField)
        nameField.selectText(nil)
    }

    @objc private func deleteSpace() {
        guard let space = editing, session.spaces.count > 1 else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete the space \u{201c}\(space.name)\u{201d}?"
        alert.informativeText = space.isPrivate
            ? "Its tabs are closed. Nothing it browsed was written to disk."
            : "Its tabs are closed and its cookies, logins and site data are erased."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        session.removeSpace(space)
        editing = nil
        reload()
    }

    // MARK: - The four appearance choices

    /// The Appearance control's four segments. The first three are the plain,
    /// untinted looks (a `neutral` space in that appearance); the fourth stands
    /// for "this space has a colour of its own". Which one a space shows as is
    /// read back from its state, so there is no separate flag to keep in sync.
    private enum AppearanceChoice: Int, CaseIterable {
        case automatic, light, dark, customized, website

        var title: String {
            switch self {
            case .automatic: return "Automatic"
            case .light: return "Light"
            case .dark: return "Dark"
            case .customized: return "Customized"
            case .website: return "Website"
            }
        }

        /// The plain appearance a preset paints in. `nil` for Customized and
        /// Website, which follow the system rather than fixing light or dark.
        var presetAppearance: AppearancePreference? {
            switch self {
            case .automatic: return .system
            case .light: return .light
            case .dark: return .dark
            case .customized, .website: return nil
            }
        }

        /// Which segment a space currently reads as. Website wins when the
        /// space lets pages colour it; else a space with a colour of its own --
        /// a tint or a gradient -- is customised, and an untinted one is its
        /// plain appearance.
        @MainActor
        static func of(_ space: Space) -> AppearanceChoice {
            if space.look.allowsWebsiteThemeColor { return .website }
            guard space.look.gradient == nil, !space.theme.tintsChrome else { return .customized }
            switch space.look.appearance {
            case .system: return .automatic
            case .light: return .light
            case .dark: return .dark
            }
        }
    }
}

// MARK: - The list

extension SpacesSettingsViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        session.spaces.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard session.spaces.indices.contains(row) else { return nil }
        let space = session.spaces[row]

        let dot = NSImageView(image: space.dotImage(side: 12))
        dot.setAccessibilityElement(false)
        let label = NSTextField(labelWithString: space.name)
        label.setAccessibilityElement(false)

        let stack = NSStackView(views: [dot, label])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        if space.isPrivate {
            let badge = NSTextField(labelWithString: "Private")
            badge.font = .systemFont(ofSize: 10)
            badge.textColor = .secondaryLabelColor
            badge.setAccessibilityElement(false)
            stack.addArrangedSubview(badge)
        }

        let cell = NSTableCellView()
        cell.addSubview(stack)
        cell.textField = label
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        cell.setAccessibilityLabel(space.isPrivate ? "\(space.name), private" : space.name)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard session.spaces.indices.contains(row) else { return }
        select(session.spaces[row])
    }
}
