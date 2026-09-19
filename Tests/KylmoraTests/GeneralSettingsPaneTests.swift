import AppKit
import Testing
@testable import Kylmora

// Every control on the General pane, driven the way a click drives it: set the
// control, fire its action, read what the pane wrote -- then reload the pane
// from the settings and check the control comes back saying the same thing.
//
// Written after an audit found "Default space" resetting itself at every
// launch: a pop-up can look right, write right, and still be wrong the next
// time the pane is built, so both directions are checked for every control.

/// The pane, its settings and a way to find the controls on it.
@MainActor
private struct Pane {
    let settings: Settings
    let session: BrowserSession?
    let controller: GeneralSettingsViewController
    let sessionFile: URL?

    init(withSession: Bool = false) {
        let defaults = UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!
        settings = Settings(defaults: defaults)
        if withSession {
            let file = FileManager.default.temporaryDirectory
                .appending(path: "kylmora-general-\(UUID().uuidString).json")
            sessionFile = file
            let store = SessionStore(fileURL: file)
            let session = BrowserSession(database: nil, sessionStore: store, settings: settings)
            _ = session.addSpace(named: "Work")
            _ = session.addSpace(named: "Reading")
            self.session = session
        } else {
            sessionFile = nil
            session = nil
        }
        controller = GeneralSettingsViewController(settings: settings, session: session)
        let view = controller.view
        view.frame = NSRect(x: 0, y: 0, width: Style.SettingsUI.contentMaxWidth, height: 2400)
        view.layoutSubtreeIfNeeded()
    }

    func cleanUp() {
        if let sessionFile { try? FileManager.default.removeItem(at: sessionFile) }
    }

    /// Builds the pane again from the same settings, which is what happens
    /// when the window is reopened: the surest test of what was stored.
    func reopened() -> GeneralSettingsViewController {
        let fresh = GeneralSettingsViewController(settings: settings, session: session)
        let view = fresh.view
        view.frame = NSRect(x: 0, y: 0, width: Style.SettingsUI.contentMaxWidth, height: 2400)
        view.layoutSubtreeIfNeeded()
        return fresh
    }

    // MARK: - Finding controls

    static func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { ($0 as? T).map { [$0] } ?? all(type, in: $0) }
    }

    var popUps: [NSPopUpButton] { Self.all(NSPopUpButton.self, in: controller.view) }

    /// The pop-up offering exactly these options.
    func popUp(offering titles: [String], in controller: NSViewController? = nil) -> NSPopUpButton? {
        let root = (controller ?? self.controller).view
        return Self.all(NSPopUpButton.self, in: root).first { $0.itemTitles == titles }
    }

    /// The switch the form shows for a checkbox.
    ///
    /// The pane builds `NSButton(checkboxWithTitle:)`, and the form hands it to
    /// a `SettingsSwitchAdaptor`: the checkbox becomes the model, off the view
    /// tree, and what is on screen is a `SettingsToggle` wearing its title as
    /// an accessibility label. Tests drive what is on screen.
    func toggle(saying fragment: String, in controller: NSViewController? = nil) -> SettingsToggle? {
        let root = (controller ?? self.controller).view
        return Self.all(SettingsToggle.self, in: root).first {
            ($0.accessibilityLabel() ?? "").localizedCaseInsensitiveContains(fragment)
        }
    }

    var homepageField: NSTextField? {
        Self.all(NSTextField.self, in: controller.view).first { $0.isEditable }
    }

    func button(titled title: String) -> NSButton? {
        Self.all(NSButton.self, in: controller.view).first { $0.title == title }
    }
}

/// Picks an option and tells the pane, exactly as a click on the menu does.
@MainActor
private func choose(_ popUp: NSPopUpButton?, _ index: Int) {
    guard let popUp, let action = popUp.action else {
        Issue.record("a pop-up on the General pane has no action")
        return
    }
    popUp.selectItem(at: index)
    _ = popUp.target?.perform(action, with: popUp)
}

