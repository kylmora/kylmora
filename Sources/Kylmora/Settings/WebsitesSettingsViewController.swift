import AppKit

/// The Websites pane: a list of per-site settings on the left, and for the
/// chosen one, its default and the sites that differ from it.
@MainActor
final class WebsitesSettingsViewController: NSViewController {
    private let categories = SiteSettingCategory.allCases
    private let categoryTable = NSTableView()
    private let sitesTable = NSTableView()
    private let defaultPopUp = NSPopUpButton()
    private let instruction = NSTextField(labelWithString: "")
    private let removeButton = NSButton(title: "", target: nil, action: nil)
    private var category: SiteSettingCategory = .pageZoom
    private var hosts: [String] = []

    /// The page in front, whose site the plus button adds.
    var currentPageURL: (() -> URL?)?

    override func loadView() {
        view = NSView()
        buildLayout()
        SiteSettings.shared.addChangeObserver { [weak self] in self?.reloadSites() }
        show(.pageZoom)
    }

    private func buildLayout() {
        // Left: the categories, in a bordered box under a header.
        let header = NSTextField(labelWithString: "General Settings")
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        header.textColor = .secondaryLabelColor

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("category"))
        column.resizingMask = .autoresizingMask
        categoryTable.addTableColumn(column)
        categoryTable.headerView = nil
        // Every category on screen at once: twenty rows of 32 fit where ten
        // of 40 hid the other ten behind a scroller nobody could see.
        categoryTable.rowHeight = 32
        categoryTable.style = .plain
        categoryTable.backgroundColor = .clear
        categoryTable.dataSource = self
        categoryTable.delegate = self
        let categoryScroll = NSScrollView()
        categoryScroll.documentView = categoryTable
        categoryScroll.drawsBackground = false
        categoryScroll.hasVerticalScroller = true
        categoryScroll.translatesAutoresizingMaskIntoConstraints = false
        categoryScroll.heightAnchor.constraint(
            equalToConstant: CGFloat(categories.count) * categoryTable.rowHeight + 4
        ).isActive = true

        let left = NSStackView(views: [header, categoryScroll])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 6
        let leftBox = boxed(left, padding: 8)
        leftBox.widthAnchor.constraint(equalToConstant: 230).isActive = true

        // Right: the default, and the sites.
        let defaultLabel = NSTextField(labelWithString: "Default setting for all websites:")
        defaultPopUp.target = self
        defaultPopUp.action = #selector(defaultChanged)
        let defaultRow = NSStackView(views: [defaultLabel, NSView(), defaultPopUp])
        defaultRow.orientation = .horizontal
        defaultRow.alignment = .centerY
        defaultRow.translatesAutoresizingMaskIntoConstraints = false

        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false

