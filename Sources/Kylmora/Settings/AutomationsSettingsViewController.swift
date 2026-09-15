import AppKit
import UniformTypeIdentifiers

/// The Automations pane: Space routing (which addresses open in which
/// Space) and the rules that act on tabs when something happens.
@MainActor
final class AutomationsSettingsViewController: NSViewController {
    private let session: BrowserSession
    private let automations: AutomationService

    private let routesStack = NSStackView()
    private let externalPopUp = NSPopUpButton()
    private let rulesStack = NSStackView()
    private let emptyRulesLabel = NSTextField(wrappingLabelWithString: "No rules yet. A rule waits for something to happen and then acts on the tab: when a page loads, when a tab sits idle, when media starts, or when a download finishes.")

    /// The routes as edited, committed on every change.
    private var routes: [SpaceRoute] = []

    init(session: BrowserSession, automations: AutomationService = .shared) {
        self.session = session
        self.automations = automations
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("AutomationsSettingsViewController is created in code only")
    }

    override func loadView() {
        let form = SettingsForm()
        view = form
        buildLayout(in: form)
        reload()
    }

    private func buildLayout(in form: SettingsForm) {
        form.addSection("Space routing")
        routesStack.orientation = .vertical
        routesStack.alignment = .leading
        routesStack.spacing = 8
        form.addRow("", routesStack)
        let addRoute = NSButton(title: "Add Route", target: self, action: #selector(addRoute))
        addRoute.bezelStyle = .rounded
        form.addContinuation(addRoute)

        externalPopUp.target = self
        externalPopUp.action = #selector(externalDefaultChanged)
        form.addRow("Links from other apps open in", SettingsForm.fill(externalPopUp))
        form.addNote("Each address is checked against the routes in order; the first match wins. A link that matches none opens where you are, or, from another app, in the Space chosen above.")

        form.addSection("Rules")
        rulesStack.orientation = .vertical
        rulesStack.alignment = .leading
        rulesStack.spacing = 10
        form.addRow("", rulesStack)
        let addRule = NSButton(title: "Add Rule\u{2026}", target: self, action: #selector(addRule))
        addRule.bezelStyle = .rounded
        let exportButton = NSButton(title: "Export\u{2026}", target: self, action: #selector(exportRules))
        exportButton.bezelStyle = .rounded
        let importButton = NSButton(title: "Import\u{2026}", target: self, action: #selector(importRules))
        importButton.bezelStyle = .rounded
        let buttons = NSStackView(views: [addRule, exportButton, importButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        form.addContinuation(buttons)
        form.addNote("Actions in a rule run in order. Text actions may use {{url}}, {{title}} and, for downloads, {{file}}. A rule whose trigger is “Run from the command palette” is a custom command: it appears in the palette (⌘K) under its name and runs on the current tab. Rules are stored in automations.json in Kylmora's Application Support folder, so they can be shared or pushed to other Macs.")
    }

    // MARK: - State

    func reload() {
        routes = session.routing.rules.routes
        rebuildRoutes()
        rebuildExternalDefault()
        rebuildRules()
    }

    private var spaceChoices: [(title: String, destination: SpaceRouteDestination)] {
        [("Where you are", .mostRecentSpace)] + session.spaces.map { ($0.name, .space($0.id)) }
    }

    private func rebuildRoutes() {
        routesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if routes.isEmpty {
            let label = NSTextField(labelWithString: "No routes: every link opens where you are.")
            label.font = Style.Fonts.settingsNote
            label.textColor = Style.Colors.secondaryText
            routesStack.addArrangedSubview(label)
            return
        }
        for (index, route) in routes.enumerated() {
            routesStack.addArrangedSubview(routeRow(route, at: index))
        }
    }

    private func routeRow(_ route: SpaceRoute, at index: Int) -> NSView {
        let pattern = NSTextField(string: route.reference)
        pattern.placeholderString = "example.com"
        pattern.tag = index
        pattern.target = self
        pattern.action = #selector(routePatternChanged(_:))
        pattern.delegate = self

        let match = NSPopUpButton()
        match.addItems(withTitles: SpaceRouteMatch.allCases.map(Self.title(for:)))
        match.selectItem(at: SpaceRouteMatch.allCases.firstIndex(of: route.match) ?? 0)
        match.tag = index
        match.target = self
        match.action = #selector(routeMatchChanged(_:))

        let arrow = NSTextField(labelWithString: "→")
        arrow.textColor = Style.Colors.secondaryText

        let space = NSPopUpButton()
        space.addItems(withTitles: spaceChoices.map(\.title))
        space.selectItem(at: spaceChoices.firstIndex(where: { $0.destination == route.destination }) ?? 0)
        space.tag = index
        space.target = self
        space.action = #selector(routeSpaceChanged(_:))

        let remove = NSButton(image: NSImage(systemSymbolName: "minus.circle", accessibilityDescription: "Remove route")!, target: self, action: #selector(removeRoute(_:)))
        remove.isBordered = false
        remove.tag = index

        // Dressed like every other pop-up in the window: no bezel, on a plate.
        let row = NSStackView(views: [
            SettingsControlPlate(pattern, width: 200),
            SettingsControlPlate(match, width: 140),
            arrow,
            SettingsControlPlate(space, width: 160),
            remove
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    static func title(for match: SpaceRouteMatch) -> String {
        switch match {
        case .contains: return "contains"
        case .equalTo: return "is exactly"
        case .regex: return "matches regex"
        }
    }

    private func rebuildExternalDefault() {
        externalPopUp.removeAllItems()
        externalPopUp.addItems(withTitles: spaceChoices.map(\.title))
        let current = session.routing.rules.externalDefault
        externalPopUp.selectItem(at: spaceChoices.firstIndex(where: { $0.destination == current }) ?? 0)
    }

    private func commitRoutes() {
        session.routing.replace(with: SpaceRoutingRules(routes: routes, externalDefault: session.routing.rules.externalDefault))
    }

    private func rebuildRules() {
        rulesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let rules = automations.rules.rules
        if rules.isEmpty {
            emptyRulesLabel.font = Style.Fonts.settingsNote
            emptyRulesLabel.textColor = Style.Colors.secondaryText
            emptyRulesLabel.preferredMaxLayoutWidth = 480
            rulesStack.addArrangedSubview(emptyRulesLabel)
            return
        }
        for rule in rules {
            rulesStack.addArrangedSubview(ruleRow(rule))
        }
    }

    /// The count of rule rows shown, for tests.
    var shownRuleCount: Int { automations.rules.rules.isEmpty ? 0 : rulesStack.arrangedSubviews.count }
    var shownRouteCount: Int { routes.count }

    private func ruleRow(_ rule: AutomationRule) -> NSView {
        let enabled = NSButton(checkboxWithTitle: "", target: self, action: #selector(ruleEnabledChanged(_:)))
        enabled.state = rule.isEnabled ? .on : .off
        enabled.identifier = NSUserInterfaceItemIdentifier(rule.id.uuidString)

        let name = NSTextField(labelWithString: rule.name.isEmpty ? "Untitled rule" : rule.name)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        let summary = NSTextField(wrappingLabelWithString: Self.summary(of: rule, spaces: session.spaces))
        summary.font = Style.Fonts.settingsNote
        summary.textColor = Style.Colors.secondaryText
        summary.preferredMaxLayoutWidth = 380
        let text = NSStackView(views: [name, summary])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.setContentHuggingPriority(.init(1), for: .horizontal)

        let edit = NSButton(title: "Edit\u{2026}", target: self, action: #selector(editRule(_:)))
        edit.bezelStyle = .rounded
        edit.controlSize = .small
        edit.identifier = NSUserInterfaceItemIdentifier(rule.id.uuidString)
        let delete = NSButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete rule")!, target: self, action: #selector(deleteRule(_:)))
        delete.isBordered = false
        delete.identifier = NSUserInterfaceItemIdentifier(rule.id.uuidString)

        let row = NSStackView(views: [enabled, text, edit, delete])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 8
        row.widthAnchor.constraint(greaterThanOrEqualToConstant: 480).isActive = true
        return row
    }

    static func summary(of rule: AutomationRule, spaces: [Space]) -> String {
        let actions = rule.actions.map { action in
            action.summary(spaceName: { id in spaces.first { $0.id == id }?.name })
        }
        return rule.trigger.summary + ": " + actions.joined(separator: ", ")
    }

    // MARK: - Route actions

    @objc private func addRoute() {
        routes.append(SpaceRoute(reference: "", match: .contains, destination: .mostRecentSpace))
        rebuildRoutes()
        if let last = routesStack.arrangedSubviews.last as? NSStackView, let field = last.views.first {
            view.window?.makeFirstResponder(field)
        }
    }

    @objc private func removeRoute(_ sender: NSButton) {
        guard routes.indices.contains(sender.tag) else { return }
        routes.remove(at: sender.tag)
        commitRoutes()
        rebuildRoutes()
    }

    @objc private func routePatternChanged(_ sender: NSTextField) {
        guard routes.indices.contains(sender.tag) else { return }
        routes[sender.tag].reference = sender.stringValue
        commitRoutes()
    }

    @objc private func routeMatchChanged(_ sender: NSPopUpButton) {
        guard routes.indices.contains(sender.tag) else { return }
        routes[sender.tag].match = SpaceRouteMatch.allCases[sender.indexOfSelectedItem]
        commitRoutes()
    }

    @objc private func routeSpaceChanged(_ sender: NSPopUpButton) {
        guard routes.indices.contains(sender.tag) else { return }
        routes[sender.tag].destination = spaceChoices[sender.indexOfSelectedItem].destination
        commitRoutes()
    }

    @objc private func externalDefaultChanged() {
        let destination = spaceChoices[externalPopUp.indexOfSelectedItem].destination
        session.routing.replace(with: SpaceRoutingRules(routes: routes, externalDefault: destination))
    }

    // MARK: - Rule actions

    @objc private func addRule() {
        present(rule: nil)
    }

    @objc private func editRule(_ sender: NSButton) {
        guard let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }),
              let rule = automations.rules.rules.first(where: { $0.id == id }) else { return }
        present(rule: rule)
    }

    private func present(rule: AutomationRule?) {
        let editor = AutomationEditorViewController(rule: rule, spaces: session.spaces) { [weak self] saved in
            guard let self else { return }
            self.automations.update(saved)
            self.rebuildRules()
        }
        presentAsSheet(editor)
    }

    @objc private func deleteRule(_ sender: NSButton) {
        guard let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }) else { return }
        automations.remove(id: id)
        rebuildRules()
    }

    @objc private func ruleEnabledChanged(_ sender: NSButton) {
        guard let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }),
              var rule = automations.rules.rules.first(where: { $0.id == id }) else { return }
        rule.isEnabled = sender.state == .on
        automations.update(rule)
    }

    @objc private func exportRules() {
        guard let window = view.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Kylmora Automations.json"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let data = try? self?.automations.exportData() else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    @objc private func importRules() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
            try? self?.automations.importRules(from: data)
            self?.rebuildRules()
        }
    }
}

extension AutomationsSettingsViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, routes.indices.contains(field.tag) else { return }
        routes[field.tag].reference = field.stringValue
        commitRoutes()
    }
}

/// The sheet that edits one rule.
@MainActor
final class AutomationEditorViewController: NSViewController {
    private var rule: AutomationRule
    private let spaces: [Space]
    private let onSave: (AutomationRule) -> Void

    private let nameField = NSTextField()
    private let triggerPopUp = NSPopUpButton()
    private let patternField = NSTextField()
    private let matchPopUp = NSPopUpButton()
    private let minutesPopUp = NSPopUpButton()
    private let extensionField = NSTextField()
    private var patternRow: SettingsFormRow?
    private var matchRow: SettingsFormRow?
    private var minutesRow: SettingsFormRow?
    private var extensionRow: SettingsFormRow?

    private var actionChecks: [AutomationAction.Kind: NSButton] = [:]
    private var actionParameters: [AutomationAction.Kind: NSControl] = [:]
    private let shortcutButton = NSButton(title: "Record Shortcut", target: nil, action: nil)
    private let shortcutClear = NSButton(title: "Clear", target: nil, action: nil)
    private var shortcutRow: SettingsFormRow?
    private var shortcutMonitor: Any?

    static let idleChoices = [5, 15, 30, 60, 120, 240, 480]

    init(rule: AutomationRule?, spaces: [Space], onSave: @escaping (AutomationRule) -> Void) {
        self.rule = rule ?? AutomationRule(name: "", trigger: .pageLoaded(pattern: "", match: .contains), actions: [])
        self.spaces = spaces
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("AutomationEditorViewController is created in code only")
    }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        view = root

        let form = SettingsForm()
        form.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(form)

        form.addSection("Rule")
        nameField.placeholderString = "What this rule is for"
        nameField.stringValue = rule.name
        form.addRow("Name", SettingsForm.fill(nameField))

        form.addSection("When")
        triggerPopUp.addItems(withTitles: AutomationTrigger.Kind.allCases.map(\.title))
        triggerPopUp.selectItem(at: AutomationTrigger.Kind.allCases.firstIndex(of: rule.trigger.kind) ?? 0)
        triggerPopUp.target = self
        triggerPopUp.action = #selector(triggerChanged)
        form.addRow("Trigger", SettingsForm.fill(triggerPopUp))

        patternField.placeholderString = "Any address, or a pattern such as github.com"
        patternField.stringValue = rule.trigger.kind == .downloadFinished ? "" : rule.trigger.pattern
        patternRow = form.addRow("Address", SettingsForm.fill(patternField))
        matchPopUp.addItems(withTitles: SpaceRouteMatch.allCases.map(AutomationsSettingsViewController.title(for:)))
        matchPopUp.selectItem(at: SpaceRouteMatch.allCases.firstIndex(of: rule.trigger.match) ?? 0)
        matchRow = form.addRow("Compared as", SettingsForm.fill(matchPopUp))
        minutesPopUp.addItems(withTitles: Self.idleChoices.map { $0 < 60 ? "\($0) minutes" : "\($0 / 60) hour\($0 == 60 ? "" : "s")" })
        minutesPopUp.selectItem(at: Self.idleChoices.firstIndex(of: rule.trigger.idleMinutes ?? 30) ?? 2)
        minutesRow = form.addRow("Idle for", SettingsForm.fill(minutesPopUp))
        extensionField.placeholderString = "Any file, or an extension such as pdf"
        extensionField.stringValue = rule.trigger.kind == .downloadFinished ? rule.trigger.pattern : ""
        extensionRow = form.addRow("File type", SettingsForm.fill(extensionField))
        shortcutButton.bezelStyle = .rounded
        shortcutButton.target = self
        shortcutButton.action = #selector(recordShortcut)
        shortcutClear.bezelStyle = .rounded
        shortcutClear.target = self
        shortcutClear.action = #selector(clearShortcut)
        shortcutRow = form.addRow("Shortcut", [shortcutButton, shortcutClear])
        updateShortcutTitle()

        form.addSection("Then")
        for kind in AutomationAction.Kind.allCases {
            let check = NSButton(checkboxWithTitle: kind.title, target: self, action: #selector(actionToggled))
            let existing = rule.actions.first { $0.kind == kind }
            check.state = existing == nil ? .off : .on
            actionChecks[kind] = check
            if let parameter = parameterControl(for: kind, value: existing?.parameter ?? "") {
                actionParameters[kind] = parameter
                form.addRow("", [check, parameter])
            } else {
                form.addRow("", check)
            }
        }

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancel, save])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(buttons)

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 620),
            form.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            form.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            form.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            buttons.topAnchor.constraint(equalTo: form.bottomAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])
        updateTriggerRows()
        updateActionControls()
    }

    private func parameterControl(for kind: AutomationAction.Kind, value: String) -> NSControl? {
        switch kind {
        case .moveToSpace:
            let popUp = NSPopUpButton()
            popUp.addItems(withTitles: spaces.map(\.name))
            if let index = spaces.firstIndex(where: { $0.id.uuidString == value }) { popUp.selectItem(at: index) }
            return popUp
        case .setZoom:
            let popUp = NSPopUpButton()
            let options = SiteSettingCategory.pageZoom.options
            popUp.addItems(withTitles: options.map(\.title))
            popUp.selectItem(at: options.firstIndex(where: { $0.id == (value.isEmpty ? "1" : value) }) ?? 3)
            return popUp
        case .notify, .runShortcut, .runAppleScript, .openURL:
            let field = NSTextField(string: value)
            field.placeholderString = kind.parameterPrompt
            field.widthAnchor.constraint(equalToConstant: 300).isActive = true
            return field
        default:
            return nil
        }
    }

    private func updateTriggerRows() {
        let kind = AutomationTrigger.Kind.allCases[triggerPopUp.indexOfSelectedItem]
        patternRow?.isHidden = !kind.takesPattern
        matchRow?.isHidden = !kind.takesPattern
        shortcutRow?.isHidden = kind != .manual
        minutesRow?.isHidden = kind != .tabIdle
        extensionRow?.isHidden = kind != .downloadFinished
        for (actionKind, check) in actionChecks {
            let allowed = kind.concernsATab || actionKind.worksWithoutTab
            check.isEnabled = allowed
            if !allowed { check.state = .off }
        }
        updateActionControls()
    }

    private func updateActionControls() {
        for (kind, control) in actionParameters {
            control.isEnabled = actionChecks[kind]?.state == .on && actionChecks[kind]?.isEnabled == true
        }
    }

    private var shortcutID: String { AutomationService.commandPrefix + rule.id.uuidString }

    private func updateShortcutTitle() {
        let keys = ShortcutManager.shared.displayString(for: shortcutID)
        shortcutButton.title = keys.isEmpty ? "Record Shortcut" : keys
        shortcutClear.isEnabled = !keys.isEmpty
    }

    /// The next stroke becomes the command's shortcut; Escape leaves it.
    @objc private func recordShortcut() {
        stopRecordingShortcut()
        shortcutButton.title = "Press keys\u{2026}"
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let chars = event.charactersIgnoringModifiers ?? ""
            // A `Bool` crosses the isolation check; the event itself stays put.
            let swallow = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                if keyCode == 53 {
                    self.stopRecordingShortcut()
                    self.updateShortcutTitle()
                    return true
                }
                guard !chars.isEmpty, !flags.isEmpty else { return true }
                let key = chars.lowercased()
                if let taken = ShortcutManager.shared.findConflict(key: key, modifiers: flags) {
                    ShortcutManager.shared.clearShortcut(id: taken.id)
                }
                if let other = ShortcutManager.shared.conflictingCommand(key: key, modifiers: flags, excluding: self.shortcutID) {
                    ShortcutManager.shared.clearShortcut(id: other)
                }
                ShortcutManager.shared.setShortcut(id: self.shortcutID, key: key, modifiers: flags)
                self.stopRecordingShortcut()
                self.updateShortcutTitle()
                return true
            }
            return swallow ? nil : event
        }
    }

    @objc private func clearShortcut() {
        ShortcutManager.shared.resetShortcut(id: shortcutID)
        updateShortcutTitle()
    }

    private func stopRecordingShortcut() {
        if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor) }
        shortcutMonitor = nil
    }

    @objc private func triggerChanged() { updateTriggerRows() }
    @objc private func actionToggled() { updateActionControls() }

    /// The rule as the sheet currently describes it.
    func currentRule() -> AutomationRule {
        var edited = rule
        edited.name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let kind = AutomationTrigger.Kind.allCases[triggerPopUp.indexOfSelectedItem]
        let pattern = patternField.stringValue.trimmingCharacters(in: .whitespaces)
        let match = SpaceRouteMatch.allCases[matchPopUp.indexOfSelectedItem]
        switch kind {
        case .pageLoaded: edited.trigger = .pageLoaded(pattern: pattern, match: match)
        case .mediaStarted: edited.trigger = .mediaStarted(pattern: pattern, match: match)
        case .tabIdle: edited.trigger = .tabIdle(minutes: Self.idleChoices[minutesPopUp.indexOfSelectedItem], pattern: pattern, match: match)
        case .downloadFinished: edited.trigger = .downloadFinished(fileExtension: extensionField.stringValue.trimmingCharacters(in: CharacterSet(charactersIn: ". ")))
        case .manual: edited.trigger = .manual
        }
        edited.actions = AutomationAction.Kind.allCases.compactMap { actionKind in
            guard actionChecks[actionKind]?.state == .on, actionChecks[actionKind]?.isEnabled == true else { return nil }
            let parameter: String
            switch actionParameters[actionKind] {
            case let popUp as NSPopUpButton where actionKind == .moveToSpace:
                parameter = spaces.indices.contains(popUp.indexOfSelectedItem) ? spaces[popUp.indexOfSelectedItem].id.uuidString : ""
            case let popUp as NSPopUpButton where actionKind == .setZoom:
                parameter = SiteSettingCategory.pageZoom.options[popUp.indexOfSelectedItem].id
            case let field as NSTextField:
                parameter = field.stringValue
            default:
                parameter = ""
            }
            return AutomationAction.make(actionKind, parameter: parameter)
        }
        if edited.name.isEmpty { edited.name = edited.trigger.summary }
        return edited
    }

    @objc private func save() {
        let saved = currentRule()
        dismissSheet()
        onSave(saved)
    }

    @objc private func cancel() { dismissSheet() }

    private func dismissSheet() {
        if presentingViewController != nil {
            presentingViewController?.dismiss(self)
        } else if let window = view.window, let parent = window.sheetParent {
            parent.endSheet(window)
        }
    }
}
