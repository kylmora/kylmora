import AppKit
import Testing
@testable import Kylmora

// Every control on the Browsing pane, driven the way a click drives it, in
// both directions, and read back from a pane built again from the same
// settings. The pane has more switches than any other in the window and they
// share a card with pop-ups, a list, a number field and two buttons, so the
// ways it can go wrong are the ways every settings pane can go wrong at once.
//
// Written after an audit found three of them at the same time: one action
// wrote every setting on the pane from every control on it, so a click on any
// switch put back whatever the pane's stale checkboxes remembered; the
// density pop-up subscripted its cases with `indexOfSelectedItem` and would
// have gone out of range on a pop-up with nothing chosen; and the number
// field took any text at all and went on showing it while the browser used
// something else.

/// The pane, its settings, and a way to find the controls on it.
@MainActor
private struct Pane {
    let settings: Settings
    let controller: BrowsingSettingsViewController

    init() {
        let defaults = UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!
        settings = Settings(defaults: defaults)
        controller = BrowsingSettingsViewController(settings: settings, session: nil)
        // Nothing here may open a sheet: a test that asks the user a question
        // waits for an answer that never comes.
        controller.confirmsWebPanelReset = { false }
        let view = controller.view
        view.frame = NSRect(x: 0, y: 0, width: Style.SettingsUI.contentMaxWidth, height: 3200)
        view.layoutSubtreeIfNeeded()
    }

    /// The pane built again from the same settings: what happens when the
    /// window is closed and reopened, and the surest test of what was stored.
    func reopened() -> BrowsingSettingsViewController {
        let fresh = BrowsingSettingsViewController(settings: settings, session: nil)
        fresh.confirmsWebPanelReset = { false }
        let view = fresh.view
        view.frame = NSRect(x: 0, y: 0, width: Style.SettingsUI.contentMaxWidth, height: 3200)
        view.layoutSubtreeIfNeeded()
        return fresh
    }

    // MARK: - Finding controls

    static func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { ($0 as? T).map { [$0] } ?? all(type, in: $0) }
    }

    /// The pop-up offering exactly these options.
    func popUp(offering titles: [String], in controller: NSViewController? = nil) -> NSPopUpButton? {
        let root = (controller ?? self.controller).view
        return Self.all(NSPopUpButton.self, in: root).first { $0.itemTitles == titles }
    }

    /// The switch the form shows for a checkbox: the checkbox is the model and
    /// stays off the view tree, and what is on screen is a `SettingsToggle`
    /// wearing the checkbox's title as an accessibility label.
    func toggle(saying fragment: String, in controller: NSViewController? = nil) -> SettingsToggle? {
        let root = (controller ?? self.controller).view
        return Self.all(SettingsToggle.self, in: root).first {
            ($0.accessibilityLabel() ?? "").localizedCaseInsensitiveContains(fragment)
        }
    }

    /// A toolbar row's switch, which wears the button's name exactly.
    func toolbarToggle(_ name: String, in controller: NSViewController? = nil) -> SettingsToggle? {
        let root = (controller ?? self.controller).view
        return Self.all(SettingsToggle.self, in: root).first { $0.accessibilityLabel() == name }
    }

    func arrow(_ label: String, in controller: NSViewController? = nil) -> NSButton? {
        let root = (controller ?? self.controller).view
        return Self.all(NSButton.self, in: root).first { $0.accessibilityLabel() == label }
    }

    func button(titled title: String, in controller: NSViewController? = nil) -> NSButton? {
        let root = (controller ?? self.controller).view
        return Self.all(NSButton.self, in: root).first { $0.title == title }
    }

    var fontField: NSTextField? {
        Self.all(NSTextField.self, in: controller.view).first { $0.isEditable }
    }

    var fontStepper: NSStepper? {
        Self.all(NSStepper.self, in: controller.view).first
    }
}

/// Picks an option and tells the pane, exactly as a click on the menu does.
@MainActor
private func choose(_ popUp: NSPopUpButton?, _ index: Int) {
    guard let popUp, let action = popUp.action else {
        Issue.record("a pop-up on the Browsing pane has no action")
        return
    }
    popUp.selectItem(at: index)
    _ = popUp.target?.perform(action, with: popUp)
}

/// Flips a switch the way a click on it does.
@MainActor
private func click(_ toggle: SettingsToggle?, file: String = #file) {
    guard let toggle else {
        Issue.record("a switch is missing from the Browsing pane")
        return
    }
    #expect(toggle.accessibilityPerformPress(), "the switch refused the press")
}

/// The keys a settings object has actually written, minus the one-time
/// migration `Settings.init` performs whatever anyone clicks.
private func storedKeys(_ defaults: UserDefaults, _ suite: String) -> [String] {
    (defaults.persistentDomain(forName: suite) ?? [:]).keys
        .filter { $0 != "externalLinkPresentationMigrated" }
        .sorted()
}

