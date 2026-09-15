import AppKit

/// A scroll view that scrolls nothing and says so.
///
/// The table is given its full height and has no scroller of its own, but an
/// `NSScrollView` takes the wheel regardless: it handles the event, finds it
/// has nowhere to go, and stops there. The page behind it never moves, and the
/// shortcuts list cannot be scrolled at all. Handing the event to the next
/// responder puts it back on its way to the detail side's own scroll view.
@MainActor
final class PassingScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

/// Settings pane for browsing, recording, and customizing keyboard shortcuts.
@MainActor
final class ShortcutsSettingsViewController: NSViewController, SettingsWidePane, NSTableViewDataSource, NSTableViewDelegate {
    private let manager: ShortcutManager

    private let searchField = NSSearchField()
    /// The category filter. A pop-up rather than a segmented control: six
    /// segments and a button could not both fit the pane's width, and a
    /// segmented control given less room than it needs does not shrink -- it
    /// draws over whatever is beside it, which is what it was doing.
    private let categoryPopUp = NSPopUpButton()
    private let restoreDefaultsButton = NSButton(title: "Restore All Defaults", target: nil, action: nil)
    private let tableView = NSTableView()
    private let scrollView = PassingScrollView()
    /// The table is as tall as its rows. The pane is already inside a scroll
    /// view, and a second scroller inside it -- a short window on a long list,
    /// with empty pane below -- is the worst of both.
    private var tableHeight: NSLayoutConstraint?

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

        searchField.placeholderString = "Search shortcuts\u{2026}"
        searchField.target = self
        searchField.action = #selector(filterChanged)
        searchField.setContentHuggingPriority(.init(1), for: .horizontal)

        categoryPopUp.addItem(withTitle: "All")
        categoryPopUp.addItems(withTitles: ShortcutCategory.allCases.map(\.rawValue))
        categoryPopUp.selectItem(at: 0)
        categoryPopUp.target = self
        categoryPopUp.action = #selector(filterChanged)

        restoreDefaultsButton.target = self
        restoreDefaultsButton.action = #selector(restoreAllDefaultsClicked)

        // Every control at its own size with the search field taking the slack,
        // so nothing is ever asked to draw where something else already is.
        let header = NSStackView(views: [
            searchField,
            SettingsForm.fill(categoryPopUp),
            // At its own size: `fill` would give it the width of a control
            // column, which on a button is just a very wide button.
            SettingsControlPlate(restoreDefaultsButton, width: nil)
        ])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.distribution = .fill
        header.spacing = 10
        header.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(header)

        let colAction = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Action"))
        colAction.title = "Action"
        colAction.width = 300
        colAction.minWidth = 200

        let colCategory = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Category"))
        colCategory.title = "Category"
        colCategory.width = 110

        let colShortcut = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Shortcut"))
        colShortcut.title = "Shortcut"
        colShortcut.width = 130

        let colReset = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Reset"))
        colReset.title = ""
        colReset.width = 60

        tableView.addTableColumn(colAction)
        tableView.addTableColumn(colCategory)
        tableView.addTableColumn(colShortcut)
        tableView.addTableColumn(colReset)
        // The action column takes whatever width the window has to give, so
        // the table fills the pane instead of stopping short of it.
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.headerView = NSTableHeaderView()
        // Tall enough for the key cap and air on either side of it. At 32 the
        // caps sat two points apart and read as one column of buttons.
        tableView.rowHeight = 40
        // The grey-and-white banding is stock AppKit and reads as a spreadsheet
        // in a window that is glass and cards everywhere else. A hairline
        // between rows, the same one the cards use, is what divides them.
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.gridStyleMask = .solidHorizontalGridLineMask
        tableView.gridColor = Style.Colors.settingsHairline
        tableView.intercellSpacing = NSSize(width: 3, height: 1)
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = tableView
        // No scroller of its own: the detail side scrolls, and the table is
        // given its whole height below.
        scrollView.hasVerticalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // On a card, like everything else in the window. Rows floating on the
        // wash with nothing around them looked like a pane that had not
        // finished loading.
        let card = SettingsPlateView()
        card.fill = Style.Colors.settingsGlass
        card.stroke = Style.Colors.settingsCardStroke
        card.cornerRadius = Style.SettingsUI.cardRadius
        card.layer?.masksToBounds = true
        card.addSubview(scrollView)
        container.addSubview(card)

