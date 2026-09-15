import AppKit

/// The Advanced pane: JSON formatting, developer tools, extension sources,
/// DNS over HTTPS (DoH), and Network Proxy.
@MainActor
final class AdvancedSettingsViewController: NSViewController, NSTextFieldDelegate {
    private let settings: Settings
    private let jsonCheckbox = NSButton(checkboxWithTitle: "Enable JSON formatting", target: nil, action: nil)
    private let developMenuCheckbox = NSButton(checkboxWithTitle: "Show Develop menu in menu bar", target: nil, action: nil)
    private let chromeCheckbox = NSButton(checkboxWithTitle: "Allow installation of 3rd-party Chrome extensions", target: nil, action: nil)
    private let firefoxCheckbox = NSButton(checkboxWithTitle: "Allow installation of 3rd-party Firefox extensions", target: nil, action: nil)

    // DNS over HTTPS
    private let dohPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let dohCustomField = NSTextField()
    private let dohInstallButton = NSButton(title: "Install DNS Profile\u{2026}", target: nil, action: nil)
    private let dohStatusLabel = NSTextField(wrappingLabelWithString: "")
    /// Where the profile goes. Downloads, so it can be found again and handed
    /// to an MDM; tests point it elsewhere.
    var profileDirectory: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ?? FileManager.default.temporaryDirectory
    /// How the written profile is handed to the system; tests replace it.
    var openProfile: (URL) -> Void = { NSWorkspace.shared.open($0) }

    // Proxy
    private let proxyCheckbox = NSButton(checkboxWithTitle: "Enable proxy server", target: nil, action: nil)
    private let proxyTypePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let proxyHostField = NSTextField()
    private let proxyPortField = NSTextField()
    private let proxyAuthCheckbox = NSButton(checkboxWithTitle: "Requires authentication", target: nil, action: nil)
    private let proxyUsernameField = NSTextField()
    private let proxyPasswordField = NSSecureTextField()
    private let proxyBypassField = NSTextField()

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
        form.addSection("Developer")
        jsonCheckbox.target = self
        jsonCheckbox.action = #selector(jsonChanged)
        form.addRow("", jsonCheckbox)
        form.addNote("A page that is a JSON document is shown indented and coloured rather than as one line.")

        developMenuCheckbox.target = self
        developMenuCheckbox.action = #selector(developMenuChanged)
        form.addRow("", developMenuCheckbox)
        form.addNote("Exposes Web Inspector, JavaScript console, and Inspect Element in the menu bar.")

