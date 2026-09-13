import AppKit

/// The General pane: what Kylmora opens with, what new tabs open with, the
/// homepage, appearance, tab suspension, and whether Kylmora is the default
/// browser. The search engine is on the Search pane.
@MainActor
final class GeneralSettingsViewController: NSViewController {
    private let settings: Settings
    private let opensWithPopUp = NSPopUpButton()
    private let newTabsPopUp = NSPopUpButton()
    private let homepageField = NSTextField()
    private let appearancePopUp = NSPopUpButton()
    private let suspensionPopUp = NSPopUpButton()
    private let archivePopUp = NSPopUpButton()
    private let idleBadgePopUp = NSPopUpButton()
    private let defaultBrowserLabel = NSTextField(labelWithString: "")
    private let setDefaultButton = NSButton(title: "Set Default\u{2026}", target: nil, action: nil)
    private let locationPopUp = NSPopUpButton()
    private let removalPopUp = NSPopUpButton()
    private let safeFiles = NSButton(checkboxWithTitle: "Open \u{201c}safe\u{201d} files after downloading", target: nil, action: nil)
    private let languagePopUp = NSPopUpButton()
    private let spacePopUp = NSPopUpButton()
    private let externalPopUp = NSPopUpButton()
    private let quitWarning = NSButton(checkboxWithTitle: "Show warning before quitting", target: nil, action: nil)
    private let session: BrowserSession?

    /// The page in front, for "Set to Current Page". Nil when there is none.
    var currentPageURL: (() -> URL?)?

    init(settings: Settings = .shared, session: BrowserSession? = nil) {
        self.settings = settings
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("GeneralSettingsViewController is created in code only")
    }

    override func loadView() {
        let form = SettingsForm()
        view = form
        buildLayout(in: form)
        reload()
    }