/// Commits what is in the number field, as pressing Return does.
@MainActor
private func commit(_ field: NSTextField?, _ text: String) {
    guard let field, let action = field.action else {
        Issue.record("the minimum font size field has no action")
        return
    }
    field.stringValue = text
    _ = field.target?.perform(action, with: field)
}

// MARK: - The switches, as a table

/// One switch on the pane: how to find it, and what it is meant to write.
@MainActor
private struct SwitchCase {
    let label: String
    let read: (Settings) -> Bool
    let write: (Settings, Bool) -> Void
    /// Switches whose row is turned off by another switch, and so cannot be
    /// pressed until that one is on.
    let requires: (label: String, on: Bool)?

    init(_ label: String,
         requires: (label: String, on: Bool)? = nil,
         read: @escaping (Settings) -> Bool,
         write: @escaping (Settings, Bool) -> Void) {
        self.label = label
        self.requires = requires
        self.read = read
        self.write = write
    }
}

/// The same switches by name, where the test runner can read them: a
/// parameterised test's arguments are gathered before the main actor is
/// reached, so the table itself cannot be the argument list.
private enum SwitchLabels {
    static let all = [
        "Automatic HTTPS upgrade",
        "Show full website address",
        "Show Unicode Domains",
        "Open bookmarks in new tabs",
        "to open pinned sites",
        "Wrap around when switching spaces",
        "Show a tab bar above the page",
        "standard window buttons in Compact Mode",
        "Automatically Picture-in-Picture",
        "Confirm closing tabs when Picture in Picture",
        "Minimum font size",
        "Press Tab to highlight",
        "Prevent ESC",
        "Enable mouse gestures",
        "Enable rocker gestures",
        "Show gesture trails",
        "Enable link hints",
        "Enable Vim-style navigation",
        "Enable Web Panels",
        "Always on Top"
    ]
}

@MainActor
private enum Switches {
    static func named(_ label: String) -> SwitchCase {
        guard let entry = all.first(where: { $0.label == label }) else {
            fatalError("no switch called \(label)")
        }
        return entry
    }

    static let all: [SwitchCase] = [
        SwitchCase("Automatic HTTPS upgrade",
                   read: { $0.upgradesToHTTPS }, write: { $0.upgradesToHTTPS = $1 }),
        SwitchCase("Show full website address",
                   read: { $0.showsFullAddress }, write: { $0.showsFullAddress = $1 }),
        SwitchCase("Show Unicode Domains",
                   read: { $0.showsUnicodeDomains }, write: { $0.showsUnicodeDomains = $1 }),
        SwitchCase("Open bookmarks in new tabs",
                   read: { $0.opensBookmarksInNewTabs }, write: { $0.opensBookmarksInNewTabs = $1 }),
        SwitchCase("to open pinned sites",
                   read: { $0.favouriteShortcutsEnabled }, write: { $0.favouriteShortcutsEnabled = $1 }),
        SwitchCase("Wrap around when switching spaces",
                   read: { $0.spaceSwitchWraps }, write: { $0.spaceSwitchWraps = $1 }),
        SwitchCase("Show a tab bar above the page",
                   read: { $0.showsTabStrip }, write: { $0.showsTabStrip = $1 }),
        SwitchCase("standard window buttons in Compact Mode",
                   read: { $0.compactModeShowsWindowButtons }, write: { $0.compactModeShowsWindowButtons = $1 }),
        SwitchCase("Automatically Picture-in-Picture",
                   read: { $0.autoPictureInPicture }, write: { $0.autoPictureInPicture = $1 }),
        SwitchCase("Confirm closing tabs when Picture in Picture",
                   read: { $0.confirmsClosingPictureInPicture }, write: { $0.confirmsClosingPictureInPicture = $1 }),
        SwitchCase("Minimum font size",
                   read: { $0.minimumFontSizeEnabled }, write: { $0.minimumFontSizeEnabled = $1 }),
        SwitchCase("Press Tab to highlight",
                   read: { $0.tabFocusesLinks }, write: { $0.tabFocusesLinks = $1 }),
        SwitchCase("Prevent ESC",
                   read: { $0.preventsEscapeExitingFullScreen }, write: { $0.preventsEscapeExitingFullScreen = $1 }),
        SwitchCase("Enable mouse gestures",
                   read: { $0.mouseGesturesEnabled }, write: { $0.mouseGesturesEnabled = $1 }),
        SwitchCase("Enable rocker gestures", requires: ("Enable mouse gestures", true),
                   read: { $0.rockerGesturesEnabled }, write: { $0.rockerGesturesEnabled = $1 }),
        SwitchCase("Show gesture trails", requires: ("Enable mouse gestures", true),
                   read: { $0.gestureTrailsEnabled }, write: { $0.gestureTrailsEnabled = $1 }),
        SwitchCase("Enable link hints",
                   read: { $0.linkHintsEnabled }, write: { $0.linkHintsEnabled = $1 }),
        SwitchCase("Enable Vim-style navigation",
                   read: { $0.vimBindingsEnabled }, write: { $0.vimBindingsEnabled = $1 }),
        SwitchCase("Enable Web Panels",
                   read: { $0.webPanelEnabled }, write: { $0.webPanelEnabled = $1 }),
        SwitchCase("Always on Top", requires: ("Enable Web Panels", true),
                   read: { $0.webPanelAlwaysOnTop }, write: { $0.webPanelAlwaysOnTop = $1 })
    ]