        form.addSection("Extensions")
        chromeCheckbox.target = self
        chromeCheckbox.action = #selector(chromeChanged)
        firefoxCheckbox.target = self
        firefoxCheckbox.action = #selector(firefoxChanged)
        form.addRow("", chromeCheckbox)
        form.addRow("", firefoxCheckbox)
        let manage = NSButton(title: "Manage Extensions\u{2026}", target: self, action: #selector(manageExtensions))
        manage.bezelStyle = .rounded
        form.addContinuation(manage)
        form.addLinkNote(
            "Read more about ", linkText: "web extensions support", " in Kylmora.",
            url: URL(string: "https://developer.apple.com/documentation/safariservices/safari-web-extensions")!
        )

        // MARK: - DNS over HTTPS
        form.addSection("Encrypted DNS")
        dohPopup.target = self
        dohPopup.action = #selector(dohChanged)
        dohPopup.removeAllItems()
        for provider in DoHProvider.allPresets {
            dohPopup.addItem(withTitle: provider.title)
        }
        form.addRow("Resolver", SettingsForm.fill(dohPopup))

        dohCustomField.placeholderString = "https://example.com/dns-query"
        dohCustomField.delegate = self
        dohCustomField.target = self
        dohCustomField.action = #selector(dohCustomFieldChanged)
        // The row goes where the field goes: it is only shown for a custom
        // resolver.
        form.addContinuation(SettingsForm.fill(dohCustomField))

        dohInstallButton.bezelStyle = .rounded
        dohInstallButton.target = self
        dohInstallButton.action = #selector(installDNSProfile)
        form.addContinuation(dohInstallButton)
        dohStatusLabel.font = Style.Fonts.settingsNote
        dohStatusLabel.textColor = Style.Colors.secondaryText
        form.addNote(dohStatusLabel)
        form.addNote("Pages load in WebKit's own network process, which uses the Mac's DNS settings, so a browser cannot switch encrypted DNS on by itself. macOS takes the setting from a configuration profile: Kylmora writes one for the resolver above, you approve it once in System Settings ▸ General ▸ Device Management, and from then on every app on this Mac, Kylmora included, sends its DNS queries over HTTPS (RFC 8484). Remove the profile there to go back.")

        // MARK: - Proxy
        form.addSection("Network proxy")
        proxyCheckbox.target = self
        proxyCheckbox.action = #selector(proxyChanged)
        form.addRow("", proxyCheckbox)

        proxyTypePopup.target = self
        proxyTypePopup.action = #selector(proxyChanged)
        proxyTypePopup.removeAllItems()
        for type in ProxyType.allCases {
            proxyTypePopup.addItem(withTitle: type.title)
        }

        proxyHostField.placeholderString = "127.0.0.1"
        proxyHostField.delegate = self
        proxyHostField.target = self
        proxyHostField.action = #selector(proxyFieldsChanged)
        proxyHostField.widthAnchor.constraint(equalToConstant: 160).isActive = true

        proxyPortField.placeholderString = "8080"
        proxyPortField.delegate = self
        proxyPortField.target = self
        proxyPortField.action = #selector(proxyFieldsChanged)
        proxyPortField.widthAnchor.constraint(equalToConstant: 60).isActive = true

        let colonLabel = NSTextField(labelWithString: ":")
        colonLabel.textColor = .secondaryLabelColor
        form.addRow("Server", [proxyTypePopup, proxyHostField, colonLabel, proxyPortField])

        proxyAuthCheckbox.target = self
        proxyAuthCheckbox.action = #selector(proxyChanged)

        proxyUsernameField.placeholderString = "Username"
        proxyUsernameField.delegate = self
        proxyUsernameField.target = self
        proxyUsernameField.action = #selector(proxyFieldsChanged)
        proxyUsernameField.widthAnchor.constraint(equalToConstant: 130).isActive = true

        proxyPasswordField.placeholderString = "Password"
        proxyPasswordField.delegate = self
        proxyPasswordField.target = self
        proxyPasswordField.action = #selector(proxyFieldsChanged)
        proxyPasswordField.widthAnchor.constraint(equalToConstant: 130).isActive = true

        // The checkbox leads, so it names the row; the two fields sit with
        // the switch.
        let authStack = NSStackView(views: [proxyAuthCheckbox, proxyUsernameField, proxyPasswordField])
        authStack.orientation = .horizontal
        authStack.alignment = .centerY
        authStack.spacing = 8
        form.addRow("", authStack)

        proxyBypassField.placeholderString = "localhost, 127.0.0.1, *.local"
        proxyBypassField.delegate = self
        proxyBypassField.target = self
        proxyBypassField.action = #selector(proxyFieldsChanged)
        form.addRow("Bypass domains", SettingsForm.fill(proxyBypassField))
        form.addNote("Comma-separated. Routes web requests through the specified HTTP or SOCKSv5 proxy. Spaces can also define per-space proxy configurations.")
    }

    private func reload() {
        jsonCheckbox.state = settings.formatsJSON ? .on : .off
        if EnterprisePolicyManager.shared.isDeveloperToolsDisabled {
            developMenuCheckbox.state = .off
            developMenuCheckbox.isEnabled = false
        } else {
            developMenuCheckbox.state = settings.showDevelopMenu ? .on : .off
            developMenuCheckbox.isEnabled = true
        }

        if EnterprisePolicyManager.shared.isBlockAllExtensions {
            chromeCheckbox.state = .off
            chromeCheckbox.isEnabled = false
            firefoxCheckbox.state = .off
            firefoxCheckbox.isEnabled = false
        } else {
            chromeCheckbox.state = settings.allowsChromeExtensions ? .on : .off
            chromeCheckbox.isEnabled = true
            firefoxCheckbox.state = settings.allowsFirefoxExtensions ? .on : .off
            firefoxCheckbox.isEnabled = true
        }

        // DoH
        let currentDoH = settings.dohProvider
        switch currentDoH {
        case .off: dohPopup.selectItem(at: 0)
        case .cloudflare: dohPopup.selectItem(at: 1)
        case .quad9: dohPopup.selectItem(at: 2)
        case .google: dohPopup.selectItem(at: 3)
        case .adguard: dohPopup.selectItem(at: 4)
        case .custom(let url):
            dohPopup.selectItem(at: 5)
            dohCustomField.stringValue = url
        }
        dohCustomField.isHidden = dohPopup.indexOfSelectedItem != 5
        updateDNSProfileControls()

        // Proxy
        let proxy = settings.proxySettings
        proxyCheckbox.state = proxy.enabled ? .on : .off
        if let idx = ProxyType.allCases.firstIndex(of: proxy.type) {
            proxyTypePopup.selectItem(at: idx)
        }
        proxyHostField.stringValue = proxy.host
        proxyPortField.stringValue = String(proxy.port)
        proxyAuthCheckbox.state = proxy.requiresAuthentication ? .on : .off
        proxyUsernameField.stringValue = proxy.username
        proxyPasswordField.stringValue = proxy.password
        proxyBypassField.stringValue = proxy.bypassList

        updateProxyControlStates()
    }

