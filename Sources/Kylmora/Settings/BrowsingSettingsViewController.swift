import AppKit

/// The Browsing pane: the small switches that shape everyday use.
@MainActor
final class BrowsingSettingsViewController: NSViewController {
    private let densityPopUp = NSPopUpButton()
    private let tabStripCheckbox = NSButton(checkboxWithTitle: "Show a tab bar above the page", target: nil, action: nil)
    private let toolbarStack = NSStackView()
    private let settings: Settings
    private let session: BrowserSession?
    private let https = NSButton(checkboxWithTitle: "Automatic HTTPS upgrade", target: nil, action: nil)
    private let fullAddress = NSButton(checkboxWithTitle: "Show full website address", target: nil, action: nil)
    private let unicodeDomains = NSButton(checkboxWithTitle: "Show Unicode Domains", target: nil, action: nil)
    private let bookmarksInNewTabs = NSButton(checkboxWithTitle: "Open bookmarks in new tabs", target: nil, action: nil)
    private let favourites = NSButton(checkboxWithTitle: "Use \u{2325}\u{2318}-1 to \u{2325}\u{2318}-9 to open pinned sites", target: nil, action: nil)
    private let wraps = NSButton(checkboxWithTitle: "Wrap around when switching spaces", target: nil, action: nil)
    private let externalLinks = NSPopUpButton()
    private let compactButtons = NSButton(checkboxWithTitle: "Show standard window buttons in Compact Mode", target: nil, action: nil)
    private let pictureInPicture = NSButton(checkboxWithTitle: "Confirm closing tabs when Picture in Picture video is playing", target: nil, action: nil)
    private let sidebarModePopUp = NSPopUpButton()
    private let sidebarPositionPopUp = NSPopUpButton()
    private let sidebarHoverDelayPopUp = NSPopUpButton()
    private let autoPictureInPicture = NSButton(checkboxWithTitle: "Automatically Picture-in-Picture playing video on tab or space switch", target: nil, action: nil)
    private let minimumFont = NSButton(checkboxWithTitle: "Minimum font size", target: nil, action: nil)
    private let fontSize = NSTextField()
    private let fontStepper = NSStepper()
    private let tabFocus = NSButton(checkboxWithTitle: "Press Tab to highlight each item on a web page", target: nil, action: nil)
    private let escape = NSButton(checkboxWithTitle: "Prevent ESC from exiting full screen", target: nil, action: nil)
    private let mouseGestures = NSButton(checkboxWithTitle: "Enable mouse gestures (Hold right button and swipe)", target: nil, action: nil)
    private let rockerGestures = NSButton(checkboxWithTitle: "Enable rocker gestures (Right+Left click = Back, Left+Right click = Forward)", target: nil, action: nil)
    private let gestureTrails = NSButton(checkboxWithTitle: "Show gesture trails and action hints", target: nil, action: nil)
    private let linkHints = NSButton(checkboxWithTitle: "Enable link hints (⌥F or 'f' in Vim mode)", target: nil, action: nil)
    private let vimBindings = NSButton(checkboxWithTitle: "Enable Vim-style navigation bindings (j/k scrolling, gg/G, H/L, x, yy)", target: nil, action: nil)
    private let webPanelEnabled = NSButton(checkboxWithTitle: "Enable Web Panels (side web apps)", target: nil, action: nil)
    private let webPanelAlwaysOnTop = NSButton(checkboxWithTitle: "Floating Windows remain Always on Top by default", target: nil, action: nil)
    private let resetWebPanelsButton = NSButton(title: "Reset Web Panels to Defaults", target: nil, action: nil)
    private let customizeContextMenuButton = NSButton(title: "Customize Context Menu…", target: nil, action: nil)

    init(settings: Settings = .shared, session: BrowserSession? = nil) {
        self.settings = settings
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("BrowsingSettingsViewController is created in code only")
    }

    override func loadView() {
        let form = SettingsForm()
        view = form
        buildLayout(in: form)
        reload()
    }