    static var indices: [Int] { Array(all.indices) }
}

// MARK: - Wiring

@Suite("The Browsing pane's controls", .serialized)
@MainActor
struct BrowsingPaneWiringTests {
    @Test("The table of switches and the pane agree on how many there are")
    func theTableIsComplete() {
        #expect(Switches.all.map(\.label) == SwitchLabels.all)
    }

    @Test("Every switch the pane promises is on it, and does something",
          arguments: SwitchLabels.all)
    func everySwitchIsThere(label: String) {
        let pane = Pane()
        let entry = Switches.named(label)
        let toggle = pane.toggle(saying: entry.label)
        #expect(toggle != nil, "the \(entry.label) switch is missing")
        #expect(toggle?.action != nil, "the \(entry.label) switch does nothing")
        #expect(toggle?.target != nil, "the \(entry.label) switch has no target")
    }

    @Test("Each pop-up offers exactly the choices its setting has")
    func everyChoiceIsOffered() {
        let pane = Pane()
        #expect(pane.popUp(offering: ExternalLinkPresentation.allCases.map(\.title)) != nil)
        #expect(pane.popUp(offering: SidebarDensity.allCases.map(\.title)) != nil)
        #expect(pane.popUp(offering: SidebarMode.allCases.map(\.title)) != nil)
        #expect(pane.popUp(offering: SidebarPosition.allCases.map(\.title)) != nil)
        #expect(pane.popUp(offering: SidebarHoverDelayPreset.allCases.map(\.title)) != nil)
    }

    @Test("Nothing on the pane is decorative")
    func nothingIsDecorative() {
        let pane = Pane()
        for popUp in Pane.all(NSPopUpButton.self, in: pane.controller.view) where popUp.isEnabled {
            #expect(popUp.action != nil, "a pop-up offering \(popUp.itemTitles) does nothing")
            #expect(popUp.target != nil, "a pop-up offering \(popUp.itemTitles) has no target")
        }
        for title in ["Restore Default Toolbar", "Reset Web Panels to Defaults", "Customize Context Menu\u{2026}"] {
            let button = pane.button(titled: title)
            #expect(button != nil, "the \(title) button is missing")
            #expect(button?.action != nil, "the \(title) button does nothing")
            #expect(button?.target != nil, "the \(title) button has no target")
        }
        #expect(pane.fontField?.action != nil)
        #expect(pane.fontStepper?.action != nil)
    }

    @Test("The font stepper cannot leave the range the setting allows")
    func stepperRange() {
        let pane = Pane()
        #expect(pane.fontStepper?.minValue == 1)
        #expect(pane.fontStepper?.maxValue == 72)
        #expect(pane.fontStepper?.increment == 1)
    }

    @Test("The font field takes whole numbers only")
    func fontFieldIsANumberField() {
        let pane = Pane()
        let formatter = pane.fontField?.formatter as? NumberFormatter
        #expect(formatter != nil, "a plain field keeps showing text that is not the setting")
        #expect(formatter?.allowsFloats == false)
    }

    @Test("The toolbar list has a row for every button Kylmora can show")
    func toolbarRows() {
        let pane = Pane()
        for entry in ToolbarLayout.catalog {
            #expect(pane.toolbarToggle(entry.label) != nil, "\(entry.label) has no row")
            #expect(pane.arrow("Move \(entry.label) up") != nil)
            #expect(pane.arrow("Move \(entry.label) down") != nil)
        }
    }
}

// MARK: - What each control stores

@Suite("What the Browsing pane stores", .serialized)
@MainActor
struct BrowsingPaneStorageTests {
    @Test("Every switch stores both answers and reads them back",
          arguments: SwitchLabels.all)
    func everySwitchRoundTrips(label: String) {
        let pane = Pane()
        let entry = Switches.named(label)
        if let requirement = entry.requires {
            // Its row is dead until the switch it depends on is on.
            if pane.toggle(saying: requirement.label)?.isOn != requirement.on {
                click(pane.toggle(saying: requirement.label))
            }
        }
        let before = entry.read(pane.settings)

        click(pane.toggle(saying: entry.label))
        #expect(entry.read(pane.settings) == !before, "\(entry.label) did not store the flip")
        #expect(pane.toggle(saying: entry.label, in: pane.reopened())?.isOn == !before,
                "\(entry.label) came back wrong when the pane was built again")

