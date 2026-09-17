import AppKit

/// The Websites pane: a list of per-site settings on the left, and for the
/// chosen one, its default and the sites that differ from it.
@MainActor
final class WebsitesSettingsViewController: NSViewController, SettingsWidePane {
    private let categories = SiteSettingCategory.allCases
    /// One row per category, built from the same `SettingsRailRow` the window's
    /// spine is built from -- see that file for why this is not a table.
    private var categoryRows: [SiteSettingCategory: SettingsRailRow] = [:]
    private let sitesTable = NSTableView()
    private let defaultPopUp = NSPopUpButton()
    private let instruction = NSTextField(labelWithString: "")
    private let removeButton = NSButton(title: "", target: nil, action: nil)
    private var category: SiteSettingCategory = .pageZoom
    private var hosts: [String] = []
    /// The sites table stands at the height of its rows. It used to be tied to
    /// the height of the category list beside it, which meant twenty categories
    /// of empty banded rows under one configured website.
    private var sitesHeight: NSLayoutConstraint?

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

        // A rail, not a table. Every category on screen at once, each one the
        // window's own row: the mark keeps its colour whatever is selected, the
        // pill lights under the pointer, and the row squeezes when it is
        // pressed -- none of which a table row did.
        let rail = NSStackView()
        rail.orientation = .vertical
        rail.alignment = .leading
        rail.spacing = 0
        rail.translatesAutoresizingMaskIntoConstraints = false
        for category in categories {
            let row = SettingsRailRow(
                title: category.title,
                symbolName: category.symbolName,
                accent: category.tileColour
            ) { [weak self] in self?.show(category) }
            categoryRows[category] = row
            rail.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rail.widthAnchor).isActive = true
        }

        let left = NSStackView(views: [header, rail])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 6
        let leftBox = boxed(left, padding: Style.SettingsUI.cardPadding)
        // The rows run the width of the box, so a pill is a pill rather than a
        // lozenge as wide as the longest category's name.
        rail.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true
        // Wide enough for the longest category. At 230 "Tab Sleeping & Archiving"
        // was cut off mid-word.
        leftBox.widthAnchor.constraint(equalToConstant: 268).isActive = true

        // Right: the default, and the sites.
        let defaultLabel = NSTextField(labelWithString: "Default setting for all websites:")
        defaultPopUp.target = self
        defaultPopUp.action = #selector(defaultChanged)
        let defaultRow = NSStackView(views: [defaultLabel, NSView(), SettingsForm.fill(defaultPopUp)])
        defaultRow.orientation = .horizontal
        defaultRow.alignment = .centerY
        defaultRow.translatesAutoresizingMaskIntoConstraints = false

        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false

        let hostColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("host"))
        // "Website", not "Configured Websites": the line directly above the
        // table already says these are the websites you have configured, and
        // the longer caption did not fit the column at any pane width the
        // window actually opens at -- it was being shortened to "CONFIGURED
        // WEBSI". A column caption names one row, and each row is a website.
        hostColumn.title = "Website"
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
        // The window's own column captions rather than AppKit's grey bar. The
        // categories beside this list have no header at all, so a stock one
        // here was the only bevelled thing on the pane.
        sitesTable.headerView = SettingsTableHeader()
        // A row is the dropdown it holds plus air on both sides. The house
        // dropdown is a fixed 30 points tall, so at a row height of 28 two of
        // them overlapped by two points: the plates touched and read as one
        // block rather than as one control per website.
        sitesTable.rowHeight = SettingsChoiceControl.height + 8
        sitesTable.style = .plain
        // Banding on rows that are not there is what filled the plate with
        // three hundred points of empty grey stripes.
        sitesTable.usesAlternatingRowBackgroundColors = false
        sitesTable.gridStyleMask = []
        sitesTable.backgroundColor = .clear
        sitesTable.dataSource = self
        sitesTable.delegate = self
        let sitesScroll = PassingScrollView()
        sitesScroll.documentView = sitesTable
        sitesScroll.hasVerticalScroller = false
        sitesScroll.drawsBackground = false
        sitesScroll.borderType = .noBorder
        sitesScroll.translatesAutoresizingMaskIntoConstraints = false
        let sitesTall = sitesScroll.heightAnchor.constraint(equalToConstant: 120)
        sitesTall.isActive = true
        sitesHeight = sitesTall

        let add = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add the current website")!,
                           target: self, action: #selector(addSite))
        add.isBordered = false
        add.contentTintColor = Style.Colors.secondaryText
        add.setAccessibilityLabel("Add the current website")
        removeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove the selected website")
        removeButton.isBordered = false
        removeButton.contentTintColor = Style.Colors.secondaryText
        removeButton.target = self
        removeButton.action = #selector(removeSite)
        removeButton.setAccessibilityLabel("Remove the selected website")
        removeButton.isEnabled = false
        // Drawn at a size you can hit: the minus was a hairline.
        for button in [add, removeButton] {
            button.image = button.image?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            )
        }
        let buttons = NSStackView(views: [add, removeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 6

        // Whatever height the right plate has over its content goes here,
        // under the buttons, so the plate stands as tall as the list beside
        // it without the table growing to fill it.
        let slack = NSView()
        slack.translatesAutoresizingMaskIntoConstraints = false
        slack.setContentHuggingPriority(.init(1), for: .vertical)

        let right = NSStackView(views: [defaultRow, line, instruction, sitesScroll, buttons, slack])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 12
        right.setCustomSpacing(16, after: line)
        right.distribution = .fill
        let rightBox = boxed(right, padding: Style.SettingsUI.cardPadding)
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
            // The two plates share a bottom edge. A short box beside a tall
            // column looked like something had failed to load into it.
            rightBox.heightAnchor.constraint(greaterThanOrEqualTo: leftBox.heightAnchor),
            // No inset of its own: the window gives every pane the same gutter,
            // and a pane that adds twenty more sits further in than its
            // neighbours for no reason anyone can see.
            columns.topAnchor.constraint(equalTo: view.topAnchor),
            columns.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            columns.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            columns.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    /// A rounded, slightly lighter plate, as the screen this is modelled on
    /// draws its two halves.
    private func boxed(_ content: NSStackView, padding: CGFloat) -> NSView {
        let box = SettingsPlateView()
        box.fill = Style.Colors.settingsGlass
        box.stroke = Style.Colors.settingsCardStroke
        box.cornerRadius = Style.SettingsUI.cardRadius
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
        for (each, row) in categoryRows { row.isChosen = each == category }
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
        let header = sitesTable.headerView?.frame.height ?? 0
        let rows = CGFloat(hosts.count) * (sitesTable.rowHeight + sitesTable.intercellSpacing.height)
        sitesHeight?.constant = max(90, header + rows + 4)
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
        guard let typed = TextPrompt.ask(
            title: "Add a website",
            message: "Its own \(category.title.lowercased()) setting will start as the default.",
            initial: suggested, placeholder: "example.com", confirm: "Add"
        ) else { return }
        let host = SiteSettingsState.normalise(typed)
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
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SettingsTableRow()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        hosts.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
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
        // Centred in the row rather than handed to the table bare. A view given
        // to a table is stretched to the row, and this one is a plate with a
        // height of its own: stretched, it draws outside its row and into the
        // one below.
        let dressed = SettingsForm.fill(popUp)
        dressed.translatesAutoresizingMaskIntoConstraints = false
        let cell = NSView()
        cell.addSubview(dressed)
        NSLayoutConstraint.activate([
            dressed.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            dressed.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            dressed.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        removeButton.isEnabled = table.selectedRow >= 0
    }
}
