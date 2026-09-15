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
    private let clearOnQuitCheckbox = NSButton(checkboxWithTitle: "Clear website data on quit except allow-list", target: nil, action: nil)
    private let manageAllowlistButton = NSButton(title: "Manage Allow-List\u{2026}", target: nil, action: nil)
    private let lockEnabledCheckbox = NSButton(checkboxWithTitle: "Require authentication to unlock Kylmora", target: nil, action: nil)
    private let lockMethodPopUp = NSPopUpButton()
    private let masterPasswordButton = NSButton(title: "Set Master Password\u{2026}", target: nil, action: nil)
    private let lockOnLaunchCheckbox = NSButton(checkboxWithTitle: "Lock immediately on launch", target: nil, action: nil)
    private let idleTimeoutPopUp = NSPopUpButton()
    private let lockNowButton = NSButton(title: "Lock Browser Now", target: nil, action: nil)
    private let antiFingerprintingCheckbox = NSButton(checkboxWithTitle: "Enable anti-fingerprinting protection", target: nil, action: nil)
    private let canvasNoiseCheckbox = NSButton(checkboxWithTitle: "Randomize Canvas and WebGL pixel readouts", target: nil, action: nil)
    private let audioNoiseCheckbox = NSButton(checkboxWithTitle: "Mask AudioContext acoustic signatures", target: nil, action: nil)
    private let hardwareMaskingCheckbox = NSButton(checkboxWithTitle: "Standardize hardware concurrency and memory", target: nil, action: nil)

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
        // Each group under a heading of its own, one setting to a row. The
        // switches and radios used to be handed over in stacks, which drew
        // them down the left of the card with the text after them -- a second
        // design on the same page as the rows above.
        form.addSection("Tracking and history")
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
        form.addRow("", disableHistory)

        form.addSection("Website data")
        let reset = NSButton(title: "Reset Kylmora\u{2026}", target: self, action: #selector(resetTapped))
        reset.bezelStyle = .rounded
        let manage = NSButton(title: "Manage Website Data\u{2026}", target: self, action: #selector(manageWebsiteData))
        manage.bezelStyle = .rounded
        form.addRow("Cookies and website data", [manage, reset])

        clearOnQuitCheckbox.target = self
        clearOnQuitCheckbox.action = #selector(clearOnQuitChanged)
        manageAllowlistButton.target = self
        manageAllowlistButton.action = #selector(manageAllowlist)
        manageAllowlistButton.bezelStyle = .rounded
        let quitRow = NSStackView(views: [clearOnQuitCheckbox, manageAllowlistButton])
        quitRow.orientation = .horizontal
        quitRow.spacing = 8
        form.addRow("", quitRow)
        form.addNote("Deletes cookies, cache, and storage for all websites when Kylmora quits, except sites on your allow-list.")

        form.addSection("Crash reports")
        for radio in [crashAsk, crashAlways, crashNever] {
            radio.target = self
            radio.action = #selector(crashPolicyChanged)
            form.addRow("", radio)
        }

        form.addSection("User agent")
        userAgentField.placeholderString = "Mozilla/5.0 \u{2026}"
        userAgentField.target = self
        userAgentField.action = #selector(userAgentCommitted)
        form.addRow("\u{201c}Custom\u{201d} user agent", SettingsForm.fill(userAgentField))
        form.addNote("Used when \u{201c}Custom\u{201d} is chosen for a site's user agent in Website Settings.")

        form.addSection("Fingerprinting")
        for box in [antiFingerprintingCheckbox, canvasNoiseCheckbox, audioNoiseCheckbox, hardwareMaskingCheckbox] {
            box.target = self
            box.action = #selector(antiFingerprintingChanged)
            form.addRow("", box)
        }
        form.addNote("Prevents tracking scripts from fingerprinting your device through Canvas, WebGL, AudioContext, or hardware specs. Each Space uses independent seeded noise.")

        form.addSection("Content blocker")
        for (control, selector) in [
            (adsSwitch, #selector(adsChanged)),
            (cookiesSwitch, #selector(cookieBannersChanged)),
            (trackersSwitch, #selector(trackerListsChanged))
        ] {
            control.target = self
            control.action = selector
        }
        // On the group's own card, not on a plate of their own inside it.
        form.addRows([
            SettingsSwitchRow(tile: .symbol("hand.raised.fill", .systemRed), title: "Block ads", control: adsSwitch),
            SettingsSwitchRow(tile: .emoji("\u{1F36A}", .systemOrange), title: "Block cookie banners", control: cookiesSwitch),
            SettingsSwitchRow(tile: .symbol("eyeglasses", .systemYellow), title: "Block trackers", control: trackersSwitch)
        ])

        autoUpdate.target = self
        autoUpdate.action = #selector(autoUpdateChanged)
        form.addRow("", autoUpdate)
        updateButton.target = self
        updateButton.action = #selector(updateNow)
        updateButton.bezelStyle = .rounded
        let manageLists = NSButton(title: "Manage Filter Lists\u{2026}", target: self, action: #selector(showAdvanced))
        manageLists.bezelStyle = .rounded
        // What is in force, with the buttons that change it beside it.
        rulesLabel.lineBreakMode = .byTruncatingTail
        form.addRow(rulesLabel, [updateButton, manageLists])
        form.addNote(updatedLabel)
        form.addNote(statusLabel)

        form.addSection("Browser lock")
        lockEnabledCheckbox.target = self
        lockEnabledCheckbox.action = #selector(lockEnabledChanged)
        form.addRow("", lockEnabledCheckbox)

        lockMethodPopUp.addItems(withTitles: BrowserLockMethod.allCases.map(\.title))
        lockMethodPopUp.target = self
        lockMethodPopUp.action = #selector(lockMethodChanged)
        masterPasswordButton.bezelStyle = .rounded
        masterPasswordButton.target = self
        masterPasswordButton.action = #selector(setMasterPasswordTapped)
        form.addRow("Unlock with", [lockMethodPopUp, masterPasswordButton])

        lockOnLaunchCheckbox.target = self
        lockOnLaunchCheckbox.action = #selector(lockOnLaunchChanged)
        form.addRow("", lockOnLaunchCheckbox)

        idleTimeoutPopUp.addItems(withTitles: BrowserLockIdleTimeout.allCases.map(\.title))
        idleTimeoutPopUp.target = self
        idleTimeoutPopUp.action = #selector(idleTimeoutChanged)
        form.addRow("Auto-lock after", SettingsForm.fill(idleTimeoutPopUp))

        lockNowButton.bezelStyle = .rounded
        lockNowButton.target = self
        lockNowButton.action = #selector(lockNowTapped)
        form.addContinuation(lockNowButton)
        form.addNote("Obscures tabs and web content behind a blur shield when locked. Unlock using Touch ID, system passcode, or your master password.")
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
        clearOnQuitCheckbox.state = settings.clearWebsiteDataOnQuit ? .on : .off

        lockEnabledCheckbox.state = settings.browserLockEnabled ? .on : .off
        lockMethodPopUp.selectItem(at: BrowserLockMethod.allCases.firstIndex(of: settings.browserLockMethod) ?? 0)
        masterPasswordButton.title = MasterPasswordStore.hasMasterPassword() ? "Change Master Password\u{2026}" : "Set Master Password\u{2026}"
        masterPasswordButton.isHidden = settings.browserLockMethod != .masterPassword
        lockOnLaunchCheckbox.state = settings.browserLockOnLaunch ? .on : .off
        idleTimeoutPopUp.selectItem(at: BrowserLockIdleTimeout.allCases.firstIndex(of: settings.browserLockIdleTimeout) ?? 0)

        lockOnLaunchCheckbox.isEnabled = settings.browserLockEnabled
        lockMethodPopUp.isEnabled = settings.browserLockEnabled
        masterPasswordButton.isEnabled = settings.browserLockEnabled
        idleTimeoutPopUp.isEnabled = settings.browserLockEnabled

        antiFingerprintingCheckbox.state = settings.antiFingerprintingEnabled ? .on : .off
        canvasNoiseCheckbox.state = settings.canvasNoiseEnabled ? .on : .off
        audioNoiseCheckbox.state = settings.audioNoiseEnabled ? .on : .off
        hardwareMaskingCheckbox.state = settings.hardwareMaskingEnabled ? .on : .off

        let fpActive = settings.antiFingerprintingEnabled
        canvasNoiseCheckbox.isEnabled = fpActive
        audioNoiseCheckbox.isEnabled = fpActive
        hardwareMaskingCheckbox.isEnabled = fpActive

        reloadStatus()
    }

    @objc private func antiFingerprintingChanged() {
        settings.antiFingerprintingEnabled = antiFingerprintingCheckbox.state == .on
        settings.canvasNoiseEnabled = canvasNoiseCheckbox.state == .on
        settings.audioNoiseEnabled = audioNoiseCheckbox.state == .on
        settings.hardwareMaskingEnabled = hardwareMaskingCheckbox.state == .on
        let fpActive = settings.antiFingerprintingEnabled
        canvasNoiseCheckbox.isEnabled = fpActive
        audioNoiseCheckbox.isEnabled = fpActive
        hardwareMaskingCheckbox.isEnabled = fpActive
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

    @objc private func clearOnQuitChanged() {
        settings.clearWebsiteDataOnQuit = clearOnQuitCheckbox.state == .on
    }

    @objc private func manageAllowlist() {
        let sheet = WebsiteDataAllowlistViewController(settings: settings, session: session)
        presentAsSheet(sheet)
    }

    @objc private func lockEnabledChanged() {
        let willEnable = lockEnabledCheckbox.state == .on
        if willEnable && settings.browserLockMethod == .masterPassword && !MasterPasswordStore.hasMasterPassword() {
            promptSetMasterPassword(onSuccess: { [weak self] in
                self?.settings.browserLockEnabled = true
                self?.reload()
            }, onCancel: { [weak self] in
                self?.lockEnabledCheckbox.state = .off
                self?.settings.browserLockEnabled = false
                self?.reload()
            })
            return
        }
        settings.browserLockEnabled = willEnable
        reload()
    }

    @objc private func lockMethodChanged() {
        guard BrowserLockMethod.allCases.indices.contains(lockMethodPopUp.indexOfSelectedItem) else { return }
        let method = BrowserLockMethod.allCases[lockMethodPopUp.indexOfSelectedItem]
        settings.browserLockMethod = method
        if method == .masterPassword && !MasterPasswordStore.hasMasterPassword() {
            promptSetMasterPassword(onSuccess: { [weak self] in
                self?.reload()
            }, onCancel: { [weak self] in
                self?.reload()
            })
        } else {
            reload()
        }
    }

    @objc private func lockOnLaunchChanged() {
        settings.browserLockOnLaunch = lockOnLaunchCheckbox.state == .on
    }

    @objc private func idleTimeoutChanged() {
        guard BrowserLockIdleTimeout.allCases.indices.contains(idleTimeoutPopUp.indexOfSelectedItem) else { return }
        settings.browserLockIdleTimeout = BrowserLockIdleTimeout.allCases[idleTimeoutPopUp.indexOfSelectedItem]
    }

    @objc private func lockNowTapped() {
        BrowserLockManager.shared.lock(animated: true)
    }

    @objc private func setMasterPasswordTapped() {
        promptSetMasterPassword(onSuccess: { [weak self] in
            self?.reload()
        })
    }

    private func promptSetMasterPassword(onSuccess: (() -> Void)? = nil, onCancel: (() -> Void)? = nil) {
        let isChanging = MasterPasswordStore.hasMasterPassword()
        let alert = NSAlert()
        alert.messageText = isChanging ? "Change Master Password" : "Set Master Password"
        alert.informativeText = isChanging
            ? "Enter your current master password and choose a new one."
            : "Create a master password to protect Kylmora."
        alert.addButton(withTitle: isChanging ? "Change Password" : "Set Password")
        alert.addButton(withTitle: "Cancel")

        let currentField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        currentField.placeholderString = "Current Password"

        let newField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        newField.placeholderString = "New Password"

        let confirmField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        confirmField.placeholderString = "Confirm Password"

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        stack.alignment = .leading
        if isChanging {
            stack.addArrangedSubview(currentField)
        }
        stack.addArrangedSubview(newField)
        stack.addArrangedSubview(confirmField)
        stack.setFrameSize(NSSize(width: 240, height: isChanging ? 96 : 64))

        alert.accessoryView = stack

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if isChanging {
                guard MasterPasswordStore.verifyMasterPassword(currentField.stringValue) else {
                    let errAlert = NSAlert()
                    errAlert.alertStyle = .critical
                    errAlert.messageText = "Incorrect Current Password"
                    errAlert.informativeText = "The current master password you entered was incorrect."
                    errAlert.runModal()
                    onCancel?()
                    return
                }
            }

            let newPass = newField.stringValue
            guard !newPass.isEmpty else {
                let errAlert = NSAlert()
                errAlert.alertStyle = .warning
                errAlert.messageText = "Empty Password"
                errAlert.informativeText = "Master password cannot be empty."
                errAlert.runModal()
                onCancel?()
                return
            }

            guard newPass == confirmField.stringValue else {
                let errAlert = NSAlert()
                errAlert.alertStyle = .warning
                errAlert.messageText = "Passwords Do Not Match"
                errAlert.informativeText = "The entered passwords do not match. Please try again."
                errAlert.runModal()
                onCancel?()
                return
            }

            MasterPasswordStore.setMasterPassword(newPass)
            onSuccess?()
        } else {
            onCancel?()
        }
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
    private let addToAllowlistButton = NSButton(title: "Add to Allow-List", target: nil, action: nil)
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
        addToAllowlistButton.target = self
        addToAllowlistButton.action = #selector(addToAllowlist)
        addToAllowlistButton.bezelStyle = .rounded
        addToAllowlistButton.isEnabled = false
        let done = NSButton(title: "Done", target: self, action: #selector(dismissSheet))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        let footer = NSStackView(views: [removeButton, removeAllButton, addToAllowlistButton, status, NSView(), done])
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

    @objc private func addToAllowlist() {
        let chosen = table.selectedRowIndexes.compactMap { records.indices.contains($0) ? records[$0] : nil }
        for record in chosen {
            Settings.shared.addToQuitAllowlist(record.displayName)
        }
        status.stringValue = "Added \(chosen.count) site\(chosen.count == 1 ? "" : "s") to allow-list."
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
        addToAllowlistButton.isEnabled = !table.selectedRowIndexes.isEmpty
    }
}