    private func updateProxyControlStates() {
        let isEnabled = proxyCheckbox.state == .on
        proxyTypePopup.isEnabled = isEnabled
        proxyHostField.isEnabled = isEnabled
        proxyPortField.isEnabled = isEnabled
        proxyAuthCheckbox.isEnabled = isEnabled
        let authEnabled = isEnabled && proxyAuthCheckbox.state == .on
        proxyUsernameField.isEnabled = authEnabled
        proxyPasswordField.isEnabled = authEnabled
        proxyBypassField.isEnabled = isEnabled
    }

    @objc private func jsonChanged() {
        settings.formatsJSON = jsonCheckbox.state == .on
        JSONFormatting.shared.preferencesChanged()
    }

    @objc private func developMenuChanged() {
        settings.showDevelopMenu = developMenuCheckbox.state == .on
    }

    @objc private func chromeChanged() { settings.allowsChromeExtensions = chromeCheckbox.state == .on }
    @objc private func firefoxChanged() { settings.allowsFirefoxExtensions = firefoxCheckbox.state == .on }

    @objc private func manageExtensions() {
        (view.window?.windowController as? SettingsWindowController)?.select(.extensions)
    }

    @objc private func dohChanged() {
        let index = dohPopup.indexOfSelectedItem
        let provider: DoHProvider
        switch index {
        case 0: provider = .off
        case 1: provider = .cloudflare
        case 2: provider = .quad9
        case 3: provider = .google
        case 4: provider = .adguard
        case 5:
            provider = .custom(url: dohCustomField.stringValue)
        default:
            provider = .off
        }
        dohCustomField.isHidden = index != 5
        settings.dohProvider = provider
        updateDNSProfileControls()
    }

    @objc private func dohCustomFieldChanged() {
        if dohPopup.indexOfSelectedItem == 5 {
            settings.dohProvider = .custom(url: dohCustomField.stringValue)
        }
        updateDNSProfileControls()
    }

    /// The button only offers what can be written: a resolver with an
    /// https endpoint. The label says what the profile will do.
    func updateDNSProfileControls() {
        if let profile = DNSProfile(provider: settings.dohProvider) {
            dohInstallButton.isEnabled = true
            dohInstallButton.title = "Install \(profile.resolverName) DNS Profile\u{2026}"
            dohStatusLabel.stringValue = "Writes \(profile.fileName) to Downloads and opens it for approval. Once approved, the whole Mac resolves names through \(profile.serverURL)."
        } else {
            dohInstallButton.isEnabled = false
            dohInstallButton.title = "Install DNS Profile\u{2026}"
            if case .custom = settings.dohProvider {
                dohStatusLabel.stringValue = "Enter an https:// resolver address to make a profile for it."
            } else {
                dohStatusLabel.stringValue = "Off: the Mac keeps the DNS settings of the network it is on."
            }
        }
    }

    /// Writes the profile for the chosen resolver and hands it to macOS,
    /// which lists it under Device Management for the user to approve.
    @objc func installDNSProfile() {
        guard let profile = DNSProfile(provider: settings.dohProvider) else { return }
        do {
            let file = try profile.write(to: profileDirectory)
            openProfile(file)
            dohStatusLabel.stringValue = "Profile written to \(file.path). Approve it in System Settings ▸ General ▸ Device Management to switch the Mac to \(profile.resolverName)."
        } catch {
            dohStatusLabel.stringValue = "Could not write the profile: \(error.localizedDescription)"
        }
    }

    @objc private func proxyChanged() {
        updateProxyControlStates()
        saveProxySettings()
    }

    @objc private func proxyFieldsChanged() {
        saveProxySettings()
    }

    private func saveProxySettings() {
        let typeIndex = max(0, proxyTypePopup.indexOfSelectedItem)
        let type = ProxyType.allCases[typeIndex]
        let port = Int(proxyPortField.stringValue) ?? 8080
        let proxy = ProxySettings(
            enabled: proxyCheckbox.state == .on,
            type: type,
            host: proxyHostField.stringValue,
            port: port,
            requiresAuthentication: proxyAuthCheckbox.state == .on,
            username: proxyUsernameField.stringValue,
            password: proxyPasswordField.stringValue,
            bypassList: proxyBypassField.stringValue
        )
        settings.proxySettings = proxy
    }

    func controlTextDidChange(_ obj: Notification) {
        if let field = obj.object as? NSTextField {
            if field === dohCustomField {
                dohCustomFieldChanged()
            } else if field === proxyHostField || field === proxyPortField || field === proxyUsernameField || field === proxyPasswordField || field === proxyBypassField {
                saveProxySettings()
            }
        }
    }
}
