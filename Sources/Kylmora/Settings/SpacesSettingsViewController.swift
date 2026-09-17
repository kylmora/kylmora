import AppKit
import UniformTypeIdentifiers
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
    private let grid = SpaceGridView()
    private let nameField = NSTextField()
    private let picker = SpaceThemePicker()
    private let borderSummary = NSTextField(labelWithString: "")
    private let appearanceControl = NSSegmentedControl(labels: SpaceAppearanceChoice.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
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
    private let privateButton = NSButton(title: "Create Private Space\u{2026}", target: nil, action: nil)
    private let detailLabel = NSTextField(labelWithString: "")
    private let downloadsFolderLabel = NSTextField(labelWithString: "Default (Downloads)")
    private let chooseDownloadsButton = NSButton(title: "Choose\u{2026}", target: nil, action: nil)
    private let resetDownloadsButton = NSButton(title: "Reset", target: nil, action: nil)
    private let bookmarkFolderField = NSTextField()
    private let passwordVaultField = NSTextField()
    private var cancellables: Set<AnyCancellable> = []

    /// The rows shown only for a customised space, kept so they can be hidden
    /// while a plain appearance is selected. `fillRow` picks solid vs gradient;
    /// the theme-colour rows belong to Solid, the gradient rows to Gradient.
    private var fillRow: SettingsFormRow?
    private var themeColorRow: SettingsFormRow?
    private var themeColorNoteRow: SettingsFormRow?
    private var gradientColorsRow: SettingsFormRow?
    private var gradientDirectionRow: SettingsFormRow?
    private var gradientNoteRow: SettingsFormRow?
    private var transparencyRow: SettingsFormRow?
    private var transparencyNoteRow: SettingsFormRow?
    /// The Window border row and its note. They sit on the same card as the
    /// space's colour, and show only for a customised space: the rim is drawn
    /// in that space's own colours, so there is nothing to draw without one.
    private var borderRow: SettingsFormRow?
    private var borderNoteRow: SettingsFormRow?
    /// Export and import, and the line under them. There is nothing to write
    /// down about a space with no look of its own, so they show only for the
    /// appearances that give a space one.
    private var themeFileRow: SettingsFormRow?
    private var themeFileNoteRow: SettingsFormRow?

    /// Kept by identity, not by index: a delete or a reorder moves indices, and
    /// the editor must not silently start pointing at a different space.
    private var editing: Space?
    private let searchEnginePopUp = NSPopUpButton()
    private let sleepPopUp = NSPopUpButton()
    private let zoomPopUp = NSPopUpButton()
    private let userAgentField = NSTextField()

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
        // A grid, not a column. See `SpaceGridView`: spaces are short-named
        // things you pick from, and a one-column list of them left five hundred
        // points of card empty beside every name.
        grid.onSelect = { [weak self] space in self?.select(space) }
        grid.translatesAutoresizingMaskIntoConstraints = false

        let createButton = NSButton(title: "Create Space\u{2026}", target: self, action: #selector(createSpace))
        privateButton.target = self
        privateButton.action = #selector(createPrivateSpace)
        // Delete sits with Create, under the list it acts on, rather than
        // stranded at the foot of the pane. Set apart from the create actions
        // so the destructive one is not next to them by a hair.
        deleteButton.target = self
        deleteButton.action = #selector(deleteSpace)
        let privatePlate = SettingsControlPlate(privateButton, width: nil)
        let buttons = NSStackView(views: [
            SettingsControlPlate(createButton, width: nil),
            privatePlate,
            SettingsControlPlate(deleteButton, width: nil)
        ])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        // After the plate, not after the button inside it: custom spacing names
        // an arranged view, and a button that has been dressed is no longer one.
        buttons.setCustomSpacing(20, after: privatePlate)

        // The key to the chips, directly under the cards that carry them.
        let key = SpaceBadgeKeyView()

        let list = NSStackView(views: [grid, key, buttons])
        list.orientation = .vertical
        list.alignment = .leading
        list.distribution = .fill
        list.spacing = 10
        // The key belongs to the grid above it, not to the buttons below.
        list.setCustomSpacing(6, after: grid)
        list.setCustomSpacing(14, after: key)
        list.translatesAutoresizingMaskIntoConstraints = false
        // The list runs the width of the card with its label above it: it is a
        // list of things, not a value sitting in a control column.
        form.addRow("Spaces", list, alignment: .top)
        // The grid runs the width of the row it is in, which is what tells it
        // how many columns it has room for.
        grid.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        reloadGrid()
        form.addNote("Every space keeps its own cookies, logins and site data, so the same site can be signed in as a different account in each one. The window takes the colour of whichever space is in front.")

        form.addSeparator()

        nameField.target = self
        nameField.action = #selector(nameCommitted)
        // The field refuses the character past the limit rather than letting a
        // long name be typed and silently cut when it is stored.
        nameField.formatter = LimitedLengthFormatter(limit: Space.maximumNameLength)
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

        // On the card the space's colour is on, not a card of its own. The rim
        // is one more thing Customized gives a space, alongside its fill,
        // colour and transparency, and a card break in front of it read as a
        // window-wide setting that had wandered into the space editor.
        borderSummary.textColor = .secondaryLabelColor
        borderSummary.lineBreakMode = .byTruncatingTail
        let customizeBorder = NSButton(title: "Customize\u{2026}", target: self, action: #selector(customizeBorder))
        borderRow = form.addRow("Window border", [borderSummary, customizeBorder])
        borderNoteRow = form.addNote("A rim around the window in this space's colours, so a glance at any corner says which identity is in front.")

        // On the same card as the colours it carries. The file is those very
        // settings written down -- exporting is this card, saved; importing is
        // this card, filled in -- so a break in front of it fenced a thing off
        // from the only settings it is about.
        //
        // Shown for Customized and Website, and hidden for the plain presets.
        //
        // This row used to show whatever the appearance, on the reasoning that
        // importing a theme is one way a plain space becomes a customised one.
        // But a space set to Automatic, Light or Dark has no colour, no
        // gradient and no border -- there is nothing in it worth writing to a
        // file -- so the row offered to export nothing, and sat under a note
        // listing six things the space did not have.
        let exportTheme = NSButton(title: "Export Theme\u{2026}", target: self, action: #selector(exportTheme))
        let importTheme = NSButton(title: "Import Theme\u{2026}", target: self, action: #selector(importTheme))
        themeFileRow = form.addRow("Theme file", [exportTheme, importTheme])
        themeFileNoteRow = form.addNote("This space's colour, gradient, appearance, fonts, bars and window border as a .kylmoratheme file, to share or to bring to another Mac. Tabs and logins stay here.")

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

        // Per-Space Extras (F-24)
        form.addSeparator()

        chooseDownloadsButton.target = self
        chooseDownloadsButton.action = #selector(chooseDownloadsFolder)
        chooseDownloadsButton.bezelStyle = .rounded
        resetDownloadsButton.target = self
        resetDownloadsButton.action = #selector(resetDownloadsFolder)
        resetDownloadsButton.bezelStyle = .rounded
        downloadsFolderLabel.font = .systemFont(ofSize: 12)
        downloadsFolderLabel.textColor = .secondaryLabelColor
        downloadsFolderLabel.lineBreakMode = .byTruncatingMiddle
        downloadsFolderLabel.translatesAutoresizingMaskIntoConstraints = false
        downloadsFolderLabel.widthAnchor.constraint(equalToConstant: 200).isActive = true
        form.addRow("Downloads folder", [downloadsFolderLabel, chooseDownloadsButton, resetDownloadsButton])
        form.addNote("Files downloaded from tabs in this space are saved here.")

        bookmarkFolderField.placeholderString = "All Bookmarks (or enter folder name, e.g. Work)"
        bookmarkFolderField.target = self
        bookmarkFolderField.action = #selector(bookmarkFolderChanged)
        bookmarkFolderField.translatesAutoresizingMaskIntoConstraints = false
        bookmarkFolderField.widthAnchor.constraint(equalToConstant: 320).isActive = true
        form.addRow("Bookmarks folder", bookmarkFolderField)
        form.addNote("Folder of bookmarks displayed on this space's bookmarks bar.")

        // Per-space overrides of what Settings decides for everyone.
        searchEnginePopUp.target = self
        searchEnginePopUp.action = #selector(searchEngineChanged)
        form.addRow("Search engine", SettingsForm.fill(searchEnginePopUp))
        sleepPopUp.addItems(withTitles: ["Default"] + Self.sleepChoices.map { $0 == 0 ? "Never" : "After \($0) min" })
        sleepPopUp.target = self
        sleepPopUp.action = #selector(sleepChanged)
        form.addRow("Tab sleeping", SettingsForm.fill(sleepPopUp))
        zoomPopUp.addItems(withTitles: ["Default"] + SiteSettingCategory.pageZoom.options.map(\.title))
        zoomPopUp.target = self
        zoomPopUp.action = #selector(zoomChanged)
        form.addRow("Default zoom", SettingsForm.fill(zoomPopUp))
        userAgentField.placeholderString = "Default (leave empty)"
        userAgentField.target = self
        userAgentField.action = #selector(userAgentChanged)
        userAgentField.translatesAutoresizingMaskIntoConstraints = false
        userAgentField.widthAnchor.constraint(equalToConstant: 320).isActive = true
        form.addRow("User agent", userAgentField)
        form.addNote("These apply to every tab in this space. A site's own choice in Websites still wins for that site.")

        passwordVaultField.placeholderString = "Space name (e.g. Work, Personal)"
        passwordVaultField.target = self
        passwordVaultField.action = #selector(passwordVaultChanged)
        passwordVaultField.translatesAutoresizingMaskIntoConstraints = false
        passwordVaultField.widthAnchor.constraint(equalToConstant: 320).isActive = true
        form.addRow("Password account", passwordVaultField)
        form.addNote("Identifies this space's account in password autofill and vaults.")
    }

    // MARK: - State

    /// Rebuilds the list and reloads the editor, keeping the same space
    /// selected across a rename or a recolour.
    func reload() {
        let keep = editing
        reloadGrid()
        if EnterprisePolicyManager.shared.isPrivateBrowsingDisabled {
            privateButton.isEnabled = false
            privateButton.toolTip = "Private spaces are disabled by your organization"
        } else {
            privateButton.isEnabled = true
            privateButton.toolTip = nil
        }
        if let keep, session.spaces.contains(where: { $0 === keep }) {
            select(keep)
        } else {
            select(session.activeSpace)
        }
    }

    /// Every space on the card at once. The grid wraps, so twelve spaces are
    /// four rows of three rather than twelve rows behind a scroller.
    private func reloadGrid() {
        grid.show(session.spaces, selected: editing, active: session.activeSpace)
    }

    /// Opens a space in the editor. Public so the space menu's "Space
    /// Settings" can land on the one the user was looking at.
    func select(_ space: Space) {
        editing = space
        reloadGrid()
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

        if let path = space.downloadsDirectoryPath, !path.isEmpty {
            downloadsFolderLabel.stringValue = (path as NSString).abbreviatingWithTildeInPath
            resetDownloadsButton.isEnabled = true
        } else {
            downloadsFolderLabel.stringValue = "Default (Downloads)"
            resetDownloadsButton.isEnabled = false
        }
        bookmarkFolderField.stringValue = space.bookmarkFolder ?? ""
        passwordVaultField.stringValue = space.passwordVaultAccount ?? ""

        searchEnginePopUp.removeAllItems()
        searchEnginePopUp.addItem(withTitle: "Default")
        for engine in Settings.shared.searchEngines { searchEnginePopUp.addItem(withTitle: engine.name) }
        if let id = space.searchEngineID, let index = Settings.shared.searchEngines.firstIndex(where: { $0.id == id }) {
            searchEnginePopUp.selectItem(at: index + 1)
        } else {
            searchEnginePopUp.selectItem(at: 0)
        }
        sleepPopUp.selectItem(at: space.sleepMinutes.flatMap { Self.sleepChoices.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        zoomPopUp.selectItem(at: space.defaultZoom.flatMap { zoom in SiteSettingCategory.pageZoom.options.firstIndex { $0.id == zoom } }.map { $0 + 1 } ?? 0)
        userAgentField.stringValue = space.userAgent ?? ""
    }

    static let sleepChoices = [0, 5, 10, 30, 60]

    @objc private func searchEngineChanged() {
        guard let space = editing else { return }
        let index = searchEnginePopUp.indexOfSelectedItem
        let engines = Settings.shared.searchEngines
        session.setSearchEngineID(index > 0 && engines.indices.contains(index - 1) ? engines[index - 1].id : nil, for: space)
    }

    @objc private func sleepChanged() {
        guard let space = editing else { return }
        let index = sleepPopUp.indexOfSelectedItem
        session.setSleepMinutes(index > 0 ? Self.sleepChoices[index - 1] : nil, for: space)
    }

    @objc private func zoomChanged() {
        guard let space = editing else { return }
        let index = zoomPopUp.indexOfSelectedItem
        session.setDefaultZoom(index > 0 ? SiteSettingCategory.pageZoom.options[index - 1].id : nil, for: space)
    }

    @objc private func userAgentChanged() {
        guard let space = editing else { return }
        session.setUserAgent(userAgentField.stringValue, for: space)
    }

    @objc private func chooseDownloadsFolder() {
        guard let space = editing else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Folder"
        panel.message = "Choose downloads folder for \(space.name)"
        if let currentPath = space.downloadsDirectoryPath {
            panel.directoryURL = URL(fileURLWithPath: (currentPath as NSString).expandingTildeInPath)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        session.setDownloadsDirectoryPath(url.path(percentEncoded: false), for: space)
        select(space)
    }

    @objc private func resetDownloadsFolder() {
        guard let space = editing else { return }
        session.setDownloadsDirectoryPath(nil, for: space)
        select(space)
    }

    @objc private func bookmarkFolderChanged() {
        guard let space = editing else { return }
        let val = bookmarkFolderField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        session.setBookmarkFolder(val.isEmpty ? nil : val, for: space)
    }

    @objc private func passwordVaultChanged() {
        guard let space = editing else { return }
        let val = passwordVaultField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        session.setPasswordVaultAccount(val.isEmpty ? nil : val, for: space)
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
        let choice = SpaceAppearanceChoice.of(space)
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
        borderRow?.isHidden = !customised
        borderNoteRow?.isHidden = !customised

        // A theme file is a space's look written down, so it shows wherever a
        // space has one to write: Customized, and Website -- whose fonts, bars
        // and page-coloured wash are a look as much as a chosen colour is.
        // Automatic, Light and Dark have nothing to export.
        let hasALook = choice == .customized || choice == .website
        themeFileRow?.isHidden = !hasALook
        themeFileNoteRow?.isHidden = !hasALook
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
        let choice = SpaceAppearanceChoice(rawValue: appearanceControl.selectedSegment) ?? .automatic
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
            // else the default swatch. A space that already has a colour keeps
            // it, and a space with a gradient keeps that too: re-selecting
            // Customized must never wipe the gradient (setTheme clears it).
            if editing.look.gradient == nil, !editing.theme.tintsChrome {
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

    @objc private func exportTheme() {
        guard let space = editing, let window = view.window else { return }
        let file = SpaceThemeFile(space: space)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [SpaceThemeFile.contentType, .json]
        panel.nameFieldStringValue = file.suggestedFileName
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url, let data = try? file.data() else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    @objc private func importTheme() {
        guard let space = editing, let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [SpaceThemeFile.contentType, .json]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url,
                  let data = try? Data(contentsOf: url), let file = try? SpaceThemeFile(data: data) else { return }
            file.apply(to: space, in: self.session)
            self.select(space)
        }
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
    @objc private func createPrivateSpace() {
        guard !EnterprisePolicyManager.shared.isPrivateBrowsingDisabled else {
            NSSound.beep()
            return
        }
        create(isPrivate: true)
    }

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

}