        click(pane.toggle(saying: entry.label))
        #expect(entry.read(pane.settings) == before, "\(entry.label) did not store the flip back")
        #expect(pane.toggle(saying: entry.label, in: pane.reopened())?.isOn == before,
                "\(entry.label) came back wrong when the pane was built again")
    }

    @Test("A switch writes its own setting and nobody else's",
          arguments: SwitchLabels.all)
    func switchesKeepToThemselves(label: String) {
        let pane = Pane()
        let entry = Switches.named(label)
        if let requirement = entry.requires,
           pane.toggle(saying: requirement.label)?.isOn != requirement.on {
            click(pane.toggle(saying: requirement.label))
        }
        let others = Switches.all.filter { $0.label != entry.label }
        // What the pane depends on is allowed to move with the switch that
        // owns it; everything else must be exactly where it was.
        let dependents = Set(Switches.all.compactMap { $0.requires?.label == entry.label ? $0.label : nil })
        let before = others.map { ($0.label, $0.read(pane.settings)) }

        click(pane.toggle(saying: entry.label))

        for (label, value) in before where !dependents.contains(label) {
            #expect(Switches.all.first { $0.label == label }?.read(pane.settings) == value,
                    "flipping \(entry.label) also changed \(label)")
        }
    }

    @Test("Links from other apps: every presentation",
          arguments: Array(ExternalLinkPresentation.allCases.enumerated()))
    func externalLinks(index: Int, presentation: ExternalLinkPresentation) {
        let pane = Pane()
        let titles = ExternalLinkPresentation.allCases.map(\.title)
        choose(pane.popUp(offering: titles), index)
        #expect(pane.settings.externalLinkPresentation == presentation)
        #expect(pane.popUp(offering: titles, in: pane.reopened())?.titleOfSelectedItem == presentation.title)
    }

    @Test("Sidebar density: every density",
          arguments: Array(SidebarDensity.allCases.enumerated()))
    func density(index: Int, density: SidebarDensity) {
        let pane = Pane()
        let titles = SidebarDensity.allCases.map(\.title)
        choose(pane.popUp(offering: titles), index)
        #expect(pane.settings.sidebarDensity == density)
        #expect(pane.popUp(offering: titles, in: pane.reopened())?.titleOfSelectedItem == density.title)
    }

    @Test("Sidebar display: every mode",
          arguments: Array(SidebarMode.allCases.enumerated()))
    func sidebarMode(index: Int, mode: SidebarMode) {
        let pane = Pane()
        let titles = SidebarMode.allCases.map(\.title)
        choose(pane.popUp(offering: titles), index)
        #expect(pane.settings.sidebarMode == mode)
        #expect(pane.popUp(offering: titles, in: pane.reopened())?.titleOfSelectedItem == mode.title)
    }

    @Test("Sidebar position: both edges",
          arguments: Array(SidebarPosition.allCases.enumerated()))
    func sidebarPosition(index: Int, position: SidebarPosition) {
        let pane = Pane()
        let titles = SidebarPosition.allCases.map(\.title)
        choose(pane.popUp(offering: titles), index)
        #expect(pane.settings.sidebarPosition == position)
        #expect(pane.popUp(offering: titles, in: pane.reopened())?.titleOfSelectedItem == position.title)
    }

    @Test("Hover reveal delay: every preset",
          arguments: Array(SidebarHoverDelayPreset.allCases.enumerated()))
    func hoverDelay(index: Int, preset: SidebarHoverDelayPreset) {
        let pane = Pane()
        let titles = SidebarHoverDelayPreset.allCases.map(\.title)
        choose(pane.popUp(offering: titles), index)
        #expect(pane.settings.sidebarHoverDelay == preset.rawValue)
        #expect(pane.popUp(offering: titles, in: pane.reopened())?.titleOfSelectedItem == preset.title)
    }

    @Test("A pop-up with nothing chosen writes nothing rather than going out of range")
    func popUpWithNoSelection() {
        let pane = Pane()
        let density = pane.settings.sidebarDensity
        let mode = pane.settings.sidebarMode
        let position = pane.settings.sidebarPosition
        let delay = pane.settings.sidebarHoverDelay
        let presentation = pane.settings.externalLinkPresentation
        for titles in [SidebarDensity.allCases.map(\.title), SidebarMode.allCases.map(\.title),
                       SidebarPosition.allCases.map(\.title), SidebarHoverDelayPreset.allCases.map(\.title),
                       ExternalLinkPresentation.allCases.map(\.title)] {
            choose(pane.popUp(offering: titles), -1)
        }
        #expect(pane.settings.sidebarDensity == density)
        #expect(pane.settings.sidebarMode == mode)
        #expect(pane.settings.sidebarPosition == position)
        #expect(pane.settings.sidebarHoverDelay == delay)
        #expect(pane.settings.externalLinkPresentation == presentation)
    }

    @Test("The default hover delay is one the pop-up can say")
    func theDefaultDelayIsAPreset() {
        let pane = Pane()
        let delay = pane.settings.sidebarHoverDelay
        #expect(SidebarHoverDelayPreset.preset(for: delay).rawValue == delay,
                "the pop-up shows \(SidebarHoverDelayPreset.preset(for: delay).title) for a delay of \(delay)s")
    }

    @Test("Opening the pane changes nothing by itself")
    func openingThePaneIsNotAnEdit() {
        let suite = "kylmora.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = Settings(defaults: defaults)
        let controller = BrowsingSettingsViewController(settings: settings, session: nil)
        controller.view.layoutSubtreeIfNeeded()
        controller.viewWillAppear()
        // The persistent domain is what outlives the app. Nothing was touched,
        // so it must still be empty: the pane used to write every setting on
        // it, including a hover delay of 250 ms over a default of 200 ms that
        // no pop-up could say.
        let stored = storedKeys(defaults, suite)
        #expect(stored.isEmpty, "showing the pane stored \(stored)")
    }

    @Test("One click writes one setting")
    func oneClickWritesOneSetting() {
        let suite = "kylmora.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = Settings(defaults: defaults)
        let controller = BrowsingSettingsViewController(settings: settings, session: nil)
        controller.confirmsWebPanelReset = { false }
        controller.view.layoutSubtreeIfNeeded()
        let toggle = Pane.all(SettingsToggle.self, in: controller.view).first {
            ($0.accessibilityLabel() ?? "").localizedCaseInsensitiveContains("Automatic HTTPS upgrade")
        }
        #expect(toggle?.accessibilityPerformPress() == true)
        #expect(storedKeys(defaults, suite) == ["upgradesKnownHostsToHTTPS"],
                "one switch wrote \(storedKeys(defaults, suite))")
    }
}