        let height = scrollView.heightAnchor.constraint(equalToConstant: 200)
        tableHeight = height

        let inset: CGFloat = 8
        NSLayoutConstraint.activate([
            // No width of its own: the pane is the container, and the window
            // has already given it a gutter.
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 520),

            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            card.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16),
            card.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            scrollView.topAnchor.constraint(equalTo: card.topAnchor, constant: inset),
            scrollView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: inset),
            scrollView.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -inset),
            scrollView.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -inset),
            height
        ])

        manager.onChange = { [weak self] in
            self?.updateFilter()
        }

        updateFilter()
    }

    /// The table stands at its full height, so the pane's own scroller is the
    /// only one there is.
    private func resizeTable() {
        let header = tableView.headerView?.frame.height ?? 0
        let rows = CGFloat(filteredDefinitions.count) * (tableView.rowHeight + tableView.intercellSpacing.height)
        tableHeight?.constant = max(120, header + rows + 4)
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
        let selectedCategoryIndex = categoryPopUp.indexOfSelectedItem

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
        resizeTable()
    }

    // MARK: - Table View Data Source & Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredDefinitions.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SettingsTableRow()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filteredDefinitions.count else { return nil }
        let def = filteredDefinitions[row]
        let identifier = tableColumn?.identifier.rawValue

        let accent = tableView.settingsAccent ?? .controlAccentColor
        /// A label centred on the row, level with the key cap beside it. A
        /// bare text field handed to the table is stretched to the row and
        /// draws its text along the top of it.
        func centred(_ label: NSTextField) -> NSView {
            let cell = NSView()
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }
        switch identifier {
        case "Action":
            let label = NSTextField(labelWithString: def.title)
            label.font = Style.Fonts.settingsRow
            label.textColor = Style.Colors.primaryText
            label.lineBreakMode = .byTruncatingTail
            return centred(label)

        case "Category":
            let label = NSTextField(labelWithString: def.category.rawValue)
            label.font = Style.Fonts.settingsNote
            label.textColor = Style.Colors.secondaryText
            return centred(label)

        case "Shortcut":
            let isRecording = recordingDefinitionID == def.id
            let display = isRecording ? "Type shortcut\u{2026}" : manager.displayString(for: def.id)

            let button = NSButton(title: display.isEmpty ? "None" : display, target: self, action: #selector(shortcutButtonClicked(_:)))
            button.tag = row
            button.controlSize = .small
            // Dressed like every other control in the window: the system bezel
            // repeated down forty rows is the whole pane's character.
            let plate = SettingsControlPlate(button, width: nil)
            button.font = NSFont.monospacedSystemFont(ofSize: 12, weight: isRecording ? .bold : .medium)
            if isRecording {
                button.contentTintColor = accent
            } else if manager.isCustomized(id: def.id) {
                button.contentTintColor = accent
            } else {
                button.contentTintColor = Style.Colors.primaryText
            }
            // A key cap: as wide as the keys on it, centred in the row, rather
            // than a plate stretched to the column and the row.
            let cell = NSView()
            cell.addSubview(plate)
            NSLayoutConstraint.activate([
                plate.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                plate.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
                plate.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                plate.widthAnchor.constraint(greaterThanOrEqualToConstant: 72)
            ])
            return cell

        case "Reset":
            // Only where there is something to reset. Forty greyed-out
            // "Reset"s down the side of the list were noise.
            let isCustomized = manager.isCustomized(id: def.id)
            let button = NSButton(title: "Reset", target: self, action: #selector(resetRowClicked(_:)))
            button.tag = row
            button.isBordered = false
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11, weight: .medium)
            button.contentTintColor = accent
            button.isHidden = !isCustomized
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
            // Require at least one modifier flag, unless the key itself is a
            // function/special key (arrows, F-keys live in U+F700-U+F8FF and
            // arrive with no device-independent flags set).
            guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty,
                  (!flags.isEmpty || chars.unicodeScalars.contains(where: { (0xF700...0xF8FF).contains($0.value) })) else {
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
                    self.manager.clearShortcut(id: conflict.id)
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
