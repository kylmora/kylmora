import AppKit
import UniformTypeIdentifiers

/// The Extensions pane: what is installed, a switch and a Remove for each,
/// and an Install button that takes a folder, a `.zip` or a `.crx`.
@MainActor
final class ExtensionsSettingsViewController: NSViewController {
    private let settings: Settings
    private let listStack = NSStackView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let storeField = NSTextField()
    private let storeButton = NSButton(title: "Install", target: nil, action: nil)
    private let firefoxField = NSTextField()
    private let firefoxButton = NSButton(title: "Install", target: nil, action: nil)
    private var storeRow: SettingsFormRow?
    private var firefoxRow: SettingsFormRow?
    /// The native messaging part of the pane.
    private let nativeMessagingBox = NSButton(checkboxWithTitle: "Let extensions talk to apps on this Mac",
                                              target: nil, action: nil)
    private let borrowedHostsBox = NSButton(checkboxWithTitle: "Include apps that set themselves up for another browser",
                                            target: nil, action: nil)
    private let hostStack = NSStackView()
    /// The switch on each row of the two lists this pane builds itself.
    ///
    /// Kept so their observers can be let go before a list is built again: a
    /// form tears down the switches it made, and these are not the form's.
    private var extensionSwitches: [SettingsSwitchAdaptor] = []
    private var hostSwitches: [SettingsSwitchAdaptor] = []

    init(settings: Settings = .shared) {
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("ExtensionsSettingsViewController is created in code only")
    }

    /// The Advanced pane's switches decide which sources are shown.
    override func viewWillAppear() {
        super.viewWillAppear()
        storeRow?.isHidden = !settings.allowsChromeExtensions
        firefoxRow?.isHidden = !settings.allowsFirefoxExtensions
        nativeMessagingBox.state = settings.nativeMessagingEnabled ? .on : .off
        borrowedHostsBox.state = settings.nativeMessagingUsesOtherBrowsers ? .on : .off
        borrowedHostsBox.isEnabled = settings.nativeMessagingEnabled
        // An app can be installed while this window is open, so the list is
        // read again every time the pane is shown rather than once at launch.
        reloadHosts()
    }