// MARK: - Settings that change while the pane is open

@Suite("The Browsing pane and the rest of the app", .serialized)
@MainActor
struct BrowsingPaneRefreshTests {
    @Test("A setting changed elsewhere survives a click on an unrelated switch",
          arguments: SwitchLabels.all)
    func thePaneDoesNotPutBackWhatItRemembered(label: String) {
        let pane = Pane()
        let entry = Switches.named(label)
        // Mouse gestures and Vim bindings have commands of their own; this
        // stands in for any of them.
        let outside = Switches.all.first { $0.label == "Enable mouse gestures" }!
        guard entry.label != outside.label, entry.requires?.label != outside.label else { return }
        outside.write(pane.settings, !outside.read(pane.settings))
        let expected = outside.read(pane.settings)

        if let requirement = entry.requires,
           pane.toggle(saying: requirement.label)?.isOn != requirement.on {
            click(pane.toggle(saying: requirement.label))
        }
        click(pane.toggle(saying: entry.label))

        #expect(outside.read(pane.settings) == expected,
                "flipping \(entry.label) put mouse gestures back the way the pane remembered them")
    }

    @Test("Showing the pane again reads the settings again")
    func viewWillAppearReloads() {
        let pane = Pane()
        for entry in Switches.all {
            entry.write(pane.settings, !entry.read(pane.settings))
        }
        pane.controller.viewWillAppear()
        for entry in Switches.all {
            #expect(pane.toggle(saying: entry.label)?.isOn == entry.read(pane.settings),
                    "\(entry.label) still shows what it showed before")
        }
    }

    @Test("Showing the pane again reads the pop-ups again")
    func viewWillAppearReloadsPopUps() {
        let pane = Pane()
        pane.settings.sidebarDensity = .roomy
        pane.settings.sidebarMode = .compact
        pane.settings.sidebarPosition = .trailing
        pane.settings.sidebarHoverDelay = SidebarHoverDelayPreset.deliberate.rawValue
        pane.settings.externalLinkPresentation = .glance
        pane.controller.viewWillAppear()
        #expect(pane.popUp(offering: SidebarDensity.allCases.map(\.title))?.titleOfSelectedItem == SidebarDensity.roomy.title)
        #expect(pane.popUp(offering: SidebarMode.allCases.map(\.title))?.titleOfSelectedItem == SidebarMode.compact.title)
        #expect(pane.popUp(offering: SidebarPosition.allCases.map(\.title))?.titleOfSelectedItem == SidebarPosition.trailing.title)
        #expect(pane.popUp(offering: SidebarHoverDelayPreset.allCases.map(\.title))?.titleOfSelectedItem == SidebarHoverDelayPreset.deliberate.title)
        #expect(pane.popUp(offering: ExternalLinkPresentation.allCases.map(\.title))?.titleOfSelectedItem == ExternalLinkPresentation.glance.title)
    }

    @Test("Showing the pane again rebuilds the toolbar list")
    func viewWillAppearReloadsTheToolbar() {
        let pane = Pane()
        var layout = ToolbarLayout()
        layout.setHidden("Share", true)
        layout.move("Extensions", to: 0)
        pane.settings.toolbarLayout = layout
        pane.controller.viewWillAppear()
        #expect(pane.toolbarToggle("Share")?.isOn == false)
        #expect(pane.arrow("Move Extensions up")?.isEnabled == false, "Extensions is first now")
    }
}