/// Flips a switch the way a click on it does: the toggle flips, tells its
/// adaptor, and the adaptor sends the pane the checkbox's own action.
@MainActor
private func click(_ toggle: SettingsToggle?) {
    guard let toggle else {
        Issue.record("a switch is missing from the General pane")
        return
    }
    #expect(toggle.accessibilityPerformPress(), "the switch refused the press")
}

/// Commits what is in a text field, as pressing Return does.
@MainActor
private func commit(_ field: NSTextField?, _ text: String) {
    guard let field, let action = field.action else {
        Issue.record("the homepage field has no action")
        return
    }
    field.stringValue = text
    _ = field.target?.perform(action, with: field)
}

@Suite("The General pane's controls", .serialized)
@MainActor
struct GeneralPaneWiringTests {
    @Test("Every control on the pane is connected to something")
    func nothingIsDecorative() {
        let pane = Pane(withSession: true)
        defer { pane.cleanUp() }
        for popUp in pane.popUps where popUp.isEnabled {
            #expect(popUp.action != nil, "a pop-up offering \(popUp.itemTitles) does nothing")
            #expect(popUp.target != nil, "a pop-up offering \(popUp.itemTitles) has no target")
        }
        for name in ["safe", "Command Palette", "warning before quitting"] {
            let box = pane.toggle(saying: name)
            #expect(box != nil, "the \(name) switch is missing")
            #expect(box?.action != nil, "the \(name) switch does nothing")
            #expect(box?.target != nil, "the \(name) switch has no target")
        }
        #expect(pane.homepageField?.action != nil)
        #expect(pane.button(titled: "Set to Current Page")?.action != nil)
        #expect(pane.button(titled: "Manage Spaces\u{2026}")?.action != nil)
    }

    @Test("Each pop-up offers exactly the choices its setting has")
    func everyChoiceIsOffered() {
        let pane = Pane()
        defer { pane.cleanUp() }
        #expect(pane.popUp(offering: ["Tabs and spaces from last session", "A new tab"]) != nil)
        #expect(pane.popUp(offering: NewTabTarget.allCases.map(\.title)) != nil)
        #expect(pane.popUp(offering: DownloadLocation.allCases.map(\.title)) != nil)
        #expect(pane.popUp(offering: DownloadRemoval.allCases.map(\.title)) != nil)
        #expect(pane.popUp(offering: AppearancePreference.allCases.map(\.title)) != nil)
        #expect(pane.popUp(offering: TabIdleBadgeMode.allCases.map(\.title)) != nil)
        #expect(pane.popUp(offering: ExternalLinkTarget.allCases.map(\.title)) != nil)
        #expect(pane.popUp(offering: SidebarWidthScope.allCases.map(\.title)) != nil)
        #expect(pane.popUp(offering: ["English"]) != nil)
    }

    @Test("The language pop-up is there but not offered")
    func languageIsNotAChoiceYet() {
        let pane = Pane()
        defer { pane.cleanUp() }
        let language = pane.popUp(offering: ["English"])
        #expect(language?.isEnabled == false, "one language is not a choice")
    }
}

@Suite("What the General pane stores", .serialized)
@MainActor
struct GeneralPaneStorageTests {
    // MARK: - Opening

