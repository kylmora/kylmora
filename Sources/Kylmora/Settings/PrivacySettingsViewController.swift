import AppKit

/// The Privacy pane: what is stripped, kept, deleted and reported, the
/// custom user agent, and the content blocker with its lists.
@MainActor
final class PrivacySettingsViewController: NSViewController {
    private let settings: Settings
    private let blocker: ContentBlocker
    private let session: BrowserSession?
    private let trackersPopUp = NSPopUpButton()
    private let historyPopUp = NSPopUpButton()
    private let cookiesPopUp = NSPopUpButton()
    private let disableHistory = NSButton(checkboxWithTitle: "Disable History", target: nil, action: nil)
    private let crashAsk = NSButton(radioButtonWithTitle: CrashReportPolicy.ask.title, target: nil, action: nil)
    private let crashAlways = NSButton(radioButtonWithTitle: CrashReportPolicy.always.title, target: nil, action: nil)
    private let crashNever = NSButton(radioButtonWithTitle: CrashReportPolicy.never.title, target: nil, action: nil)
    private let userAgentField = NSTextField()
    private let adsSwitch = NSSwitch()
    private let cookiesSwitch = NSSwitch()
    private let trackersSwitch = NSSwitch()
    private let autoUpdate = NSButton(checkboxWithTitle: "Auto-update content blockers", target: nil, action: nil)
    private let updatedLabel = NSTextField(labelWithString: "")
    private let rulesLabel = NSTextField(labelWithString: "")
    private let updateButton = NSButton(title: "Update Now", target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    init(settings: Settings = .shared, blocker: ContentBlocker = .shared, session: BrowserSession? = nil) {
        self.settings = settings
        self.blocker = blocker
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("PrivacySettingsViewController is created in code only")
    }

    override func loadView() {
        let form = SettingsForm()
        view = form
        buildLayout(in: form)
        reload()
        blocker.onChange = { [weak self] in self?.reloadStatus() }
    }

    private func buildLayout(in form: SettingsForm) {
        trackersPopUp.addItems(withTitles: TrackerRemoval.allCases.map(\.title))
        trackersPopUp.target = self
        trackersPopUp.action = #selector(trackersChanged)
        form.addRow("Remove trackers from URLs", SettingsForm.fill(trackersPopUp))
        form.addNote("Parameters that only say which advert, mail or post a link came from are dropped before the page loads.")

        historyPopUp.addItems(withTitles: HistoryRetention.allCases.map(\.title))
        historyPopUp.target = self
        historyPopUp.action = #selector(historyChanged)
        form.addRow("Remove history items", SettingsForm.fill(historyPopUp))

        cookiesPopUp.addItems(withTitles: CookieDeletion.allCases.map(\.title))
        cookiesPopUp.target = self
        cookiesPopUp.action = #selector(cookiesChanged)
        form.addRow("Automatically delete cookies", SettingsForm.fill(cookiesPopUp))

        disableHistory.target = self
        disableHistory.action = #selector(disableHistoryChanged)
        form.addRow("History", disableHistory)

        let reset = NSButton(title: "Reset Kylmora\u{2026}", target: self, action: #selector(resetTapped))
        reset.bezelStyle = .rounded
        let manage = NSButton(title: "Manage Website Data\u{2026}", target: self, action: #selector(manageWebsiteData))
        manage.bezelStyle = .rounded
        let dataButtons = NSStackView(views: [reset, manage])
        dataButtons.orientation = .horizontal
        dataButtons.spacing = 8
        form.addRow("Cookies and website data", dataButtons)

        for radio in [crashAsk, crashAlways, crashNever] {
            radio.target = self
            radio.action = #selector(crashPolicyChanged)
        }
        let crash = NSStackView(views: [crashAsk, crashAlways, crashNever])
        crash.orientation = .vertical
        crash.alignment = .leading
        crash.spacing = 6
        form.addRow("Crash reports", crash)

        userAgentField.placeholderString = "Mozilla/5.0 \u{2026}"
        userAgentField.target = self
        userAgentField.action = #selector(userAgentCommitted)
        form.addRow("\u{201c}Custom\u{201d} user agent", SettingsForm.fill(userAgentField))
        form.addNote("Used when \u{201c}Custom\u{201d} is chosen for a site's user agent in Website Settings.")

        form.addSeparator()

        let card = SettingsCardView(rows: [
            SettingsSwitchRow(tile: .symbol("hand.raised.fill", .systemRed), title: "Block ads", control: adsSwitch),
            SettingsSwitchRow(tile: .emoji("\u{1F36A}", .systemOrange), title: "Block cookie banners", control: cookiesSwitch),
            SettingsSwitchRow(tile: .symbol("eyeglasses", .systemYellow), title: "Block trackers", control: trackersSwitch)
        ])
        for (control, selector) in [
            (adsSwitch, #selector(adsChanged)),
            (cookiesSwitch, #selector(cookieBannersChanged)),
            (trackersSwitch, #selector(trackerListsChanged))
        ] {
            control.target = self
            control.action = selector
        }
        form.addRow("Content blocker", SettingsForm.fill(card))

        autoUpdate.target = self
        autoUpdate.action = #selector(autoUpdateChanged)
        updatedLabel.font = .systemFont(ofSize: 12)
        updatedLabel.textColor = .secondaryLabelColor
        rulesLabel.font = .systemFont(ofSize: 12)
        rulesLabel.textColor = .secondaryLabelColor
        updateButton.target = self
        updateButton.action = #selector(updateNow)
        updateButton.bezelStyle = .rounded
        let manageLists = NSButton(title: "Manage Filter Lists\u{2026}", target: self, action: #selector(showAdvanced))
        manageLists.bezelStyle = .rounded
        let listButtons = NSStackView(views: [updateButton, manageLists])
        listButtons.orientation = .horizontal
        listButtons.spacing = 8
        let blockerRows = NSStackView(views: [autoUpdate, updatedLabel, rulesLabel, listButtons])
        blockerRows.orientation = .vertical
        blockerRows.alignment = .leading
        blockerRows.spacing = 8
        form.addContinuation(blockerRows)
        form.addNote(statusLabel)
    }

    private func reload() {
        trackersPopUp.selectItem(at: TrackerRemoval.allCases.firstIndex(of: settings.trackerRemoval) ?? 0)
        historyPopUp.selectItem(at: HistoryRetention.allCases.firstIndex(of: settings.historyRetention) ?? 0)
        cookiesPopUp.selectItem(at: CookieDeletion.allCases.firstIndex(of: settings.cookieDeletion) ?? 0)
        disableHistory.state = settings.historyDisabled ? .on : .off
        crashAsk.state = settings.crashReportPolicy == .ask ? .on : .off
        crashAlways.state = settings.crashReportPolicy == .always ? .on : .off
        crashNever.state = settings.crashReportPolicy == .never ? .on : .off
        userAgentField.stringValue = settings.customUserAgent ?? ""
        let preferences = settings.contentBlocking
        adsSwitch.state = preferences.blocksAds ? .on : .off
        cookiesSwitch.state = preferences.blocksCookieBanners ? .on : .off
        trackersSwitch.state = preferences.blocksTrackers ? .on : .off
        autoUpdate.state = settings.autoUpdatesFilterLists ? .on : .off
        reloadStatus()
    }

    /// The lines under the card: when the lists were fetched, what is in
    /// force, and anything still downloading or failing.
    private func reloadStatus() {
        if let updated = blocker.lastUpdated {
            updatedLabel.stringValue = "Last updated \u{2013} \(updated.formatted(date: .numeric, time: .shortened))"
        } else {
            updatedLabel.stringValue = blocker.activeLists.isEmpty ? "No lists are in use." : "Not yet downloaded."
        }
        let summary = blocker.activeSummary
        let lists = summary.lists == 1 ? "1 active list" : "\(summary.lists) active lists"
        rulesLabel.stringValue = "\(Self.formatted(summary.rules)) active rules from \(lists)."

        var parts: [String] = []
        var fetching = 0
        var failed = 0
        for list in blocker.activeLists {
            switch blocker.statuses[list.id] {
            case .fetching: fetching += 1
            case .failed: failed += 1
            default: break
            }
        }
        if fetching > 0 { parts.append(fetching == 1 ? "1 list downloading" : "\(fetching) lists downloading") }
        if failed > 0 { parts.append(failed == 1 ? "1 list could not be downloaded" : "\(failed) lists could not be downloaded") }
        statusLabel.stringValue = parts.isEmpty ? "Changes apply to pages as they load." : parts.joined(separator: " \u{00b7} ") + "."
        updateButton.isEnabled = fetching == 0
    }

    private static func formatted(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: count)) ?? String(count)
    }

    // MARK: - Actions

    @objc private func trackersChanged() {
        guard TrackerRemoval.allCases.indices.contains(trackersPopUp.indexOfSelectedItem) else { return }
        settings.trackerRemoval = TrackerRemoval.allCases[trackersPopUp.indexOfSelectedItem]
    }

    @objc private func historyChanged() {
        guard HistoryRetention.allCases.indices.contains(historyPopUp.indexOfSelectedItem) else { return }
        settings.historyRetention = HistoryRetention.allCases[historyPopUp.indexOfSelectedItem]
        session?.pruneHistory()
    }

    @objc private func cookiesChanged() {
        guard CookieDeletion.allCases.indices.contains(cookiesPopUp.indexOfSelectedItem) else { return }
        settings.cookieDeletion = CookieDeletion.allCases[cookiesPopUp.indexOfSelectedItem]
    }

    @objc private func disableHistoryChanged() {
        settings.historyDisabled = disableHistory.state == .on
    }

    @objc private func crashPolicyChanged(_ sender: NSButton) {
        settings.crashReportPolicy = sender === crashAlways ? .always : sender === crashNever ? .never : .ask
    }

    @objc private func userAgentCommitted() {
        settings.customUserAgent = userAgentField.stringValue
    }

    @objc private func resetTapped() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reset Kylmora?"
        alert.informativeText = "History, cookies and every space's website data are erased, and open pages reload signed out. Spaces, bookmarks and settings are kept."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, let session else { return }
        Task { await session.resetBrowsingData() }
    }

    @objc private func manageWebsiteData() {
        let sheet = WebsiteDataViewController(identities: session?.storedIdentities ?? [.standard])
        presentAsSheet(sheet)
    }

    private func update(_ change: (inout ContentBlockingPreferences) -> Void) {
        var preferences = settings.contentBlocking
        change(&preferences)
        settings.contentBlocking = preferences
        blocker.preferencesChanged()
        reloadStatus()
    }

    @objc private func adsChanged() { update { $0.blocksAds = adsSwitch.state == .on } }
    @objc private func cookieBannersChanged() { update { $0.blocksCookieBanners = cookiesSwitch.state == .on } }
    @objc private func trackerListsChanged() { update { $0.blocksTrackers = trackersSwitch.state == .on } }

    @objc private func autoUpdateChanged() {
        settings.autoUpdatesFilterLists = autoUpdate.state == .on
    }

    @objc private func updateNow() {
        blocker.refreshAll()
        reloadStatus()
    }

    @objc private func showAdvanced() {
        let sheet = AdvancedBlockingViewController(settings: settings, blocker: blocker)
        sheet.onDismiss = { [weak self] in self?.reloadStatus() }
        presentAsSheet(sheet)
    }
}

/// The sites with data on disk, to remove one at a time or all at once.
@MainActor
final class WebsiteDataViewController: NSViewController {
    private let identities: [Space.Identity]
    private let table = NSTableView()
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let removeAllButton = NSButton(title: "Remove All", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "Loading\u{2026}")
    private var records: [WebsiteData.Record] = []

    init(identities: [Space.Identity]) {
        self.identities = identities
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("WebsiteDataViewController is created in code only")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 420))
        let title = NSTextField(labelWithString: "Website Data")
        title.font = .systemFont(ofSize: 17, weight: .bold)
        let blurb = NSTextField(wrappingLabelWithString: "Every site that has stored something in any of your spaces. Removing a site's data signs you out of it there.")
        blurb.font = .systemFont(ofSize: 12)
        blurb.textColor = .secondaryLabelColor

        let site = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("site"))
        site.title = "Website"
        site.width = 260
        let kinds = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("kinds"))
        kinds.title = "Data"
        kinds.width = 200
        table.addTableColumn(site)
        table.addTableColumn(kinds)
        table.rowHeight = 24
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 240).isActive = true

