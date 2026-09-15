import AppKit

/// The About pane: the logo and version over what the browser is, who makes
/// it, what the mark means, and a button that asks kylmora.com whether this
/// is the newest version.
///
/// The standard About panel shows an icon and a version and nothing else.
/// This pane is where the story goes, and it is a pane rather than a panel so
/// the update check has somewhere to put its answer.
@MainActor
final class AboutSettingsViewController: NSViewController {
    /// The copy, in one place, so it can be edited without touching layout.
    enum Copy {
        static let tagline = "A lightweight native browser for the Mac."
        static let browser = """
            Kylmora is built on the WebKit that ships with macOS, the engine behind \
            Safari, so pages render the way the system expects and web content stays \
            in WebKit's own sandboxed processes. The app around it is written in \
            Swift with AppKit: one window, Spaces that keep their own identities, \
            tabs that cost nothing until you look at them, and browsing tools \
            designed with AI agents in mind.
            """
        static let aboutUs = """
            Kylmora is made independently, by people who wanted a browser that is \
            fast, honest and quiet. Nothing in it is a mock: if a control is there, \
            it does something. Nothing phones home: there is no telemetry, crash \
            reports stay on your Mac unless you choose otherwise, and the browser \
            contains no third-party code. It is built by hand, one decision at a \
            time, and every decision is written down.
            """
        static let logo = """
            The mark is a K drawn as two ribbons of blue: an upright stem, and one \
            sweeping stroke that folds over it to make both arms. It reads as a \
            letter at a glance and as a fold of paper on a second look, which is \
            the browser in a shape: simple on the surface, with more underneath.
            """
        static let copyright = "© 2026 Kylmora"
    }

    private let autoCheckCheckbox = NSButton(checkboxWithTitle: "Automatically check for updates", target: nil, action: nil)
    private let autoDownloadCheckbox = NSButton(checkboxWithTitle: "Automatically download updates", target: nil, action: nil)
    private let checkButton = NSButton(title: "Check for Updates\u{2026}", target: nil, action: nil)
    private let downloadButton = NSButton(title: "Update Now", target: nil, action: nil)
    private let updateStatus = NSTextField(wrappingLabelWithString: "")
    private var checking = false
    private var downloadURL: URL?