    /// Spaces may have been made or renamed since the pane was built, and
    /// the default browser may have changed outside Kylmora.
    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }

    private func buildLayout(in form: SettingsForm) {
        opensWithPopUp.addItems(withTitles: ["Tabs and spaces from last session", "A new tab"])
        opensWithPopUp.target = self
        opensWithPopUp.action = #selector(opensWithChanged)
        form.addRow("Kylmora opens with", SettingsForm.fill(opensWithPopUp))

        newTabsPopUp.addItems(withTitles: NewTabTarget.allCases.map(\.title))
        newTabsPopUp.target = self
        newTabsPopUp.action = #selector(newTabsChanged)
        form.addRow("New tabs open with", SettingsForm.fill(newTabsPopUp))

        homepageField.placeholderString = "https://"
        homepageField.target = self
        homepageField.action = #selector(homepageCommitted)
        form.addRow("Homepage", SettingsForm.fill(homepageField))
        let setToCurrent = NSButton(title: "Set to Current Page", target: self, action: #selector(setHomepageToCurrent))
        setToCurrent.bezelStyle = .rounded
        form.addContinuation(setToCurrent)

        form.addSeparator()

        locationPopUp.addItems(withTitles: DownloadLocation.allCases.map(\.title))
        locationPopUp.target = self
        locationPopUp.action = #selector(locationChanged)
        form.addRow("File download location", SettingsForm.fill(locationPopUp))

        removalPopUp.addItems(withTitles: DownloadRemoval.allCases.map(\.title))
        removalPopUp.target = self
        removalPopUp.action = #selector(removalChanged)
        form.addRow("Remove download items", SettingsForm.fill(removalPopUp))
        safeFiles.target = self
        safeFiles.action = #selector(safeFilesChanged)
        form.addContinuation(safeFiles)
        form.addNote("\u{201c}Safe\u{201d} files include movies, pictures, sounds, PDF and text documents, and archives.")

        languagePopUp.addItems(withTitles: ["English"])
        languagePopUp.isEnabled = false
        form.addRow("Language", SettingsForm.fill(languagePopUp))
        form.addNote("Kylmora is in English so far. More languages will appear here as they are added.")

        appearancePopUp.addItems(withTitles: AppearancePreference.allCases.map(\.title))
        appearancePopUp.target = self
        appearancePopUp.action = #selector(appearanceChanged)
        form.addRow("Appearance", SettingsForm.fill(appearancePopUp))

        suspensionPopUp.addItems(withTitles: Settings.suspensionChoices.map(Self.suspensionTitle))
        suspensionPopUp.target = self
        suspensionPopUp.action = #selector(suspensionChanged)
        form.addRow("Put inactive tabs to sleep after", SettingsForm.fill(suspensionPopUp))
        form.addNote("""
            A sleeping tab gives its memory back and reopens where you left it. \
            It stays in the sidebar, dimmed, with a moon beside it. Tabs you have \
            set to Keep Awake are left alone, unless macOS itself runs critically \
            short of memory.
            """)

        archivePopUp.addItems(withTitles: Settings.archiveChoices.map(Self.archiveTitle))
        archivePopUp.target = self
        archivePopUp.action = #selector(archiveChanged)
        form.addRow("Then archive them after", SettingsForm.fill(archivePopUp))
        form.addNote("""
            Off unless you turn it on. A sleeping tab that stays untouched for this \
            long \u{2014} including one you opened in the background and never read \u{2014} \
            leaves the sidebar for the Archive, where you can read it or put it \
            back. Pinned tabs, Essentials, split panes, Live Folder tabs and tabs you \
            have set to Keep in Sidebar are never archived, and nothing is archived \
            from a private space.
            """)

        idleBadgePopUp.addItems(withTitles: TabIdleBadgeMode.allCases.map(\.title))
        idleBadgePopUp.target = self
        idleBadgePopUp.action = #selector(idleBadgeChanged)
        form.addRow("Show time since last use", SettingsForm.fill(idleBadgePopUp))
        form.addNote("A small timer on the tab row, such as 10m or 2h. The tab you are reading never shows one.")

        form.addSeparator()

        spacePopUp.target = self
        spacePopUp.action = #selector(defaultSpaceChanged)
        spacePopUp.translatesAutoresizingMaskIntoConstraints = false
        spacePopUp.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let manageSpaces = NSButton(title: "Manage Spaces\u{2026}", target: self, action: #selector(manageSpaces))
        manageSpaces.bezelStyle = .rounded
        form.addRow("Default space", [spacePopUp, manageSpaces])

        externalPopUp.addItems(withTitles: ExternalLinkTarget.allCases.map(\.title))
        externalPopUp.target = self
        externalPopUp.action = #selector(externalChanged)
        form.addRow("Open external links in", SettingsForm.fill(externalPopUp))

        form.addSeparator()

        quitWarning.target = self
        quitWarning.action = #selector(quitWarningChanged)
        form.addRow("Quitting", quitWarning)

        form.addSeparator()

        defaultBrowserLabel.alignment = .left
        setDefaultButton.target = self
        setDefaultButton.action = #selector(setDefaultBrowser)
        setDefaultButton.bezelStyle = .rounded
        form.addRow("Default browser", [defaultBrowserLabel, setDefaultButton])
    }

    private func reload() {
        locationPopUp.selectItem(at: DownloadLocation.allCases.firstIndex(of: settings.downloadLocation) ?? 0)
        removalPopUp.selectItem(at: DownloadRemoval.allCases.firstIndex(of: settings.downloadRemoval) ?? 0)
        safeFiles.state = settings.opensSafeFilesAfterDownloading ? .on : .off
        externalPopUp.selectItem(at: ExternalLinkTarget.allCases.firstIndex(of: settings.externalLinkTarget) ?? 0)
        quitWarning.state = settings.warnsBeforeQuitting ? .on : .off
        spacePopUp.removeAllItems()
        if let session {
            for space in session.spaces {
                let item = NSMenuItem(title: space.name, action: nil, keyEquivalent: "")
                item.image = space.dotImage()
                spacePopUp.menu?.addItem(item)
            }
            if let index = session.spaces.firstIndex(where: { $0.id == session.defaultSpace.id }) {
                spacePopUp.selectItem(at: index)
            }
        }
        opensWithPopUp.selectItem(at: settings.restoresSession ? 0 : 1)
        newTabsPopUp.selectItem(withTitle: settings.newTabTarget.title)
        homepageField.stringValue = settings.homepageURL?.absoluteString ?? ""
        appearancePopUp.selectItem(withTitle: settings.appearance.title)
        suspensionPopUp.selectItem(withTitle: Self.suspensionTitle(settings.tabSuspensionMinutes))
        archivePopUp.selectItem(withTitle: Self.archiveTitle(settings.tabArchiveHours))
        idleBadgePopUp.selectItem(withTitle: settings.tabIdleBadgeMode.title)
        reloadDefaultBrowser()
    }

    private func reloadDefaultBrowser() {
        let isDefault = DefaultBrowser.isKylmora
        defaultBrowserLabel.stringValue = isDefault
            ? "Kylmora is your default web browser."
            : "Kylmora is not your default web browser."
        setDefaultButton.isHidden = isDefault
    }

    private static func suspensionTitle(_ minutes: Int) -> String {
        minutes == 0 ? "Never" : "\(minutes) minutes"
    }

    /// Hours, said the way people say them: nobody reads "168 hours" as a week.
    private static func archiveTitle(_ hours: Int) -> String {
        switch hours {
        case 0: "Never"
        case ..<24: "\(hours) hours"
        case 24: "1 day"
        case ..<168: "\(hours / 24) days"
        case 168: "1 week"
        case ..<720: "\(hours / 168) weeks"
        default: "30 days"
        }
    }

    @objc private func locationChanged() {
        guard DownloadLocation.allCases.indices.contains(locationPopUp.indexOfSelectedItem) else { return }
        settings.downloadLocation = DownloadLocation.allCases[locationPopUp.indexOfSelectedItem]
    }

    @objc private func removalChanged() {
        guard DownloadRemoval.allCases.indices.contains(removalPopUp.indexOfSelectedItem) else { return }
        settings.downloadRemoval = DownloadRemoval.allCases[removalPopUp.indexOfSelectedItem]
        DownloadManager.shared.pruneCompleted(atLaunch: false)
    }

    @objc private func safeFilesChanged() {
        settings.opensSafeFilesAfterDownloading = safeFiles.state == .on
    }

    @objc private func defaultSpaceChanged() {
        guard let session, session.spaces.indices.contains(spacePopUp.indexOfSelectedItem) else { return }
        settings.defaultSpaceID = session.spaces[spacePopUp.indexOfSelectedItem].id
    }

    @objc private func externalChanged() {
        guard ExternalLinkTarget.allCases.indices.contains(externalPopUp.indexOfSelectedItem) else { return }
        settings.externalLinkTarget = ExternalLinkTarget.allCases[externalPopUp.indexOfSelectedItem]
    }

    @objc private func manageSpaces() {
        (view.window?.windowController as? SettingsWindowController)?.select(.spaces)
    }

    @objc private func quitWarningChanged() {
        settings.warnsBeforeQuitting = quitWarning.state == .on
    }

    @objc private func opensWithChanged() {
        settings.restoresSession = opensWithPopUp.indexOfSelectedItem == 0
    }

    @objc private func newTabsChanged() {
        let index = newTabsPopUp.indexOfSelectedItem
        guard NewTabTarget.allCases.indices.contains(index) else { return }
        settings.newTabTarget = NewTabTarget.allCases[index]
    }

    @objc private func homepageCommitted() {
        let text = homepageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.homepageURL = Settings.homepageURL(from: text)
        homepageField.stringValue = settings.homepageURL?.absoluteString ?? ""
    }

    @objc private func setHomepageToCurrent() {
        guard let url = currentPageURL?() else { return }
        settings.homepageURL = url
        homepageField.stringValue = url.absoluteString
    }

    @objc private func appearanceChanged() {
        let index = appearancePopUp.indexOfSelectedItem
        guard AppearancePreference.allCases.indices.contains(index) else { return }
        settings.appearance = AppearancePreference.allCases[index]
        settings.applyAppearance()
    }

    @objc private func suspensionChanged() {
        let index = suspensionPopUp.indexOfSelectedItem
        guard Settings.suspensionChoices.indices.contains(index) else { return }
        settings.tabSuspensionMinutes = Settings.suspensionChoices[index]
    }

    @objc private func archiveChanged() {
        let index = archivePopUp.indexOfSelectedItem
        guard Settings.archiveChoices.indices.contains(index) else { return }
        settings.tabArchiveHours = Settings.archiveChoices[index]
    }

    @objc private func idleBadgeChanged() {
        let index = idleBadgePopUp.indexOfSelectedItem
        guard TabIdleBadgeMode.allCases.indices.contains(index) else { return }
        settings.tabIdleBadgeMode = TabIdleBadgeMode.allCases[index]
    }

    @objc private func setDefaultBrowser() {
        setDefaultButton.isEnabled = false
        Task { [weak self] in
            let outcome = await DefaultBrowser.makeKylmoraDefault()
            self?.setDefaultButton.isEnabled = true
            self?.reloadDefaultBrowser()
            if case .failure(let message) = outcome {
                self?.defaultBrowserLabel.stringValue = message
            }
        }
    }
}

/// What a new tab shows.
enum NewTabTarget: String, CaseIterable, Sendable {
    case startPage
    case homepage

    var title: String {
        switch self {
        case .startPage: return "Search engine start page"
        case .homepage: return "Homepage"
        }
    }
}

/// Whether Kylmora handles web links for the system, and asking to.
enum DefaultBrowser {
    enum Outcome: Equatable {
        case done
        case failure(String)
    }

    @MainActor
    static var isKylmora: Bool {
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com/")!) else {
            return false
        }
        return handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    /// macOS asks the user to confirm; the answer arrives as an error when
    /// they decline.
    @MainActor
    static func makeKylmoraDefault() async -> Outcome {
        do {
            for scheme in ["http", "https"] {
                try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme)
            }
            return .done
        } catch {
            return .failure("Could not make Kylmora the default: \(error.localizedDescription)")
        }
    }
}