    override func loadView() {
        let form = SettingsForm()
        view = form
        buildLayout(in: form)
        if #available(macOS 15.4, *) {
            ExtensionManager.shared.onChange = { [weak self] in self?.reload() }
        }
        reload()
    }

    private func buildLayout(in form: SettingsForm) {
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 8
        form.addRow("Installed", SettingsForm.fill(listStack))
        form.addNote("Kylmora runs extensions on WebKit's own extension engine, the one Safari uses. It reads the "
            + "manifest format Chrome extensions are written in, so most Chrome extensions load as they are. "
            + "One that depends on an API Safari does not have will say so here.")

        form.addSeparator()

        storeField.placeholderString = "Paste a Chrome Web Store link or extension ID"
        storeField.target = self
        storeField.action = #selector(storeInstallTapped)
        storeButton.target = self
        storeButton.action = #selector(storeInstallTapped)
        storeButton.bezelStyle = .rounded
        storeButton.keyEquivalent = "\r"
        storeButton.setAccessibilityLabel("Install from the Chrome Web Store")
        storeField.translatesAutoresizingMaskIntoConstraints = false
        // No width of its own: the row gives it what is left after the button,
        // and a link pasted into 210 points is a link you cannot read.
        storeField.setContentHuggingPriority(.init(1), for: .horizontal)
        storeRow = form.addRow("Chrome Web Store", [storeField, storeButton])

        firefoxField.placeholderString = "Paste an addons.mozilla.org link"
        firefoxField.target = self
        firefoxField.action = #selector(firefoxInstallTapped)
        firefoxButton.target = self
        firefoxButton.action = #selector(firefoxInstallTapped)
        firefoxButton.bezelStyle = .rounded
        firefoxButton.setAccessibilityLabel("Install from Firefox Add-ons")
        firefoxField.translatesAutoresizingMaskIntoConstraints = false
        firefoxField.setContentHuggingPriority(.init(1), for: .horizontal)
        firefoxRow = form.addRow("Firefox Add-ons", [firefoxField, firefoxButton])

        let install = NSButton(title: "Install from a File\u{2026}", target: self, action: #selector(installTapped))
        install.bezelStyle = .rounded
        form.addRow("Package", install)
        form.addNote(statusLabel)

        form.addSeparator()
        form.addSection("Apps on this Mac")
        nativeMessagingBox.target = self
        nativeMessagingBox.action = #selector(nativeMessagingFlipped)
        form.addRow("Native messaging", nativeMessagingBox)
        form.addNote("A password manager's extension is a front end; the vault is in the app. Native messaging is "
            + "how the two talk, and an extension cannot start a program itself, so Kylmora does it -- but only for "
            + "an app that installed a manifest naming that extension, and only if the extension asked for the "
            + "permission.")

        borrowedHostsBox.target = self
        borrowedHostsBox.action = #selector(borrowedHostsFlipped)
        form.addContinuation(borrowedHostsBox)
        form.addNote("Almost no app ships a manifest for Kylmora; they ship Chrome's and Firefox's. Reading those "
            + "folders is what makes 1Password, Bitwarden and iCloud Passwords work the day they are installed. "
            + "The app's own manifest still decides which extensions may reach it.")

        hostStack.orientation = .vertical
        hostStack.alignment = .leading
        hostStack.spacing = 8
        form.addRow("Apps found", SettingsForm.fill(hostStack))

        if #unavailable(macOS 15.4) {
            install.isEnabled = false
            storeField.isEnabled = false
            storeButton.isEnabled = false
            firefoxField.isEnabled = false
            firefoxButton.isEnabled = false
            statusLabel.stringValue = "Extensions need macOS 15.4 or later, where WebKit's extension engine became available."
        }
    }

    private func reload() {
        for adaptor in extensionSwitches { adaptor.stop() }
        extensionSwitches = []
        for view in listStack.arrangedSubviews {
            listStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard #available(macOS 15.4, *) else { return }
        let entries = ExtensionManager.shared.entries
        if entries.isEmpty {
            let empty = NSTextField(labelWithString: "No extensions installed.")
            empty.textColor = .secondaryLabelColor
            listStack.addArrangedSubview(empty)
            return
        }
        let rows = entries.map { makeRow($0) }
        let card = SettingsCardView(rows: rows)
        listStack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
    }

    @available(macOS 15.4, *)
    private func makeRow(_ entry: ExtensionManager.Entry) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView(image: entry.icon
            ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)!)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setAccessibilityElement(false)

        let title = NSTextField(labelWithString: entry.displayVersion.isEmpty
            ? entry.displayName : "\(entry.displayName)  \(entry.displayVersion)")
        title.font = .systemFont(ofSize: 13)
        var summary = entry.summary
        if entry.record.storeID != nil {
            summary = summary.isEmpty ? "From the Chrome Web Store." : summary + " From the Chrome Web Store."
        } else if entry.record.firefoxSlug != nil {
            summary = summary.isEmpty ? "From Firefox Add-ons." : summary + " From Firefox Add-ons."
        }
        let detail = NSTextField(wrappingLabelWithString: entry.problems.isEmpty
            ? summary
            : entry.problems.joined(separator: " "))
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = entry.problems.isEmpty ? .secondaryLabelColor : .systemRed
        detail.maximumNumberOfLines = 2
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false

        // Ours, not AppKit's: an installed extension used to put a stock blue
        // switch on a page where every other control is this app's own.
        let checkbox = NSButton(checkboxWithTitle: "\(entry.displayName) enabled", target: self,
                                action: #selector(toggled(_:)))
        checkbox.state = entry.record.isEnabled ? .on : .off
        checkbox.identifier = NSUserInterfaceItemIdentifier(entry.id.uuidString)
        let adaptor = SettingsSwitchAdaptor(checkbox: checkbox)
        extensionSwitches.append(adaptor)
        let toggle = adaptor.control

        let remove = NSButton(title: "Remove", target: self, action: #selector(removeTapped(_:)))
        remove.bezelStyle = .rounded
        remove.controlSize = .small
        remove.identifier = NSUserInterfaceItemIdentifier(entry.id.uuidString)

        let stack = NSStackView(views: [icon, text, NSView(), toggle, remove])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
            stack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: row.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -8),
            detail.widthAnchor.constraint(lessThanOrEqualToConstant: 360)
        ])
        return row
    }

    // MARK: - Native messaging

    @objc private func nativeMessagingFlipped() {
        settings.nativeMessagingEnabled = nativeMessagingBox.state == .on
        borrowedHostsBox.isEnabled = settings.nativeMessagingEnabled
        if #available(macOS 15.4, *), !settings.nativeMessagingEnabled {
            // Switching it off stops what is already running, not only what
            // would start next.
            NativeMessagingService.shared.disconnectAll()
        }
        reloadHosts()
    }

    @objc private func borrowedHostsFlipped() {
        settings.nativeMessagingUsesOtherBrowsers = borrowedHostsBox.state == .on
        reloadHosts()
    }

    private func reloadHosts() {
        guard #available(macOS 15.4, *) else { return }
        Task { @MainActor in
            let scan = await NativeMessagingService.shared.scan(refreshing: true)
            showHosts(scan)
        }
    }

    @available(macOS 15.4, *)
    private func showHosts(_ scan: NativeMessagingHostRegistry.Scan) {
        for adaptor in hostSwitches { adaptor.stop() }
        hostSwitches = []
        for view in hostStack.arrangedSubviews {
            hostStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard !scan.hosts.isEmpty || !scan.rejections.isEmpty else {
            let empty = NSTextField(labelWithString: "No app on this Mac has asked to be reachable.")
            empty.textColor = .secondaryLabelColor
            hostStack.addArrangedSubview(empty)
            return
        }
        var rows: [NSView] = scan.hosts.map { makeHostRow($0) }
        rows += scan.rejections.map { makeRejectionRow($0) }
        let card = SettingsCardView(rows: rows)
        hostStack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: hostStack.widthAnchor).isActive = true
    }

    @available(macOS 15.4, *)
    private func makeHostRow(_ host: NativeMessagingHost) -> NSView {
        let title = NSTextField(labelWithString: host.name)
        title.font = .systemFont(ofSize: 13)
        var lines: [String] = []
        if !host.summary.isEmpty { lines.append(host.summary) }
        lines.append("From \(host.directory.label) \u{00b7} \(host.executable.path(percentEncoded: false))")
        let detail = NSTextField(wrappingLabelWithString: lines.joined(separator: "\n"))
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 3

        // The pane's own switch, not AppKit's: every other control in this
        // window is one of ours, and a stock blue tick beside them would show.
        let checkbox = NSButton(checkboxWithTitle: "\(host.name) allowed", target: self,
                                action: #selector(hostToggled(_:)))
        checkbox.state = NativeMessagingService.shared.isBlocked(host.name) ? .off : .on
        checkbox.identifier = NSUserInterfaceItemIdentifier(host.name)
        let adaptor = SettingsSwitchAdaptor(checkbox: checkbox)
        hostSwitches.append(adaptor)
        return makeCardRow(title: title, detail: detail, trailing: adaptor.control)
    }

    @available(macOS 15.4, *)
    private func makeRejectionRow(_ rejection: NativeMessagingHostRegistry.Rejection) -> NSView {
        let title = NSTextField(labelWithString: rejection.manifestURL.deletingPathExtension().lastPathComponent)
        title.font = .systemFont(ofSize: 13)
        // Said plainly rather than hidden: a manifest Kylmora will not run is
        // the reason an extension is about to look broken.
        let detail = NSTextField(wrappingLabelWithString: "Not used. \(rejection.reason)")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .systemRed
        detail.maximumNumberOfLines = 3
        return makeCardRow(title: title, detail: detail, trailing: nil)
    }

    private func makeCardRow(title: NSTextField, detail: NSTextField, trailing: NSView?) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false
        var views: [NSView] = [text, NSView()]
        if let trailing { views.append(trailing) }
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: row.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -8),
            detail.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
        return row
    }

    @objc private func hostToggled(_ sender: NSButton) {
        guard #available(macOS 15.4, *), let name = sender.identifier?.rawValue else { return }
        NativeMessagingService.shared.setBlocked(sender.state == .off, hostName: name)
    }

    @objc private func toggled(_ sender: NSButton) {
        guard #available(macOS 15.4, *), let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }) else { return }
        ExtensionManager.shared.setEnabled(sender.state == .on, for: id)
    }

    @objc private func removeTapped(_ sender: NSButton) {
        guard #available(macOS 15.4, *), let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }),
              let entry = ExtensionManager.shared.entries.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \u{201c}\(entry.displayName)\u{201d}?"
        alert.informativeText = "Its files and anything it stored are deleted."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ExtensionManager.shared.remove(id)
    }

    @objc private func storeInstallTapped() {
        guard #available(macOS 15.4, *) else { return }
        let input = storeField.stringValue
        guard ChromeWebStore.extensionID(from: input) != nil else {
            statusLabel.stringValue = "That is not a Chrome Web Store link or extension ID."
            return
        }
        storeButton.isEnabled = false
        statusLabel.stringValue = "Downloading from the Chrome Web Store\u{2026}"
        Task { [weak self] in
            defer { self?.storeButton.isEnabled = true }
            do {
                let record = try await ExtensionManager.shared.install(fromChromeWebStore: input)
                self?.storeField.stringValue = ""
                self?.statusLabel.stringValue = "Installed \(record.name)."
            } catch {
                self?.statusLabel.stringValue = "Could not install: \(Self.describe(error))"
            }
            self?.reload()
        }
    }

    @objc private func firefoxInstallTapped() {
        guard #available(macOS 15.4, *) else { return }
        let input = firefoxField.stringValue
        guard FirefoxAddons.slug(from: input) != nil else {
            statusLabel.stringValue = "That is not an addons.mozilla.org link."
            return
        }
        firefoxButton.isEnabled = false
        statusLabel.stringValue = "Downloading from addons.mozilla.org\u{2026}"
        Task { [weak self] in
            defer { self?.firefoxButton.isEnabled = true }
            do {
                let record = try await ExtensionManager.shared.install(fromFirefoxAddons: input)
                self?.firefoxField.stringValue = ""
                self?.statusLabel.stringValue = "Installed \(record.name)."
            } catch {
                self?.statusLabel.stringValue = "Could not install: \(Self.describe(error))"
            }
            self?.reload()
        }
    }

    @objc private func installTapped() {
        guard #available(macOS 15.4, *) else { return }
        let panel = NSOpenPanel()
        panel.title = "Install Extension"
        panel.message = "Choose an extension package (.zip or .crx) or its unpacked folder."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        var types: [UTType] = [.zip]
        if settings.allowsChromeExtensions, let crx = UTType(filenameExtension: "crx") { types.append(crx) }
        if settings.allowsFirefoxExtensions, let xpi = UTType(filenameExtension: "xpi") { types.append(xpi) }
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK, let url = panel.url else { return }

        statusLabel.stringValue = "Installing\u{2026}"
        Task { [weak self] in
            do {
                let record = try await ExtensionManager.shared.install(from: url)
                self?.statusLabel.stringValue = "Installed \(record.name)."
            } catch {
                self?.statusLabel.stringValue = "Could not install: \(Self.describe(error))"
            }
            self?.reload()
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error as? FirefoxAddons.Failure {
        case .notAnAddonLink: return "that is not an addons.mozilla.org link."
        case .notFound: return "the add-on site has no add-on by that name."
        case .noPackage: return "the add-on site listed no package to download."
        case .transport(let message): return message
        case nil: break
        }
        switch error as? ChromeWebStore.Failure {
        case .notAStoreLink: return "that is not a Chrome Web Store link or extension ID."
        case .notFound: return "the store has no extension with that ID."
        case .notAPackage: return "the store did not return an extension package. It may be unlisted, or the store may have changed."
        case .transport(let message): return message
        case nil: break
        }
        switch error as? ExtensionPackage.Failure {
        case .unreadable: return "the file could not be read."
        case .notAPackage: return "that is not a .zip, a .crx, or a folder."
        case .noManifest: return "no manifest.json was found inside."
        case .unpackFailed(let message): return "the package could not be unpacked. \(message)"
        case nil: return error.localizedDescription
        }
    }
}