// MARK: - Switches that turn other switches off

@Suite("The Browsing pane's dependent controls", .serialized)
@MainActor
struct BrowsingPaneDependencyTests {
    @Test("Rocker gestures and trails are dead while mouse gestures are off")
    func gestureDependency() {
        let pane = Pane()
        if pane.toggle(saying: "Enable mouse gestures")?.isOn == false {
            click(pane.toggle(saying: "Enable mouse gestures"))
        }
        #expect(pane.toggle(saying: "Enable rocker gestures")?.isEnabled == true)
        #expect(pane.toggle(saying: "Show gesture trails")?.isEnabled == true)

        let rocker = pane.settings.rockerGesturesEnabled
        let trails = pane.settings.gestureTrailsEnabled
        click(pane.toggle(saying: "Enable mouse gestures"))
        #expect(pane.toggle(saying: "Enable rocker gestures")?.isEnabled == false)
        #expect(pane.toggle(saying: "Show gesture trails")?.isEnabled == false)
        // Off, not forgotten: turning gestures back on brings them back.
        #expect(pane.settings.rockerGesturesEnabled == rocker)
        #expect(pane.settings.gestureTrailsEnabled == trails)

        click(pane.toggle(saying: "Enable mouse gestures"))
        #expect(pane.toggle(saying: "Enable rocker gestures")?.isEnabled == true)
        #expect(pane.settings.rockerGesturesEnabled == rocker)
    }

    @Test("A dead switch cannot be pressed")
    func deadSwitchesRefuse() {
        let pane = Pane()
        if pane.toggle(saying: "Enable mouse gestures")?.isOn == true {
            click(pane.toggle(saying: "Enable mouse gestures"))
        }
        let rocker = pane.settings.rockerGesturesEnabled
        #expect(pane.toggle(saying: "Enable rocker gestures")?.accessibilityPerformPress() == false)
        #expect(pane.settings.rockerGesturesEnabled == rocker)
    }

    @Test("Always on Top and the reset are dead while Web Panels are off")
    func webPanelDependency() {
        let pane = Pane()
        if pane.toggle(saying: "Enable Web Panels")?.isOn == false {
            click(pane.toggle(saying: "Enable Web Panels"))
        }
        #expect(pane.toggle(saying: "Always on Top")?.isEnabled == true)
        #expect(pane.button(titled: "Reset Web Panels to Defaults")?.isEnabled == true)

        click(pane.toggle(saying: "Enable Web Panels"))
        #expect(pane.toggle(saying: "Always on Top")?.isEnabled == false)
        #expect(pane.button(titled: "Reset Web Panels to Defaults")?.isEnabled == false,
                "a button that resets panels the browser is not using")
    }

    @Test("The font field and stepper are dead while the minimum is off")
    func fontDependency() {
        let pane = Pane()
        if pane.toggle(saying: "Minimum font size")?.isOn == true {
            click(pane.toggle(saying: "Minimum font size"))
        }
        #expect(pane.fontField?.isEnabled == false)
        #expect(pane.fontStepper?.isEnabled == false)
        click(pane.toggle(saying: "Minimum font size"))
        #expect(pane.fontField?.isEnabled == true)
        #expect(pane.fontStepper?.isEnabled == true)
    }

    @Test("A pane built with a dependency already off shows it off")
    func dependenciesSurviveAReopen() {
        let pane = Pane()
        pane.settings.mouseGesturesEnabled = false
        pane.settings.webPanelEnabled = false
        pane.settings.minimumFontSizeEnabled = false
        let fresh = pane.reopened()
        #expect(pane.toggle(saying: "Enable rocker gestures", in: fresh)?.isEnabled == false)
        #expect(pane.toggle(saying: "Always on Top", in: fresh)?.isEnabled == false)
        #expect(pane.button(titled: "Reset Web Panels to Defaults", in: fresh)?.isEnabled == false)
    }
}

// MARK: - The minimum font size

@Suite("The Browsing pane's minimum font size", .serialized)
@MainActor
struct BrowsingPaneFontSizeTests {
    private func enabledPane() -> Pane {
        let pane = Pane()
        if pane.toggle(saying: "Minimum font size")?.isOn == false {
            click(pane.toggle(saying: "Minimum font size"))
        }
        return pane
    }