    @Test("Kylmora opens with: both answers stored and read back")
    func opensWith() {
        let pane = Pane()
        defer { pane.cleanUp() }
        let popUp = pane.popUp(offering: ["Tabs and spaces from last session", "A new tab"])
        choose(popUp, 1)
        #expect(pane.settings.restoresSession == false)
        #expect(pane.popUp(offering: ["Tabs and spaces from last session", "A new tab"], in: pane.reopened())?
            .indexOfSelectedItem == 1)
        choose(popUp, 0)
        #expect(pane.settings.restoresSession)
        #expect(pane.popUp(offering: ["Tabs and spaces from last session", "A new tab"], in: pane.reopened())?
            .indexOfSelectedItem == 0)
    }

    @Test("New tabs open with: every target", arguments: Array(NewTabTarget.allCases.enumerated()))
    func newTabTarget(index: Int, target: NewTabTarget) {
        let pane = Pane()
        defer { pane.cleanUp() }
        choose(pane.popUp(offering: NewTabTarget.allCases.map(\.title)), index)
        #expect(pane.settings.newTabTarget == target)
        #expect(pane.popUp(offering: NewTabTarget.allCases.map(\.title), in: pane.reopened())?
            .titleOfSelectedItem == target.title)
    }

    @Test("The command palette checkbox goes both ways")
    func commandPalette() {
        let pane = Pane()
        defer { pane.cleanUp() }
        let box = pane.toggle(saying: "Command Palette")
        #expect(box?.isOn == true, "on unless turned off")
        click(box)
        #expect(pane.settings.openCommandBarOnNewTab == false)
        #expect(pane.toggle(saying: "Command Palette", in: pane.reopened())?.isOn == false)
        click(box)
        #expect(pane.settings.openCommandBarOnNewTab)
    }

    // MARK: - Homepage

    @Test("A bare domain becomes an address")
    func homepageGainsAScheme() {
        let pane = Pane()
        defer { pane.cleanUp() }
        commit(pane.homepageField, "example.com")
        #expect(pane.settings.homepageURL?.absoluteString == "https://example.com")
        #expect(pane.homepageField?.stringValue == "https://example.com", "the field shows what was stored")
    }

    @Test("An address is kept as typed", arguments: [
        "https://example.com/start", "http://example.com/", "https://sub.example.co.uk/a/b?c=d"
    ])
    func homepageKeepsRealAddresses(text: String) {
        let pane = Pane()
        defer { pane.cleanUp() }
        commit(pane.homepageField, text)
        #expect(pane.settings.homepageURL?.absoluteString == text)
    }

    @Test("Nothing usable is stored as nothing", arguments: ["", "   ", "not a url at all"])
    func homepageRejectsNonsense(text: String) {
        let pane = Pane()
        defer { pane.cleanUp() }
        commit(pane.homepageField, "https://example.com/")
        commit(pane.homepageField, text)
        #expect(pane.settings.homepageURL == nil)
        #expect(pane.homepageField?.stringValue == "", "the field says what was stored: nothing")
    }

    @Test("Surrounding space is not part of the address")
    func homepageIsTrimmed() {
        let pane = Pane()
        defer { pane.cleanUp() }
        commit(pane.homepageField, "  https://example.com/  ")
        #expect(pane.settings.homepageURL?.absoluteString == "https://example.com/")
    }

    @Test("Set to Current Page takes the page in front")
    func setToCurrentPage() {
        let pane = Pane()
        defer { pane.cleanUp() }
        pane.controller.currentPageURL = { URL(string: "https://kylmora.com/pricing")! }
        let button = pane.button(titled: "Set to Current Page")
        _ = button?.target?.perform(button!.action!, with: button)
        #expect(pane.settings.homepageURL?.absoluteString == "https://kylmora.com/pricing")
        #expect(pane.homepageField?.stringValue == "https://kylmora.com/pricing")
    }

    @Test("With no page in front it changes nothing")
    func setToCurrentPageWithNoPage() {
        let pane = Pane()
        defer { pane.cleanUp() }
        commit(pane.homepageField, "https://example.com/")
        pane.controller.currentPageURL = { nil }
        let button = pane.button(titled: "Set to Current Page")
        _ = button?.target?.perform(button!.action!, with: button)
        #expect(pane.settings.homepageURL?.absoluteString == "https://example.com/")
    }

    // MARK: - Downloads

    @Test("File download location: every choice", arguments: Array(DownloadLocation.allCases.enumerated()))
    func downloadLocation(index: Int, location: DownloadLocation) {
        let pane = Pane()
        defer { pane.cleanUp() }
        choose(pane.popUp(offering: DownloadLocation.allCases.map(\.title)), index)
        #expect(pane.settings.downloadLocation == location)
        #expect(pane.popUp(offering: DownloadLocation.allCases.map(\.title), in: pane.reopened())?
            .titleOfSelectedItem == location.title)
    }

    @Test("Remove download items: every choice", arguments: Array(DownloadRemoval.allCases.enumerated()))
    func downloadRemoval(index: Int, removal: DownloadRemoval) {
        let pane = Pane()
        defer { pane.cleanUp() }
        choose(pane.popUp(offering: DownloadRemoval.allCases.map(\.title)), index)
        #expect(pane.settings.downloadRemoval == removal)
        #expect(pane.popUp(offering: DownloadRemoval.allCases.map(\.title), in: pane.reopened())?
            .titleOfSelectedItem == removal.title)
    }

    @Test("Opening safe files goes both ways")
    func safeFiles() {
        let pane = Pane()
        defer { pane.cleanUp() }
        let box = pane.toggle(saying: "safe")
        #expect(box?.isOn == false, "off unless asked for")
        click(box)
        #expect(pane.settings.opensSafeFilesAfterDownloading)
        #expect(pane.toggle(saying: "safe", in: pane.reopened())?.isOn == true)
        click(box)
        #expect(pane.settings.opensSafeFilesAfterDownloading == false)
    }

    // MARK: - Appearance and tab lifecycle

    @Test("Appearance: every choice", arguments: Array(AppearancePreference.allCases.enumerated()))
    func appearance(index: Int, preference: AppearancePreference) {
        let pane = Pane()
        defer { pane.cleanUp() }
        // The pane applies what it stores, which is the whole application's
        // appearance: put it back the way the test found it.
        let before = NSApp.appearance
        defer { NSApp.appearance = before }
        choose(pane.popUp(offering: AppearancePreference.allCases.map(\.title)), index)
        #expect(pane.settings.appearance == preference)
        #expect(pane.popUp(offering: AppearancePreference.allCases.map(\.title), in: pane.reopened())?
            .titleOfSelectedItem == preference.title)
    }

    @Test("Sleep after: every choice, and each says what it means")
    func suspension() {
        let pane = Pane()
        defer { pane.cleanUp() }
        let titles = Settings.suspensionChoices.map { $0 == 0 ? "Never" : "\($0) minutes" }
        let popUp = pane.popUp(offering: titles)
        #expect(popUp != nil, "the sleep pop-up should offer \(titles)")
        for (index, minutes) in Settings.suspensionChoices.enumerated() {
            choose(popUp, index)
            #expect(pane.settings.tabSuspensionMinutes == minutes)
            #expect(pane.popUp(offering: titles, in: pane.reopened())?.indexOfSelectedItem == index,
                    "\(minutes) minutes did not come back")
        }
    }

    @Test("Archive after: every choice, and each says what it means")
    func archiving() {
        let pane = Pane()
        defer { pane.cleanUp() }
        let titles = ["Never", "12 hours", "1 day", "3 days", "1 week", "30 days"]
        #expect(Settings.archiveChoices == [0, 12, 24, 72, 168, 720])
        let popUp = pane.popUp(offering: titles)
        #expect(popUp != nil, "the archive pop-up should offer \(titles)")
        for (index, hours) in Settings.archiveChoices.enumerated() {
            choose(popUp, index)
            #expect(pane.settings.tabArchiveHours == hours)
            #expect(pane.popUp(offering: titles, in: pane.reopened())?.indexOfSelectedItem == index,
                    "\(hours) hours did not come back")
        }
    }

    @Test("Archiving is off until it is asked for")
    func archivingStartsOff() {
        let pane = Pane()
        defer { pane.cleanUp() }
        #expect(pane.settings.tabArchiveHours == 0)
    }

    @Test("Show time since last use: every choice", arguments: Array(TabIdleBadgeMode.allCases.enumerated()))
    func idleBadge(index: Int, mode: TabIdleBadgeMode) {
        let pane = Pane()
        defer { pane.cleanUp() }
        choose(pane.popUp(offering: TabIdleBadgeMode.allCases.map(\.title)), index)
        #expect(pane.settings.tabIdleBadgeMode == mode)
        #expect(pane.popUp(offering: TabIdleBadgeMode.allCases.map(\.title), in: pane.reopened())?
            .titleOfSelectedItem == mode.title)
    }

    // MARK: - Spaces, links, sidebar, quitting

    @Test("Open external links in: every choice", arguments: Array(ExternalLinkTarget.allCases.enumerated()))
    func externalLinks(index: Int, target: ExternalLinkTarget) {
        let pane = Pane()
        defer { pane.cleanUp() }
        choose(pane.popUp(offering: ExternalLinkTarget.allCases.map(\.title)), index)
        #expect(pane.settings.externalLinkTarget == target)
        #expect(pane.popUp(offering: ExternalLinkTarget.allCases.map(\.title), in: pane.reopened())?
            .titleOfSelectedItem == target.title)
    }

    @Test("Sidebar width: shared and its own")
    func sidebarWidthScope() {
        let pane = Pane()
        defer { pane.cleanUp() }
        let titles = SidebarWidthScope.allCases.map(\.title)
        choose(pane.popUp(offering: titles), SidebarWidthScope.perSpace.rawValue)
        #expect(pane.settings.sidebarWidthIsPerSpace)
        #expect(pane.popUp(offering: titles, in: pane.reopened())?.indexOfSelectedItem
            == SidebarWidthScope.perSpace.rawValue)
        choose(pane.popUp(offering: titles), SidebarWidthScope.shared.rawValue)
        #expect(pane.settings.sidebarWidthIsPerSpace == false)
        #expect(pane.popUp(offering: titles, in: pane.reopened())?.indexOfSelectedItem
            == SidebarWidthScope.shared.rawValue)
    }

    @Test("The quit warning goes both ways")
    func quitWarning() {
        let pane = Pane()
        defer { pane.cleanUp() }
        let box = pane.toggle(saying: "warning before quitting")
        #expect(box?.isOn == true, "on unless turned off")
        click(box)
        #expect(pane.settings.warnsBeforeQuitting == false)
        #expect(pane.toggle(saying: "warning before quitting", in: pane.reopened())?.isOn == false)
        click(box)
        #expect(pane.settings.warnsBeforeQuitting)
    }
}