    private func buildLayout(in form: SettingsForm) {
        for box in [https, fullAddress, unicodeDomains, bookmarksInNewTabs, favourites, wraps,
                    compactButtons, autoPictureInPicture, pictureInPicture, minimumFont, tabFocus, escape,
                    mouseGestures, rockerGestures, gestureTrails, linkHints, vimBindings,
                    webPanelEnabled, webPanelAlwaysOnTop] {
            box.target = self
            box.action = #selector(changed)
        }
        // Each group under a heading of its own, one switch to a row. The
        // switches used to be handed over three at a time in a stack, which
        // drew them down the left of the card with the text trailing off
        // after them -- a second design on the same page as the rows.
        form.addSection("Addresses")
        form.addRow("", https)
        form.addNote("Sites WebKit knows offer HTTPS are loaded over it even when a link says http.")
        form.addRow("", fullAddress)
        form.addRow("", unicodeDomains)
        form.addNote("Show domains with special characters (e.g. na\u{00ef}ve.com) instead of encoded format. May make some spoofed domains harder to recognise.")

        externalLinks.addItems(withTitles: ExternalLinkPresentation.allCases.map(\.title))
        externalLinks.target = self
        externalLinks.action = #selector(changed)

        form.addSection("Tabs and navigation")
        form.addRow("", bookmarksInNewTabs)
        form.addRow("", favourites)
        form.addRow("", wraps)
        form.addRow("Links from other apps", SettingsForm.fill(externalLinks))
        form.addNote("A Little Arc window opens where you are, so a link from another app does not pull you to the desktop the browser is on. A Glance shows the page over the one you are reading. Hold Shift as the link arrives to open a tab instead.")

        sidebarModePopUp.addItems(withTitles: SidebarMode.allCases.map(\.title))
        sidebarModePopUp.target = self
        sidebarModePopUp.action = #selector(changed)
        sidebarPositionPopUp.addItems(withTitles: SidebarPosition.allCases.map(\.title))
        sidebarPositionPopUp.target = self
        sidebarPositionPopUp.action = #selector(changed)
        sidebarHoverDelayPopUp.addItems(withTitles: SidebarHoverDelayPreset.allCases.map(\.title))
        sidebarHoverDelayPopUp.target = self
        sidebarHoverDelayPopUp.action = #selector(changed)

        form.addSection("Sidebar and window")
        densityPopUp.addItems(withTitles: SidebarDensity.allCases.map(\.title))
        densityPopUp.target = self
        densityPopUp.action = #selector(densityChanged)
        form.addRow("Sidebar density", SettingsForm.fill(densityPopUp))
        tabStripCheckbox.target = self
        tabStripCheckbox.action = #selector(tabStripChanged)
        form.addRow("", tabStripCheckbox)
        form.addRow("Sidebar display", SettingsForm.fill(sidebarModePopUp))
        form.addRow("Sidebar position", SettingsForm.fill(sidebarPositionPopUp))
        form.addRow("Hover reveal delay", SettingsForm.fill(sidebarHoverDelayPopUp))
        form.addNote("Icons-only mode leaves a compact vertical strip that expands to full width on hover. Hover delay prevents accidental reveals when moving the cursor across the edge.")
        form.addRow("", compactButtons)

        form.addSection("Toolbar buttons")
        toolbarStack.orientation = .vertical
        toolbarStack.alignment = .leading
        toolbarStack.spacing = 4
        form.addRow("", toolbarStack)
        let resetToolbar = NSButton(title: "Restore Default Toolbar", target: self, action: #selector(resetToolbar))
        resetToolbar.bezelStyle = .rounded
        form.addContinuation(resetToolbar)
        form.addNote("Untick a button to take it off the bar above the page; the arrows change the order. The navigation buttons and the address stay.")

        form.addSection("Picture in Picture")
        form.addRow("", autoPictureInPicture)
        form.addRow("", pictureInPicture)

        fontSize.translatesAutoresizingMaskIntoConstraints = false
        fontSize.widthAnchor.constraint(equalToConstant: 44).isActive = true
        fontSize.alignment = .right
        fontSize.target = self
        fontSize.action = #selector(fontSizeTyped)
        fontStepper.minValue = 1
        fontStepper.maxValue = 72
        fontStepper.increment = 1
        fontStepper.target = self
        fontStepper.action = #selector(fontStepped)
        // The checkbox leads, so it names the row; the field and the stepper
        // sit with the switch.
        let sizeRow = NSStackView(views: [minimumFont, fontSize, fontStepper])
        sizeRow.orientation = .horizontal
        sizeRow.spacing = 4
        form.addSection("Accessibility")
        form.addRow("", sizeRow)
        form.addRow("", tabFocus)
        form.addRow("", escape)

        form.addSection("Mouse gestures")
        form.addRow("", mouseGestures)
        form.addRow("", rockerGestures)
        form.addRow("", gestureTrails)
        form.addNote("Perform navigation actions by holding right-click and swiping: ← Back, → Forward, ↓ New Tab, ↓→ Close Tab, ↑↓ Reload, ↑ Scroll to Top.")

        form.addSection("Keyboard navigation")
        form.addRow("", linkHints)
        form.addRow("", vimBindings)
        form.addNote("Use link hints (⌥F or 'f' in Vim mode) to jump to any link or button without the mouse. Vim bindings provide modal j/k scrolling, gg/G, H/L history, and x tab closing.")

        resetWebPanelsButton.target = self
        resetWebPanelsButton.action = #selector(resetWebPanelsClicked)
        resetWebPanelsButton.bezelStyle = .rounded
        form.addSection("Web panels and floating windows")
        form.addRow("", webPanelEnabled)
        form.addRow("", webPanelAlwaysOnTop)
        form.addContinuation(resetWebPanelsButton)
        form.addNote("Pinned side web apps like ChatGPT, Quick Notes, and DeepL. Detach to an always-on-top floating window using ⌃⌘P or ⌥⌘F.")

        customizeContextMenuButton.target = self
        customizeContextMenuButton.action = #selector(openContextMenuSettings)
        customizeContextMenuButton.bezelStyle = .rounded
        form.addSection("Context menu")
        form.addRow("Search engines, Copy Clean Link, and items to hide", customizeContextMenuButton)
        form.addNote("Configure 'Search for…' engines, 'Copy Clean Link', and remove unwanted items like Share, Services, or Speech.")
    }

    private func reload() {
        densityPopUp.selectItem(at: SidebarDensity.allCases.firstIndex(of: settings.sidebarDensity) ?? 1)
        tabStripCheckbox.state = settings.showsTabStrip ? .on : .off
        rebuildToolbarRows()
        https.state = settings.upgradesToHTTPS ? .on : .off
        fullAddress.state = settings.showsFullAddress ? .on : .off
        unicodeDomains.state = settings.showsUnicodeDomains ? .on : .off
        bookmarksInNewTabs.state = settings.opensBookmarksInNewTabs ? .on : .off
        favourites.state = settings.favouriteShortcutsEnabled ? .on : .off
        wraps.state = settings.spaceSwitchWraps ? .on : .off
        externalLinks.selectItem(withTitle: settings.externalLinkPresentation.title)
        sidebarModePopUp.selectItem(withTitle: settings.sidebarMode.title)
        sidebarPositionPopUp.selectItem(withTitle: settings.sidebarPosition.title)
        sidebarHoverDelayPopUp.selectItem(withTitle: SidebarHoverDelayPreset.preset(for: settings.sidebarHoverDelay).title)
        compactButtons.state = settings.compactModeShowsWindowButtons ? .on : .off
        autoPictureInPicture.state = settings.autoPictureInPicture ? .on : .off
        pictureInPicture.state = settings.confirmsClosingPictureInPicture ? .on : .off
        minimumFont.state = settings.minimumFontSizeEnabled ? .on : .off
        fontSize.integerValue = settings.minimumFontSize
        fontStepper.integerValue = settings.minimumFontSize
        fontSize.isEnabled = settings.minimumFontSizeEnabled
        fontStepper.isEnabled = settings.minimumFontSizeEnabled
        tabFocus.state = settings.tabFocusesLinks ? .on : .off
        escape.state = settings.preventsEscapeExitingFullScreen ? .on : .off
        mouseGestures.state = settings.mouseGesturesEnabled ? .on : .off
        rockerGestures.state = settings.rockerGesturesEnabled ? .on : .off
        gestureTrails.state = settings.gestureTrailsEnabled ? .on : .off
        rockerGestures.isEnabled = settings.mouseGesturesEnabled
        gestureTrails.isEnabled = settings.mouseGesturesEnabled
        linkHints.state = settings.linkHintsEnabled ? .on : .off
        vimBindings.state = settings.vimBindingsEnabled ? .on : .off
        webPanelEnabled.state = settings.webPanelEnabled ? .on : .off
        webPanelAlwaysOnTop.state = settings.webPanelAlwaysOnTop ? .on : .off
        webPanelAlwaysOnTop.isEnabled = settings.webPanelEnabled
    }

    /// One row per button: a checkbox for shown, arrows for order.
    private func rebuildToolbarRows() {
        toolbarStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let layout = settings.toolbarLayout
        let names = layout.fullOrder()
        for (index, name) in names.enumerated() {
            let check = NSButton(checkboxWithTitle: name, target: self, action: #selector(toolbarVisibilityChanged(_:)))
            check.state = layout.hidden.contains(name) ? .off : .on
            check.identifier = NSUserInterfaceItemIdentifier(name)
            check.widthAnchor.constraint(equalToConstant: 180).isActive = true
            let symbol = NSImageView(image: NSImage(systemSymbolName: ToolbarLayout.catalog.first { $0.label == name }?.symbolName ?? "questionmark", accessibilityDescription: nil)!)
            symbol.contentTintColor = .secondaryLabelColor
            let up = NSButton(image: NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Move \(name) up")!, target: self, action: #selector(toolbarMoveUp(_:)))
            up.isBordered = false
            up.identifier = NSUserInterfaceItemIdentifier(name)
            up.isEnabled = index > 0
            let down = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Move \(name) down")!, target: self, action: #selector(toolbarMoveDown(_:)))
            down.isBordered = false
            down.identifier = NSUserInterfaceItemIdentifier(name)
            down.isEnabled = index < names.count - 1
            let row = NSStackView(views: [symbol, check, up, down])
            row.orientation = .horizontal
            row.spacing = 6
            toolbarStack.addArrangedSubview(row)
        }
    }

    @objc private func toolbarVisibilityChanged(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue else { return }
        var layout = settings.toolbarLayout
        layout.setHidden(name, sender.state == .off)
        settings.toolbarLayout = layout
    }

    @objc private func toolbarMoveUp(_ sender: NSButton) { moveToolbarButton(sender, by: -1) }
    @objc private func toolbarMoveDown(_ sender: NSButton) { moveToolbarButton(sender, by: 1) }

    private func moveToolbarButton(_ sender: NSButton, by delta: Int) {
        guard let name = sender.identifier?.rawValue else { return }
        var layout = settings.toolbarLayout
        layout.move(name, by: delta)
        settings.toolbarLayout = layout
        rebuildToolbarRows()
    }

    @objc private func resetToolbar() {
        settings.toolbarLayout = .default
        rebuildToolbarRows()
    }

    @objc private func tabStripChanged() {
        settings.showsTabStrip = tabStripCheckbox.state == .on
    }

    @objc private func densityChanged() {
        settings.sidebarDensity = SidebarDensity.allCases[densityPopUp.indexOfSelectedItem]
    }

    @objc private func changed() {
        settings.upgradesToHTTPS = https.state == .on
        settings.showsFullAddress = fullAddress.state == .on
        settings.showsUnicodeDomains = unicodeDomains.state == .on
        settings.opensBookmarksInNewTabs = bookmarksInNewTabs.state == .on
        settings.favouriteShortcutsEnabled = favourites.state == .on
        settings.spaceSwitchWraps = wraps.state == .on
        let presentations = ExternalLinkPresentation.allCases
        guard presentations.indices.contains(externalLinks.indexOfSelectedItem) else { return }
        settings.externalLinkPresentation = presentations[externalLinks.indexOfSelectedItem]

        let modes = SidebarMode.allCases
        if modes.indices.contains(sidebarModePopUp.indexOfSelectedItem) {
            settings.sidebarMode = modes[sidebarModePopUp.indexOfSelectedItem]
        }
        let positions = SidebarPosition.allCases
        if positions.indices.contains(sidebarPositionPopUp.indexOfSelectedItem) {
            settings.sidebarPosition = positions[sidebarPositionPopUp.indexOfSelectedItem]
        }
        let delays = SidebarHoverDelayPreset.allCases
        if delays.indices.contains(sidebarHoverDelayPopUp.indexOfSelectedItem) {
            settings.sidebarHoverDelay = delays[sidebarHoverDelayPopUp.indexOfSelectedItem].rawValue
        }

        settings.compactModeShowsWindowButtons = compactButtons.state == .on
        settings.autoPictureInPicture = autoPictureInPicture.state == .on
        settings.confirmsClosingPictureInPicture = pictureInPicture.state == .on
        settings.minimumFontSizeEnabled = minimumFont.state == .on
        settings.tabFocusesLinks = tabFocus.state == .on
        settings.preventsEscapeExitingFullScreen = escape.state == .on
        settings.mouseGesturesEnabled = mouseGestures.state == .on
        settings.rockerGesturesEnabled = rockerGestures.state == .on
        settings.gestureTrailsEnabled = gestureTrails.state == .on
        settings.linkHintsEnabled = linkHints.state == .on
        settings.vimBindingsEnabled = vimBindings.state == .on
        settings.webPanelEnabled = webPanelEnabled.state == .on
        settings.webPanelAlwaysOnTop = webPanelAlwaysOnTop.state == .on
        webPanelAlwaysOnTop.isEnabled = settings.webPanelEnabled
        rockerGestures.isEnabled = settings.mouseGesturesEnabled
        gestureTrails.isEnabled = settings.mouseGesturesEnabled
        fontSize.isEnabled = settings.minimumFontSizeEnabled
        fontStepper.isEnabled = settings.minimumFontSizeEnabled
        session?.applyWebPreferences()
        session?.changes.send(.activeTab)
    }

    @objc private func resetWebPanelsClicked() {
        WebPanelStore.shared.resetToDefaults()
    }

    @objc private func fontSizeTyped() {
        settings.minimumFontSize = fontSize.integerValue
        fontSize.integerValue = settings.minimumFontSize
        fontStepper.integerValue = settings.minimumFontSize
        session?.applyWebPreferences()
    }

    @objc private func fontStepped() {
        settings.minimumFontSize = fontStepper.integerValue
        fontSize.integerValue = settings.minimumFontSize
        session?.applyWebPreferences()
    }

    @objc private func openContextMenuSettings() {
        let sheet = ContextMenuSettingsViewController(settings: settings)
        presentAsSheet(sheet)
    }
}
