import AppKit

/// The Advanced pane: JSON formatting, and which extension sources are open.
@MainActor
final class AdvancedSettingsViewController: NSViewController {
    private let settings: Settings
    private let jsonCheckbox = NSButton(checkboxWithTitle: "Enable JSON formatting", target: nil, action: nil)
    private let chromeCheckbox = NSButton(checkboxWithTitle: "Allow installation of 3rd-party Chrome extensions", target: nil, action: nil)
    private let firefoxCheckbox = NSButton(checkboxWithTitle: "Allow installation of 3rd-party Firefox extensions", target: nil, action: nil)

    init(settings: Settings = .shared) {
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("AdvancedSettingsViewController is created in code only")
    }

    override func loadView() {
        let form = SettingsForm()
        view = form
        buildLayout(in: form)
        reload()
    }

    private func buildLayout(in form: SettingsForm) {
        jsonCheckbox.target = self
        jsonCheckbox.action = #selector(jsonChanged)
        form.addRow("Rendering", jsonCheckbox)
        form.addNote("A page that is a JSON document is shown indented and coloured rather than as one line.")

        chromeCheckbox.target = self
        chromeCheckbox.action = #selector(chromeChanged)
        firefoxCheckbox.target = self
        firefoxCheckbox.action = #selector(firefoxChanged)
        let sources = NSStackView(views: [chromeCheckbox, firefoxCheckbox])
        sources.orientation = .vertical
        sources.alignment = .leading
        sources.spacing = 8
        form.addRow("Extensions", sources)
        form.addLinkNote(
            "Read more about ", linkText: "web extensions support", " in Kylmora.",
            url: URL(string: "https://developer.apple.com/documentation/safariservices/safari-web-extensions")!
        )

        let manage = NSButton(title: "Manage Extensions\u{2026}", target: self, action: #selector(manageExtensions))
        manage.bezelStyle = .rounded
        form.addContinuation(manage)
    }

    private func reload() {
        jsonCheckbox.state = settings.formatsJSON ? .on : .off
        chromeCheckbox.state = settings.allowsChromeExtensions ? .on : .off
        firefoxCheckbox.state = settings.allowsFirefoxExtensions ? .on : .off
    }

    @objc private func jsonChanged() {
        settings.formatsJSON = jsonCheckbox.state == .on
        JSONFormatting.shared.preferencesChanged()
    }

    @objc private func chromeChanged() { settings.allowsChromeExtensions = chromeCheckbox.state == .on }
    @objc private func firefoxChanged() { settings.allowsFirefoxExtensions = firefoxCheckbox.state == .on }

    @objc private func manageExtensions() {
        (view.window?.windowController as? SettingsWindowController)?.select(.extensions)
    }
}