        let hostColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("host"))
        hostColumn.title = "Configured Websites"
        hostColumn.resizingMask = .autoresizingMask
        let settingColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("setting"))
        settingColumn.title = "Setting"
        settingColumn.width = 150
        settingColumn.minWidth = 150
        settingColumn.resizingMask = []
        sitesTable.addTableColumn(hostColumn)
        sitesTable.addTableColumn(settingColumn)
        // The site names take whatever width is left; the setting column
        // keeps its own, so it is never squeezed out of the table.
        sitesTable.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        sitesTable.rowHeight = 26
        sitesTable.style = .plain
        sitesTable.usesAlternatingRowBackgroundColors = true
        sitesTable.dataSource = self
        sitesTable.delegate = self
        let sitesScroll = NSScrollView()
        sitesScroll.documentView = sitesTable
        sitesScroll.hasVerticalScroller = true
        sitesScroll.borderType = .bezelBorder
        sitesScroll.translatesAutoresizingMaskIntoConstraints = false
        sitesScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        sitesScroll.setContentHuggingPriority(.defaultLow, for: .vertical)

        let add = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add the current website")!,
                           target: self, action: #selector(addSite))
        add.bezelStyle = .smallSquare
        add.setAccessibilityLabel("Add the current website")
        removeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove the selected website")
        removeButton.bezelStyle = .smallSquare
        removeButton.target = self
        removeButton.action = #selector(removeSite)
        removeButton.setAccessibilityLabel("Remove the selected website")
        removeButton.isEnabled = false
        let buttons = NSStackView(views: [add, removeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 0

        let right = NSStackView(views: [defaultRow, line, instruction, sitesScroll, buttons])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 12
        right.setCustomSpacing(16, after: line)
        // The table takes the height the list on the left sets.
        right.distribution = .fill
        let rightBox = boxed(right, padding: 20)
        rightBox.setContentHuggingPriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            defaultRow.widthAnchor.constraint(equalTo: right.widthAnchor),
            line.widthAnchor.constraint(equalTo: right.widthAnchor),
            sitesScroll.widthAnchor.constraint(equalTo: right.widthAnchor)
        ])

        let columns = NSStackView(views: [leftBox, rightBox])
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.spacing = 16
        // The right plate fills what the left one leaves. A stack's default
        // distribution packs its views at their own size and leaves the
        // rest empty, which is how the table lost its second column.
        columns.distribution = .fill
        columns.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(columns)
        NSLayoutConstraint.activate([
            columns.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            columns.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            columns.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            columns.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            leftBox.heightAnchor.constraint(equalTo: rightBox.heightAnchor)
        ])
    }

    /// A rounded, slightly lighter plate, as the screen this is modelled on
    /// draws its two halves.
    private func boxed(_ content: NSStackView, padding: CGFloat) -> NSView {
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.cornerCurve = .continuous
        box.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        content.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: box.topAnchor, constant: padding),
            content.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: padding),
            content.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -padding),
            content.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -padding)
        ])
        return box
    }

    // MARK: - State

    private func show(_ category: SiteSettingCategory) {
        self.category = category
        if let row = categories.firstIndex(of: category), categoryTable.selectedRow != row {
            categoryTable.selectRowIndexes([row], byExtendingSelection: false)
        }
        defaultPopUp.removeAllItems()
        defaultPopUp.addItems(withTitles: category.options.map(\.title))
        instruction.stringValue = category.instruction
        reloadSites()
    }

    private func reloadSites() {
        let state = SiteSettings.shared.state
        let current = state.defaultOption(for: category)
        if let index = category.options.firstIndex(where: { $0.id == current }) {
            defaultPopUp.selectItem(at: index)
        }
        hosts = state.configuredHosts(for: category)
        sitesTable.reloadData()
        removeButton.isEnabled = sitesTable.selectedRow >= 0
    }

    // MARK: - Actions

    @objc private func defaultChanged() {
        let index = defaultPopUp.indexOfSelectedItem
        guard category.options.indices.contains(index) else { return }
        let option = category.options[index].id
        let category = category
        SiteSettings.shared.update { $0.setDefault(option, for: category) }
    }

    @objc private func addSite() {
        let category = category
        let suggested = currentPageURL?()?.host().map(SiteSettingsState.normalise) ?? ""
        let alert = NSAlert()
        alert.messageText = "Add a website"
        alert.informativeText = "Its own \(category.title.lowercased()) setting will start as the default."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = suggested
        field.placeholderString = "example.com"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let host = SiteSettingsState.normalise(field.stringValue)
        guard !host.isEmpty else { return }
        let option = SiteSettings.shared.state.defaultOption(for: category)
        SiteSettings.shared.update { $0.set(option, for: host, in: category) }
        if let row = hosts.firstIndex(of: host) {
            sitesTable.selectRowIndexes([row], byExtendingSelection: false)
        }
    }

    @objc private func removeSite() {
        let row = sitesTable.selectedRow
        guard hosts.indices.contains(row) else { return }
        let host = hosts[row]
        let category = category
        SiteSettings.shared.update { $0.remove(host, from: category) }
    }

    @objc private func siteOptionChanged(_ sender: NSPopUpButton) {
        let row = sender.tag
        guard hosts.indices.contains(row), category.options.indices.contains(sender.indexOfSelectedItem) else { return }
        let host = hosts[row]
        let option = category.options[sender.indexOfSelectedItem].id
        let category = category
        SiteSettings.shared.update { $0.set(option, for: host, in: category) }
    }
}

extension WebsitesSettingsViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === categoryTable ? categories.count : hosts.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === categoryTable {
            guard categories.indices.contains(row) else { return nil }
            let category = categories[row]
            let tile = SettingsSwitchRow.tileView(.symbol(category.symbolName, category.tileColour), side: 28)
            let label = NSTextField(labelWithString: category.title)
            label.setAccessibilityElement(false)
            let stack = NSStackView(views: [tile, label])
            stack.orientation = .horizontal
            stack.spacing = 10
            stack.alignment = .centerY
            stack.translatesAutoresizingMaskIntoConstraints = false
            let cell = NSTableCellView()
            cell.addSubview(stack)
            cell.textField = label
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            cell.setAccessibilityLabel(category.title)
            return cell
        }

        guard hosts.indices.contains(row) else { return nil }
        let host = hosts[row]
        if tableColumn?.identifier.rawValue == "host" {
            let label = NSTextField(labelWithString: host)
            label.translatesAutoresizingMaskIntoConstraints = false
            let cell = NSTableCellView()
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }
        let popUp = NSPopUpButton()
        popUp.controlSize = .small
        popUp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        popUp.addItems(withTitles: category.options.map(\.title))
        let option = SiteSettings.shared.state.option(for: category, host: host) ?? category.builtInDefault
        if let index = category.options.firstIndex(where: { $0.id == option }) { popUp.selectItem(at: index) }
        popUp.tag = row
        popUp.target = self
        popUp.action = #selector(siteOptionChanged(_:))
        popUp.setAccessibilityLabel("\(category.title) for \(host)")
        return popUp
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        if table === categoryTable {
            guard categories.indices.contains(table.selectedRow) else { return }
            show(categories[table.selectedRow])
        } else {
            removeButton.isEnabled = table.selectedRow >= 0
        }
    }
}