// The default space is the control that was broken: it wrote an identifier
// that was made fresh at every launch, so the pane came back on the next one
// saying the first space, whatever had been chosen.

@Suite("The default space", .serialized)
@MainActor
struct GeneralPaneDefaultSpaceTests {
    private func spacePopUp(_ pane: Pane, in controller: NSViewController? = nil) -> NSPopUpButton? {
        let names = pane.session?.spaces.map(\.name) ?? []
        return pane.popUp(offering: names, in: controller)
    }

    @Test("It lists the session's spaces, in order, with their colours")
    func itListsTheSpaces() {
        let pane = Pane(withSession: true)
        defer { pane.cleanUp() }
        guard let session = pane.session, let popUp = spacePopUp(pane) else {
            Issue.record("the pane should offer the session's spaces")
            return
        }
        #expect(popUp.itemTitles == session.spaces.map(\.name))
        #expect(popUp.itemArray.allSatisfy { $0.image != nil }, "each space is shown by its dot")
    }

    @Test("Choosing a space stores that space")
    func choosingWrites() {
        let pane = Pane(withSession: true)
        defer { pane.cleanUp() }
        guard let session = pane.session else { return }
        choose(spacePopUp(pane), 2)
        #expect(pane.settings.defaultSpaceID == session.spaces[2].id)
        #expect(session.defaultSpace.id == session.spaces[2].id)
    }

