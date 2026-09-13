import AppKit

/// The Browsing pane: the small switches that shape everyday use.
@MainActor
final class BrowsingSettingsViewController: NSViewController {
    private let settings: Settings
    private let session: BrowserSession?
    private let https = NSButton(checkboxWithTitle: "Automatic HTTPS upgrade", target: nil, action: nil)
    private let fullAddress = NSButton(checkboxWithTitle: "Show full website address", target: nil, action: nil)
    private let unicodeDomains = NSButton(checkboxWithTitle: "Show Unicode Domains", target: nil, action: nil)
    private let bookmarksInNewTabs = NSButton(checkboxWithTitle: "Open bookmarks in new tabs", target: nil, action: nil)
    private let favourites = NSButton(checkboxWithTitle: "Use \u{2325}\u{2318}-1 to \u{2325}\u{2318}-9 to open pinned sites", target: nil, action: nil)
    private let wraps = NSButton(checkboxWithTitle: "Wrap around when switching spaces", target: nil, action: nil)
    private let glance = NSButton(checkboxWithTitle: "Open links from other apps in a Glance (Shift for a tab)", target: nil, action: nil)
    private let compactButtons = NSButton(checkboxWithTitle: "Show standard window buttons in Compact Mode", target: nil, action: nil)
    private let pictureInPicture = NSButton(checkboxWithTitle: "Confirm closing tabs when Picture in Picture video is playing", target: nil, action: nil)
    private let minimumFont = NSButton(checkboxWithTitle: "Minimum font size", target: nil, action: nil)
    private let fontSize = NSTextField()
    private let fontStepper = NSStepper()
    private let tabFocus = NSButton(checkboxWithTitle: "Press Tab to highlight each item on a web page", target: nil, action: nil)
    private let escape = NSButton(checkboxWithTitle: "Prevent ESC from exiting full screen", target: nil, action: nil)

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
        for box in [https, fullAddress, unicodeDomains, bookmarksInNewTabs, favourites, wraps, glance,
                    compactButtons, pictureInPicture, minimumFont, tabFocus, escape] {
            box.target = self
            box.action = #selector(changed)
        }
        form.addRow("HTTPS", https)
        form.addNote("Sites WebKit knows offer HTTPS are loaded over it even when a link says http.")

        let display = NSStackView(views: [fullAddress, unicodeDomains])
        display.orientation = .vertical
        display.alignment = .leading
        display.spacing = 8
        form.addRow("URL display", display)
        form.addNote("Show domains with special characters (e.g. na\u{00ef}ve.com) instead of encoded format. May make some spoofed domains harder to recognise.")

        form.addRow("Bookmarks", bookmarksInNewTabs)
        form.addRow("Navigation", favourites)
        form.addRow("Space switcher", wraps)
        form.addRow("Link Preview", glance)
        form.addRow("Compact Mode", compactButtons)
        form.addRow("Picture in Picture", pictureInPicture)

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
        let sizeRow = NSStackView(views: [minimumFont, fontSize, fontStepper])
        sizeRow.orientation = .horizontal
        sizeRow.spacing = 4
        let accessibility = NSStackView(views: [sizeRow, tabFocus, escape])
        accessibility.orientation = .vertical
        accessibility.alignment = .leading
        accessibility.spacing = 8
        form.addRow("Accessibility", accessibility)
    }

    private func reload() {
        https.state = settings.upgradesToHTTPS ? .on : .off
        fullAddress.state = settings.showsFullAddress ? .on : .off
        unicodeDomains.state = settings.showsUnicodeDomains ? .on : .off
        bookmarksInNewTabs.state = settings.opensBookmarksInNewTabs ? .on : .off
        favourites.state = settings.favouriteShortcutsEnabled ? .on : .off
        wraps.state = settings.spaceSwitchWraps ? .on : .off
        glance.state = settings.opensExternalLinksInGlance ? .on : .off
        compactButtons.state = settings.compactModeShowsWindowButtons ? .on : .off
        pictureInPicture.state = settings.confirmsClosingPictureInPicture ? .on : .off
        minimumFont.state = settings.minimumFontSizeEnabled ? .on : .off
        fontSize.integerValue = settings.minimumFontSize
        fontStepper.integerValue = settings.minimumFontSize
        fontSize.isEnabled = settings.minimumFontSizeEnabled
        fontStepper.isEnabled = settings.minimumFontSizeEnabled
        tabFocus.state = settings.tabFocusesLinks ? .on : .off
        escape.state = settings.preventsEscapeExitingFullScreen ? .on : .off
    }

    @objc private func changed() {
        settings.upgradesToHTTPS = https.state == .on
        settings.showsFullAddress = fullAddress.state == .on
        settings.showsUnicodeDomains = unicodeDomains.state == .on
        settings.opensBookmarksInNewTabs = bookmarksInNewTabs.state == .on
        settings.favouriteShortcutsEnabled = favourites.state == .on
        settings.spaceSwitchWraps = wraps.state == .on
        settings.opensExternalLinksInGlance = glance.state == .on
        settings.compactModeShowsWindowButtons = compactButtons.state == .on
        settings.confirmsClosingPictureInPicture = pictureInPicture.state == .on
        settings.minimumFontSizeEnabled = minimumFont.state == .on
        settings.tabFocusesLinks = tabFocus.state == .on
        settings.preventsEscapeExitingFullScreen = escape.state == .on
        fontSize.isEnabled = settings.minimumFontSizeEnabled
        fontStepper.isEnabled = settings.minimumFontSizeEnabled
        session?.applyWebPreferences()
        session?.changes.send(.activeTab)
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
}
