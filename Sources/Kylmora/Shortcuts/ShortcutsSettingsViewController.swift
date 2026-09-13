import AppKit

/// Settings pane for browsing, recording, and customizing keyboard shortcuts.
@MainActor
final class ShortcutsSettingsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let manager: ShortcutManager

    private let searchField = NSSearchField()
    private let categoryControl = NSSegmentedControl(
        labels: ["All"] + ShortcutCategory.allCases.map(\.rawValue),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let restoreDefaultsButton = NSButton(title: "Restore All Defaults", target: nil, action: nil)
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    private var filteredDefinitions: [ShortcutDefinition] = []
    private var recordingDefinitionID: String?
    private var keyMonitor: Any?

    init(manager: ShortcutManager = .shared) {
        self.manager = manager
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("ShortcutsSettingsViewController is created in code only")
    }

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        self.view = container

        // Search & Filter header
        searchField.placeholderString = "Search shortcuts\u{2026}"
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.target = self
        searchField.action = #selector(filterChanged)
        container.addSubview(searchField)

        categoryControl.selectedSegment = 0
        categoryControl.translatesAutoresizingMaskIntoConstraints = false
        categoryControl.target = self
        categoryControl.action = #selector(filterChanged)
        container.addSubview(categoryControl)

        restoreDefaultsButton.bezelStyle = .rounded
        restoreDefaultsButton.translatesAutoresizingMaskIntoConstraints = false
        restoreDefaultsButton.target = self
        restoreDefaultsButton.action = #selector(restoreAllDefaultsClicked)
        container.addSubview(restoreDefaultsButton)

        // Table
        let colAction = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Action"))
        colAction.title = "Action"
        colAction.width = 460

        let colCategory = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Category"))
        colCategory.title = "Category"
        colCategory.width = 120

        let colShortcut = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Shortcut"))
        colShortcut.title = "Shortcut"
        colShortcut.width = 150

        let colReset = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Reset"))
        colReset.title = ""
        colReset.width = 60

        tableView.addTableColumn(colAction)
        tableView.addTableColumn(colCategory)
        tableView.addTableColumn(colShortcut)
        tableView.addTableColumn(colReset)
        tableView.headerView = NSTableHeaderView()
        tableView.rowHeight = 32
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: SettingsWindowController.windowWidth),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 440),

            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            searchField.widthAnchor.constraint(equalToConstant: 240),

            categoryControl.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            categoryControl.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 16),

            restoreDefaultsButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            restoreDefaultsButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 14),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
            scrollView.heightAnchor.constraint(equalToConstant: 380)
        ])

        manager.onChange = { [weak self] in
            self?.updateFilter()
        }

        updateFilter()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        stopRecording()
    }

    // MARK: - Filtering

    @objc private func filterChanged() {
        updateFilter()
    }

    private func updateFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let selectedCategoryIndex = categoryControl.selectedSegment

        filteredDefinitions = manager.definitions.filter { def in
            if selectedCategoryIndex > 0 {
                let cat = ShortcutCategory.allCases[selectedCategoryIndex - 1]
                if def.category != cat { return false }
            }

            if query.isEmpty { return true }
            let shortcutStr = manager.displayString(for: def.id).lowercased()
            return def.title.lowercased().contains(query) ||
                   def.category.rawValue.lowercased().contains(query) ||
                   shortcutStr.contains(query)
        }

        tableView.reloadData()
    }

    // MARK: - Table View Data Source & Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredDefinitions.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filteredDefinitions.count else { return nil }
        let def = filteredDefinitions[row]
        let identifier = tableColumn?.identifier.rawValue

        switch identifier {
        case "Action":
            let cell = NSTextField(labelWithString: def.title)
            cell.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            cell.textColor = .labelColor
            return cell

        case "Category":
            let cell = NSTextField(labelWithString: def.category.rawValue)
            cell.font = NSFont.systemFont(ofSize: 11)
            cell.textColor = .secondaryLabelColor
            return cell

        case "Shortcut":
            let isRecording = recordingDefinitionID == def.id
            let display = isRecording ? "Type shortcut\u{2026}" : manager.displayString(for: def.id)

            let button = NSButton(title: display.isEmpty ? "None" : display, target: self, action: #selector(shortcutButtonClicked(_:)))
            button.tag = row
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = NSFont.monospacedSystemFont(ofSize: 12, weight: isRecording ? .bold : .regular)
            if isRecording {
                button.contentTintColor = .systemBlue
            } else if manager.isCustomized(id: def.id) {
                button.contentTintColor = .systemOrange
            } else {
                button.contentTintColor = .labelColor
            }
            return button

        case "Reset":
            let isCustomized = manager.isCustomized(id: def.id)
            let button = NSButton(title: "Reset", target: self, action: #selector(resetRowClicked(_:)))
            button.tag = row
            button.bezelStyle = .inline
            button.controlSize = .mini
            button.isEnabled = isCustomized
            return button

        default:
            return nil
        }
    }

    // MARK: - Recording Actions

    @objc private func shortcutButtonClicked(_ sender: NSButton) {
        let row = sender.tag
        guard row < filteredDefinitions.count else { return }
        let def = filteredDefinitions[row]

        if recordingDefinitionID == def.id {
            stopRecording()
            return
        }

        startRecording(for: def.id)
    }

    @objc private func resetRowClicked(_ sender: NSButton) {
        let row = sender.tag
        guard row < filteredDefinitions.count else { return }
        let def = filteredDefinitions[row]
        manager.resetShortcut(id: def.id)
        updateFilter()
    }

    @objc private func restoreAllDefaultsClicked() {
        let alert = NSAlert()
        alert.messageText = "Restore Default Shortcuts?"
        alert.informativeText = "All customized keyboard shortcuts will be reset to their factory defaults."
        alert.addButton(withTitle: "Restore Defaults")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        if alert.runModal() == .alertFirstButtonReturn {
            manager.resetAll()
            updateFilter()
        }
    }

    private func startRecording(for id: String) {
        stopRecording()
        recordingDefinitionID = id
        tableView.reloadData()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let targetID = self.recordingDefinitionID else { return event }

            // Escape cancels recording
            if event.keyCode == 53 {
                self.stopRecording()
                return nil
            }

            // Backspace / Delete resets shortcut to default
            if event.keyCode == 51 || event.keyCode == 117 {
                self.manager.resetShortcut(id: targetID)
                self.stopRecording()
                return nil
            }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Require at least one modifier flag or function key
            guard !flags.isEmpty, let chars = event.charactersIgnoringModifiers, !chars.isEmpty else {
                return nil
            }

            let key = chars.lowercased()

            // Conflict detection
            if let conflict = self.manager.findConflict(key: key, modifiers: flags, excluding: targetID) {
                let alert = NSAlert()
                alert.messageText = "Shortcut Already In Use"
                let keyStr = ShortcutFormatter.format(key: key, modifiers: flags)
                alert.informativeText = "The shortcut \"\(keyStr)\" is already assigned to \"\(conflict.title)\". Do you want to reassign it?"
                alert.addButton(withTitle: "Reassign")
                alert.addButton(withTitle: "Cancel")

                if alert.runModal() == .alertFirstButtonReturn {
                    self.manager.resetShortcut(id: conflict.id)
                    self.manager.setShortcut(id: targetID, key: key, modifiers: flags)
                }
            } else {
                self.manager.setShortcut(id: targetID, key: key, modifiers: flags)
            }

            self.stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        recordingDefinitionID = nil
        tableView.reloadData()
    }
}