    @Test("Reopening the pane shows the space that was chosen")
    func theChoiceComesBack() {
        let pane = Pane(withSession: true)
        defer { pane.cleanUp() }
        choose(spacePopUp(pane), 1)
        #expect(spacePopUp(pane, in: pane.reopened())?.indexOfSelectedItem == 1)
    }

    @Test("It survives the session being restored from disk")
    func theChoiceSurvivesARelaunch() {
        let pane = Pane(withSession: true)
        defer { pane.cleanUp() }
        guard let session = pane.session else { return }
        choose(spacePopUp(pane), 1)
        let chosen = session.spaces[1]
        session.saveNow()

        // A second session over the same file is what the next launch is.
        guard let file = pane.sessionFile else {
            Issue.record("the test session should have a file of its own")
            return
        }
        let restored = BrowserSession(
            database: nil,
            sessionStore: SessionStore(fileURL: file),
            settings: pane.settings
        )
        #expect(restored.spaces.map(\.name) == session.spaces.map(\.name))
        #expect(restored.defaultSpace.id == chosen.id, "the chosen space came back as someone else")
        #expect(restored.defaultSpace.name == chosen.name)
    }

    @Test("An identifier for a space that is gone falls back to the first")
    func aMissingSpaceFallsBack() {
        let pane = Pane(withSession: true)
        defer { pane.cleanUp() }
        guard let session = pane.session else { return }
        pane.settings.defaultSpaceID = UUID()
        #expect(session.defaultSpace.id == session.spaces[0].id)
        // And the pane says so rather than showing an empty selection.
        #expect(spacePopUp(pane, in: pane.reopened())?.indexOfSelectedItem == 0)
    }
}