    @Test("Typed sizes are stored, clamped, and shown back clamped",
          arguments: [("12", 12), ("1", 1), ("72", 72), ("0", 1), ("-5", 1), ("999", 72), ("73", 72)])
    func typedSizes(text: String, stored: Int) {
        let pane = enabledPane()
        commit(pane.fontField, text)
        #expect(pane.settings.minimumFontSize == stored, "typing \(text) stored the wrong size")
        #expect(pane.fontField?.integerValue == stored, "the field shows what was not stored")
        #expect(pane.fontStepper?.integerValue == stored, "the stepper and the field disagree")
    }

    @Test("Text that is not a number puts the setting back")
    func textIsRefused() {
        let pane = enabledPane()
        commit(pane.fontField, "14")
        guard let field = pane.fontField else {
            Issue.record("the minimum font size field is missing")
            return
        }
        field.stringValue = "mouse"
        _ = pane.controller.control(field, didFailToFormatString: "mouse", errorDescription: nil)
        #expect(field.integerValue == 14, "the field kept saying something the browser is not doing")
        #expect(pane.settings.minimumFontSize == 14)
    }

    @Test("Leaving the field commits it, as Return does")
    func endingEditingCommits() {
        let pane = enabledPane()
        guard let field = pane.fontField else {
            Issue.record("the minimum font size field is missing")
            return
        }
        field.integerValue = 21
        pane.controller.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        #expect(pane.settings.minimumFontSize == 21)
    }

    @Test("The stepper walks the size up and down")
    func stepping() {
        let pane = enabledPane()
        commit(pane.fontField, "10")
        guard let stepper = pane.fontStepper, let action = stepper.action else {
            Issue.record("the minimum font size stepper is missing")
            return
        }
        stepper.integerValue = 11
        _ = stepper.target?.perform(action, with: stepper)
        #expect(pane.settings.minimumFontSize == 11)
        #expect(pane.fontField?.integerValue == 11)

        stepper.integerValue = 10
        _ = stepper.target?.perform(action, with: stepper)
        #expect(pane.settings.minimumFontSize == 10)
        #expect(pane.fontField?.integerValue == 10)
    }

    @Test("A size survives the pane being built again")
    func sizeRoundTrips() {
        let pane = enabledPane()
        commit(pane.fontField, "18")
        let fresh = pane.reopened()
        let field = Pane.all(NSTextField.self, in: fresh.view).first { $0.isEditable }
        #expect(field?.integerValue == 18)
    }

    @Test("Turning the minimum off keeps the size for when it comes back")
    func sizeIsRemembered() {
        let pane = enabledPane()
        commit(pane.fontField, "16")
        click(pane.toggle(saying: "Minimum font size"))
        #expect(pane.settings.minimumFontSize == 16)
        click(pane.toggle(saying: "Minimum font size"))
        #expect(pane.fontField?.integerValue == 16)
    }
}

// MARK: - The toolbar list

@Suite("The Browsing pane's toolbar list", .serialized)
@MainActor
struct BrowsingPaneToolbarTests {
    @Test("Every button can be taken off the bar and put back",
          arguments: ToolbarLayout.catalog.map(\.label))
    func hidingRoundTrips(name: String) {
        let pane = Pane()
        #expect(pane.toolbarToggle(name)?.isOn == true, "\(name) starts on the bar")
        click(pane.toolbarToggle(name))
        #expect(pane.settings.toolbarLayout.hidden.contains(name))
        #expect(pane.toolbarToggle(name, in: pane.reopened())?.isOn == false)

        click(pane.toolbarToggle(name))
        #expect(pane.settings.toolbarLayout.hidden.contains(name) == false)
        #expect(pane.toolbarToggle(name, in: pane.reopened())?.isOn == true)
    }

    @Test("Hiding a button changes nothing else")
    func hidingIsNotReordering() {
        let pane = Pane()
        let order = pane.settings.toolbarLayout.fullOrder()
        click(pane.toolbarToggle("Share"))
        #expect(pane.settings.toolbarLayout.fullOrder() == order)
    }

    @Test("Every button can be walked to the top and back down",
          arguments: Array(ToolbarLayout.catalog.map(\.label).enumerated()))
    func walkingAButton(index: Int, name: String) {
        let pane = Pane()
        for _ in 0..<index {
            pane.arrow("Move \(name) up")?.performClick(nil)
        }
        #expect(pane.settings.toolbarLayout.fullOrder().first == name)
        #expect(pane.arrow("Move \(name) up")?.isEnabled == false, "nothing is above the first row")

        let last = ToolbarLayout.catalog.count - 1
        for _ in 0..<last {
            pane.arrow("Move \(name) down")?.performClick(nil)
        }
        #expect(pane.settings.toolbarLayout.fullOrder().last == name)
        #expect(pane.arrow("Move \(name) down")?.isEnabled == false, "nothing is below the last row")
    }