    /// The check, replaceable so a test can answer without the network.
    var check: (String) async -> UpdateCheck.Outcome = { current in
        await UpdateCheck.run(current: current)
    }

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("AboutSettingsViewController is created in code only")
    }

    override func loadView() {
        let form = SettingsForm()
        view = SettingsScrollingPane(form: form)
        buildLayout(in: form)
    }

    private func buildLayout(in form: SettingsForm) {
        form.addHero(makeHero())
        form.addSeparator()

        form.addRow("Browser", Self.paragraph(Copy.browser), alignment: .top)
        form.addRow("Engine", Self.value("WebKit, the system's own, shared with Safari (security patches arrive with macOS updates)"))
        form.addRow("Built with", Self.value("Swift 6 and AppKit, with no third-party code"))
        form.addRow("Website", Self.link("kylmora.com", url: AppInfo.website))

        form.addSeparator()
        form.addRow("About us", Self.paragraph(Copy.aboutUs), alignment: .top)
        form.addRow("The logo", Self.paragraph(Copy.logo), alignment: .top)

        form.addSeparator()
        autoCheckCheckbox.state = Settings.shared.automaticallyCheckForUpdates ? .on : .off
        autoCheckCheckbox.target = self
        autoCheckCheckbox.action = #selector(autoCheckToggled(_:))
        if EnterprisePolicyManager.shared.isAutoUpdateForced {
            autoCheckCheckbox.state = .on
            autoCheckCheckbox.isEnabled = false
            autoCheckCheckbox.toolTip = "Mandatory automatic updates are enforced by your organization"
        }
        form.addRow("Updates", autoCheckCheckbox)

        autoDownloadCheckbox.state = Settings.shared.automaticallyDownloadUpdates ? .on : .off
        autoDownloadCheckbox.target = self
        autoDownloadCheckbox.action = #selector(autoDownloadToggled(_:))
        form.addRow("", autoDownloadCheckbox)

        checkButton.target = self
        checkButton.action = #selector(checkForUpdates)
        checkButton.bezelStyle = .rounded
        downloadButton.target = self
        downloadButton.action = #selector(download)
        downloadButton.bezelStyle = .rounded
        downloadButton.isHidden = true
        form.addRow("", [checkButton, downloadButton])
        updateStatus.stringValue = "Kylmora sends no telemetry during update checks. WebKit security patches arrive automatically with macOS updates."
        form.addNote(updateStatus)

        form.addSeparator()
        form.addRow("", Self.value(Copy.copyright, secondary: true))
    }

    /// The icon, the name, the tagline and the version, centred.
    private func makeHero() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 112),
            icon.heightAnchor.constraint(equalToConstant: 112)
        ])

        let name = NSTextField(labelWithString: AppInfo.name)
        name.font = .systemFont(ofSize: 26, weight: .semibold)
        name.alignment = .center

        let tagline = NSTextField(labelWithString: Copy.tagline)
        tagline.font = .systemFont(ofSize: 13)
        tagline.textColor = .secondaryLabelColor
        tagline.alignment = .center

        let version = NSTextField(labelWithString: "Version \(AppInfo.version) (\(AppInfo.build))")
        version.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        version.textColor = .tertiaryLabelColor
        version.alignment = .center

        let stack = NSStackView(views: [icon, name, tagline, version])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.setCustomSpacing(12, after: icon)
        stack.setCustomSpacing(10, after: tagline)
        return stack
    }

    private static func paragraph(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 12)
        field.translatesAutoresizingMaskIntoConstraints = false
        // No width of its own. A paragraph goes under its heading and runs the
        // width of the card; pinning it to the control column left two thirds
        // of the card empty beside every line.
        return field
    }

    private static func value(_ text: String, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        if secondary { field.textColor = .secondaryLabelColor }
        return field
    }

    private static func link(_ text: String, url: URL) -> NSTextField {
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .link: url, .foregroundColor: NSColor.linkColor
        ])
        let field = NSTextField(labelWithAttributedString: attributed)
        field.allowsEditingTextAttributes = true
        field.isSelectable = true
        return field
    }

    // MARK: - Updates

    @objc private func checkForUpdates() {
        guard !checking else { return }
        checking = true
        checkButton.isEnabled = false
        downloadButton.isHidden = true
        downloadURL = nil
        release = nil
        updateStatus.textColor = .secondaryLabelColor
        updateStatus.stringValue = "Checking with kylmora.com\u{2026}"
        let current = AppInfo.version
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.check(current)
            self.show(outcome)
        }
    }

    /// Puts the answer on the pane.
    func show(_ outcome: UpdateCheck.Outcome) {
        checking = false
        checkButton.isEnabled = true
        switch outcome {
        case .upToDate(let current):
            updateStatus.textColor = .secondaryLabelColor
            updateStatus.stringValue = "You\u{2019}re on the latest version. Kylmora \(current) is the newest there is."
        case .available(let version, let url, let notes):
            updateStatus.textColor = .labelColor
            var text = "Kylmora \(version) is available; you have \(AppInfo.version)."
            if let notes, !notes.isEmpty { text += " \(notes)" }
            updateStatus.stringValue = text
            downloadURL = url
            release = UpdateCheck.Release(version: version, url: url, notes: notes)
            // Only when there is something to fetch. A release the feed named
            // but gave no address for cannot be installed or downloaded, and a
            // button that would do neither is worse than no button.
            downloadButton.isHidden = url == nil
        case .unreachable(let reason):
            updateStatus.textColor = .secondaryLabelColor
            updateStatus.stringValue = reason
        }
        view.window?.windowController.flatMap { $0 as? SettingsWindowController }?.paneDidResize()
    }

    @objc private func autoCheckToggled(_ sender: NSButton) {
        Settings.shared.automaticallyCheckForUpdates = (sender.state == .on)
    }

    @objc private func autoDownloadToggled(_ sender: NSButton) {
        Settings.shared.automaticallyDownloadUpdates = (sender.state == .on)
    }

    /// Hands the update to the installer rather than to a web page.
    ///
    /// This button used to open the download in a browser and leave the rest
    /// to the user: find the disk image, open it, drag the app over the old
    /// one, agree to replace it. `UpdateController` does the whole thing --
    /// download, verify, swap, reopen -- so all this has to do is start it and
    /// let the update window take over from here.
    @objc private func download() {
        guard let release else {
            // No release in hand: fall back to the page, which is better than
            // a button that does nothing.
            if let downloadURL { NSWorkspace.shared.open(downloadURL) }
            return
        }
        UpdateController.shared.presentUpdateWindow(for: release)
    }

    /// The release the check found, which the Update Now button installs.
    private var release: UpdateCheck.Release?

    /// What the status line says right now; for tests.
    var updateStatusText: String { updateStatus.stringValue }
    var showsDownloadButton: Bool { !downloadButton.isHidden }
    var isAutoCheckEnabled: Bool { autoCheckCheckbox.state == .on }
    var isAutoDownloadEnabled: Bool { autoDownloadCheckbox.state == .on }
}