        removeButton.target = self
        removeButton.action = #selector(removeSelected)
        removeButton.bezelStyle = .rounded
        removeButton.isEnabled = false
        removeAllButton.target = self
        removeAllButton.action = #selector(removeAll)
        removeAllButton.bezelStyle = .rounded
        let done = NSButton(title: "Done", target: self, action: #selector(dismissSheet))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        let footer = NSStackView(views: [removeButton, removeAllButton, status, NSView(), done])
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [title, blurb, scroll, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            blurb.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        reload()
    }

    private func reload() {
        let identities = identities
        Task { [weak self] in
            let records = await WebsiteData.records(for: identities)
            guard let self else { return }
            self.records = records
            table.reloadData()
            status.stringValue = records.isEmpty ? "No website data." : (records.count == 1 ? "1 website" : "\(records.count) websites")
            removeAllButton.isEnabled = !records.isEmpty
        }
    }

    @objc private func removeSelected() {
        let chosen = table.selectedRowIndexes.compactMap { records.indices.contains($0) ? records[$0] : nil }
        guard !chosen.isEmpty else { return }
        status.stringValue = "Removing\u{2026}"
        Task { [weak self] in
            await WebsiteData.remove(chosen)
            self?.reload()
        }
    }

    @objc private func removeAll() {
        let identities = identities
        status.stringValue = "Removing\u{2026}"
        Task { [weak self] in
            await WebsiteData.removeAll(for: identities)
            self?.reload()
        }
    }

    @objc private func dismissSheet() { dismiss(nil) }
}

extension WebsiteDataViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { records.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard records.indices.contains(row) else { return nil }
        let record = records[row]
        let text = tableColumn?.identifier.rawValue == "site" ? record.displayName : WebsiteData.describe(record.types)
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        let cell = NSTableCellView()
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton.isEnabled = !table.selectedRowIndexes.isEmpty
    }
}