// The pane is built once and reopened many times, and the settings behind it
// can change while it is on screen -- from another window, from a menu, from
// the companion phone. Everything on it is rebuilt from the settings when it
// appears, and these are the cases where that used to be the difference
// between a pane that is right and a pane that merely looks right.

@Suite("The General pane keeps up", .serialized)
@MainActor
struct GeneralPaneRefreshTests {
    @Test("A setting changed elsewhere shows on the pane when it appears")
    func thePaneIsNeverStale() {
        let pane = Pane()
        defer { pane.cleanUp() }
        let before = NSApp.appearance
        defer { NSApp.appearance = before }

        pane.settings.appearance = .dark
        pane.settings.newTabTarget = .homepage
        pane.settings.tabSuspensionMinutes = 60
        pane.settings.tabArchiveHours = 168
        pane.settings.tabIdleBadgeMode = .all
        pane.settings.externalLinkTarget = .defaultSpace
        pane.settings.downloadRemoval = .onQuit
        pane.settings.opensSafeFilesAfterDownloading = true
        pane.settings.warnsBeforeQuitting = false
        pane.settings.openCommandBarOnNewTab = false
        pane.settings.homepageURL = URL(string: "https://example.com/")
        pane.controller.viewWillAppear()

        #expect(pane.popUp(offering: AppearancePreference.allCases.map(\.title))?.titleOfSelectedItem == "Dark")
        #expect(pane.popUp(offering: NewTabTarget.allCases.map(\.title))?.titleOfSelectedItem == NewTabTarget.homepage.title)
        #expect(pane.popUp(offering: Settings.suspensionChoices.map { $0 == 0 ? "Never" : "\($0) minutes" })?
            .titleOfSelectedItem == "60 minutes")
        #expect(pane.popUp(offering: ["Never", "12 hours", "1 day", "3 days", "1 week", "30 days"])?
            .titleOfSelectedItem == "1 week")
        #expect(pane.popUp(offering: TabIdleBadgeMode.allCases.map(\.title))?.titleOfSelectedItem == TabIdleBadgeMode.all.title)
        #expect(pane.popUp(offering: ExternalLinkTarget.allCases.map(\.title))?.titleOfSelectedItem == ExternalLinkTarget.defaultSpace.title)
        #expect(pane.popUp(offering: DownloadRemoval.allCases.map(\.title))?.titleOfSelectedItem == DownloadRemoval.onQuit.title)
        #expect(pane.toggle(saying: "safe")?.isOn == true)
        #expect(pane.toggle(saying: "warning before quitting")?.isOn == false)
        #expect(pane.toggle(saying: "Command Palette")?.isOn == false)
        #expect(pane.homepageField?.stringValue == "https://example.com/")
    }

    @Test("A space made after the pane was built is on the list when it appears again")
    func newSpacesArrive() {
        let pane = Pane(withSession: true)
        defer { pane.cleanUp() }
        guard let session = pane.session else { return }
        let before = pane.popUp(offering: session.spaces.map(\.name))
        #expect(before != nil)

        let added = session.addSpace(named: "Later")
        pane.controller.viewWillAppear()
        let after = pane.popUp(offering: session.spaces.map(\.name))
        #expect(after?.itemTitles.last == "Later")
        #expect(after?.itemTitles.count == session.spaces.count)
        #expect(session.spaces.last?.id == added.id)
    }

    @Test("A renamed space is renamed on the list too")
    func renamedSpaces() {
        let pane = Pane(withSession: true)
        defer { pane.cleanUp() }
        guard let session = pane.session, let space = session.spaces.last else { return }
        session.rename(space, to: "Renamed")
        pane.controller.viewWillAppear()
        #expect(pane.popUp(offering: session.spaces.map(\.name))?.itemTitles.last == "Renamed")
    }

    @Test("Every choice the pane stores is still there for the next launch")
    func everythingSurvivesARelaunch() {
        let defaults = UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!
        let settings = Settings(defaults: defaults)
        settings.restoresSession = false
        settings.newTabTarget = .startPage
        settings.openCommandBarOnNewTab = false
        settings.homepageURL = URL(string: "https://example.com/")
        settings.downloadLocation = .ask
        settings.downloadRemoval = .uponSuccess
        settings.opensSafeFilesAfterDownloading = true
        settings.appearance = .light
        settings.tabSuspensionMinutes = 30
        settings.tabArchiveHours = 72
        settings.tabIdleBadgeMode = .never
        settings.externalLinkTarget = .defaultSpace
        settings.sidebarWidthIsPerSpace = true
        settings.warnsBeforeQuitting = false

        // A second `Settings` over the same defaults is what the next launch
        // reads: nothing here is held in memory by the first one.
        let next = Settings(defaults: defaults)
        #expect(next.restoresSession == false)
        #expect(next.newTabTarget == .startPage)
        #expect(next.openCommandBarOnNewTab == false)
        #expect(next.homepageURL?.absoluteString == "https://example.com/")
        #expect(next.downloadLocation == .ask)
        #expect(next.downloadRemoval == .uponSuccess)
        #expect(next.opensSafeFilesAfterDownloading)
        #expect(next.appearance == .light)
        #expect(next.tabSuspensionMinutes == 30)
        #expect(next.tabArchiveHours == 72)
        #expect(next.tabIdleBadgeMode == .never)
        #expect(next.externalLinkTarget == .defaultSpace)
        #expect(next.sidebarWidthIsPerSpace)
        #expect(next.warnsBeforeQuitting == false)
    }

    @Test("A pop-up with nothing chosen changes nothing")
    func noSelectionChangesNothing() {
        let pane = Pane(withSession: true)
        defer { pane.cleanUp() }
        let before = NSApp.appearance
        defer { NSApp.appearance = before }

        // What a pane sees when a menu is rebuilt and nothing is selected yet.
        // Every action on the pane guards its index; this is that guard.
        pane.settings.appearance = .dark
        pane.settings.newTabTarget = .homepage
        pane.settings.downloadLocation = .ask
        pane.settings.tabArchiveHours = 72
        pane.settings.restoresSession = true
        pane.settings.sidebarWidthIsPerSpace = true
        for popUp in pane.popUps where popUp.isEnabled {
            popUp.select(nil)
            if let action = popUp.action { _ = popUp.target?.perform(action, with: popUp) }
        }
        #expect(pane.settings.appearance == .dark)
        #expect(pane.settings.newTabTarget == .homepage)
        #expect(pane.settings.downloadLocation == .ask)
        #expect(pane.settings.tabArchiveHours == 72)
        #expect(pane.settings.restoresSession, "an empty selection turned session restore off")
        #expect(pane.settings.sidebarWidthIsPerSpace, "an empty selection reset the sidebar width")
    }
}