    @Test("The arrows at the ends of the list do nothing")
    func arrowsAtTheEnds() {
        let pane = Pane()
        let names = ToolbarLayout.catalog.map(\.label)
        let order = pane.settings.toolbarLayout.fullOrder()
        pane.arrow("Move \(names[0]) up")?.performClick(nil)
        pane.arrow("Move \(names[names.count - 1]) down")?.performClick(nil)
        #expect(pane.settings.toolbarLayout.fullOrder() == order)
    }

    @Test("A drag drops a button where the drag showed it would go")
    func draggingTakesOutAndPutsBack() {
        var layout = ToolbarLayout()
        let names = layout.fullOrder()
        layout.move(names[0], to: 3)
        #expect(layout.fullOrder() == [names[1], names[2], names[3], names[0]] + names[4...],
                "a drag that swaps is not the drag the list showed")
    }

    @Test("A move outside the list is not a move")
    func movesAreClamped() {
        var layout = ToolbarLayout()
        let order = layout.fullOrder()
        layout.move(order[0], by: -1)
        layout.move(order[order.count - 1], by: 1)
        layout.move("Not a button", by: 1)
        #expect(layout.fullOrder() == order)
    }

    @Test("A hidden button keeps its place in the order")
    func hiddenButtonsKeepTheirPlace() {
        let pane = Pane()
        let names = ToolbarLayout.catalog.map(\.label)
        click(pane.toolbarToggle(names[0]))
        pane.arrow("Move \(names[0]) down")?.performClick(nil)
        #expect(pane.settings.toolbarLayout.fullOrder()[1] == names[0])
        #expect(pane.settings.toolbarLayout.hidden.contains(names[0]), "moving it put it back on the bar")
    }

    @Test("Every button can be taken off at once, and the bar still stands")
    func hidingEverything() {
        let pane = Pane()
        for entry in ToolbarLayout.catalog {
            click(pane.toolbarToggle(entry.label))
        }
        #expect(pane.settings.toolbarLayout.hidden.count == ToolbarLayout.catalog.count)
        #expect(pane.settings.toolbarLayout.arrange(ToolbarLayout.catalog.map(\.label), label: { $0 }).isEmpty)
        let fresh = pane.reopened()
        for entry in ToolbarLayout.catalog {
            #expect(pane.toolbarToggle(entry.label, in: fresh)?.isOn == false)
        }
    }

    @Test("Restore Default Toolbar puts back the order and the hidden ones")
    func restoringDefaults() {
        let pane = Pane()
        let names = ToolbarLayout.catalog.map(\.label)
        click(pane.toolbarToggle(names[2]))
        for _ in 0..<4 { pane.arrow("Move \(names[9]) up")?.performClick(nil) }
        #expect(pane.settings.toolbarLayout.isDefault == false)

        pane.button(titled: "Restore Default Toolbar")?.performClick(nil)
        #expect(pane.settings.toolbarLayout.isDefault)
        #expect(pane.settings.toolbarLayout.fullOrder() == names)
        for name in names {
            #expect(pane.toolbarToggle(name)?.isOn == true, "\(name) is still off the bar")
        }
    }

    @Test("Restoring an already default toolbar is not a change")
    func restoringTwice() {
        let pane = Pane()
        pane.button(titled: "Restore Default Toolbar")?.performClick(nil)
        pane.button(titled: "Restore Default Toolbar")?.performClick(nil)
        #expect(pane.settings.toolbarLayout.isDefault)
    }

    @Test("A button added to the catalogue later lands in its default place")
    func newButtonsAppear() {
        var layout = ToolbarLayout()
        layout.order = ["Extensions", "Share"]
        let order = layout.fullOrder()
        #expect(order.prefix(2) == ["Extensions", "Share"])
        #expect(Set(order) == Set(ToolbarLayout.catalog.map(\.label)), "a button went missing")
    }
}

// MARK: - The buttons that do something outside the pane

@Suite("The Browsing pane's buttons", .serialized)
@MainActor
struct BrowsingPaneButtonTests {
    @Test("Resetting Web Panels asks first, and does nothing when the answer is no")
    func resetAsksFirst() {
        let pane = Pane()
        var asked = 0
        pane.controller.confirmsWebPanelReset = {
            asked += 1
            return false
        }
        let before = WebPanelStore.shared.panels
        pane.button(titled: "Reset Web Panels to Defaults")?.performClick(nil)
        #expect(asked == 1, "one click threw away every panel the user had added")
        #expect(WebPanelStore.shared.panels == before)
    }

    @Test("Customize Context Menu is a sheet, not a window of its own")
    func contextMenuOpensASheet() {
        let pane = Pane()
        let button = pane.button(titled: "Customize Context Menu\u{2026}")
        #expect(button?.target === pane.controller)
        #expect(button?.action != nil)
    }
}