// MARK: - The card

/// A grouped card of rows with a hairline between each, as macOS System
/// Settings draws its groups.
@MainActor
final class SettingsCardView: NSView {
    init(rows: [NSView]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        var views: [NSView] = []
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let line = NSBox()
                line.boxType = .separator
                line.translatesAutoresizingMaskIntoConstraints = false
                views.append(line)
            }
            views.append(row)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        for view in views {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsCardView is created in code only")
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
    }
}

/// A coloured tile with a glyph, a title, and a control at the trailing edge.
@MainActor
final class SettingsSwitchRow: NSView {
    enum Tile {
        case symbol(String, NSColor)
        case emoji(String, NSColor)
    }

    /// A tile on its own, for lists that want the same glyph-on-colour.
    static func tileView(_ tile: Tile, side: CGFloat = 26) -> NSView {
        TileView(tile: tile, side: side)
    }

    init(tile: Tile, title: String, control: NSControl) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let tileView = TileView(tile: tile, side: 26)
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        control.translatesAutoresizingMaskIntoConstraints = false
        control.setAccessibilityLabel(title)

        let stack = NSStackView(views: [tileView, label, NSView(), control])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 44),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsSwitchRow is created in code only")
    }

    private final class TileView: NSView {
        private let tile: Tile

        init(tile: Tile, side: CGFloat) {
            self.tile = tile
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                widthAnchor.constraint(equalToConstant: side),
                heightAnchor.constraint(equalToConstant: side)
            ])
            setAccessibilityElement(false)
        }

        required init?(coder: NSCoder) {
            fatalError("TileView is created in code only")
        }

        override func draw(_ dirtyRect: NSRect) {
            let colour: NSColor
            switch tile {
            case .symbol(_, let c), .emoji(_, let c): colour = c
            }
            colour.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()

            switch tile {
            case .symbol(let name, _):
                guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold)) else { return }
                let tinted = image.copy() as! NSImage
                tinted.isTemplate = true
                let size = tinted.size
                let origin = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
                NSColor.white.set()
                tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
                // Template images draw black; paint white through the mask.
                NSGraphicsContext.saveGraphicsState()
                let rect = NSRect(origin: origin, size: size)
                tinted.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
                NSColor.white.setFill()
                rect.fill(using: .sourceAtop)
                NSGraphicsContext.restoreGraphicsState()
            case .emoji(let text, _):
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15)]
                let size = (text as NSString).size(withAttributes: attributes)
                (text as NSString).draw(
                    at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                    withAttributes: attributes
                )
            }
        }
    }
}
