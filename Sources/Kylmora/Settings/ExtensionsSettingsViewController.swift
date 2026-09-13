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
    private var storeRow: NSGridRow?
    private var firefoxRow: NSGridRow?

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
        storeField.widthAnchor.constraint(equalToConstant: SettingsForm.controlWidth - 70).isActive = true
        storeRow = form.addRow("Chrome Web Store", [storeField, storeButton])

        firefoxField.placeholderString = "Paste an addons.mozilla.org link"
        firefoxField.target = self
        firefoxField.action = #selector(firefoxInstallTapped)
        firefoxButton.target = self
        firefoxButton.action = #selector(firefoxInstallTapped)
        firefoxButton.bezelStyle = .rounded
        firefoxButton.setAccessibilityLabel("Install from Firefox Add-ons")
        firefoxField.translatesAutoresizingMaskIntoConstraints = false
        firefoxField.widthAnchor.constraint(equalToConstant: SettingsForm.controlWidth - 70).isActive = true
        firefoxRow = form.addRow("Firefox Add-ons", [firefoxField, firefoxButton])

        let install = NSButton(title: "Install from a File\u{2026}", target: self, action: #selector(installTapped))
        install.bezelStyle = .rounded
        form.addRow("Package", install)
        form.addNote(statusLabel)

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

        let toggle = NSSwitch()
        toggle.state = entry.record.isEnabled ? .on : .off
        toggle.identifier = NSUserInterfaceItemIdentifier(entry.id.uuidString)
        toggle.target = self
        toggle.action = #selector(toggled(_:))
        toggle.setAccessibilityLabel("\(entry.displayName) enabled")

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

    @objc private func toggled(_ sender: NSSwitch) {
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
