import AppKit

/// The Passwords pane: where saved logins come from, the AutoFill switches, and
/// a way to manage what is stored. Kylmora's own AutoFill is backed by the macOS
/// login Keychain; other managers plug in as browser extensions.
@MainActor
final class PasswordsSettingsViewController: NSViewController {
    private let settings: Settings
    private let session: BrowserSession
    private let providerPopUp = NSPopUpButton()
    private let providerNote = NSTextField(wrappingLabelWithString: "")
    private let offerAutofill = NSButton(checkboxWithTitle: "Offer to AutoFill saved passwords", target: nil, action: nil)
    private let offerSave = NSButton(checkboxWithTitle: "Offer to save passwords", target: nil, action: nil)
    private let submitAutomatically = NSButton(checkboxWithTitle: "Submit form automatically", target: nil, action: nil)
    private let useTouchID = NSButton(checkboxWithTitle: "Use Touch ID", target: nil, action: nil)
    private var manager: PasswordsManagerWindowController?
    private let identityAutofill = NSButton(checkboxWithTitle: "AutoFill names, addresses and contact details", target: nil, action: nil)
    private let cardAutofill = NSButton(checkboxWithTitle: "AutoFill payment cards", target: nil, action: nil)
    private var autofillManager: AutofillManagerWindowController?
    /// The rows only Keychain AutoFill uses, and the rows only "Others" uses,
    /// so the pane can swap one set for the other when the provider changes.
    private var autofillRows: [SettingsFormRow] = []
    private var linkRows: [SettingsFormRow] = []

    init(settings: Settings = .shared, session: BrowserSession) {
        self.settings = settings
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("PasswordsSettingsViewController is created in code only")
    }

    override func loadView() {
        let form = SettingsForm()
        view = form

        providerPopUp.addItems(withTitles: PasswordProvider.allCases.map(\.title))
        providerPopUp.target = self
        providerPopUp.action = #selector(providerChanged)
        form.addRow("Password provider", SettingsForm.fill(providerPopUp))
        form.addNote(providerNote)

        form.addSeparator()

        for box in [offerAutofill, offerSave, submitAutomatically, useTouchID] {
            box.target = self
            box.action = #selector(toggleChanged)
        }
        let manage = NSButton(title: "Manage Passwords\u{2026}", target: self, action: #selector(managePasswords))
        manage.bezelStyle = .rounded
        autofillRows = [
            form.addRow("Password AutoFill", offerAutofill),
            form.addContinuation(offerSave),
            form.addContinuation(submitAutomatically),
            form.addContinuation(useTouchID),
            form.addContinuation(manage)
        ]

        // "Others": links to the managers Kylmora can point at but cannot read.
        for (index, link) in PasswordManagerLink.common.enumerated() {
            let button = NSButton(title: link.name, target: self, action: #selector(openManager(_:)))
            button.isBordered = false
            button.tag = index
            button.attributedTitle = NSAttributedString(string: link.name, attributes: [
                .foregroundColor: NSColor.linkColor,
                .font: NSFont.systemFont(ofSize: 13),
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ])
            let row = index == 0 ? form.addRow("Install a manager", button) : form.addContinuation(button)
            linkRows.append(row)
        }

        form.addSection("Identities and cards")
        for box in [identityAutofill, cardAutofill] {
            box.target = self
            box.action = #selector(toggleChanged)
        }
        form.addRow("", identityAutofill)
        form.addRow("", cardAutofill)
        let manageAutofill = NSButton(title: "Manage Identities & Cards\u{2026}", target: self, action: #selector(manageAutofill))
        manageAutofill.bezelStyle = .rounded
        form.addContinuation(manageAutofill)
        form.addNote("Click into a form and Kylmora fills the fields it recognises from your first identity. Cards are filled only on secure pages, after Touch ID when that is on above, and never submitted; the security code is never stored.")

        reload()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }

    private func reload() {
        providerPopUp.selectItem(at: PasswordProvider.allCases.firstIndex(of: settings.passwordProvider) ?? 0)
        offerAutofill.state = settings.passwordOfferAutofill ? .on : .off
        offerSave.state = settings.passwordOfferSave ? .on : .off
        submitAutomatically.state = settings.passwordSubmitAutomatically ? .on : .off
        useTouchID.state = settings.passwordUsesTouchID ? .on : .off
        identityAutofill.state = settings.formAutofillEnabled ? .on : .off
        cardAutofill.state = settings.cardAutofillEnabled ? .on : .off
        syncProvider()
    }

    /// Keychain AutoFill shows its switches; "Others" swaps them for a warning
    /// and the list of managers to install, since Kylmora cannot read their vaults.
    private func syncProvider() {
        let usesKeychain = settings.passwordProvider == .keychain
        providerNote.stringValue = usesKeychain
            ? "Passwords are saved in your macOS login Keychain and synced with iCloud Keychain \u{2014} the same store Safari uses. Kylmora keeps no separate password database."
            : "Kylmora can\u{2019}t read another manager\u{2019}s vault directly \u{2014} you need its browser extension. Click one below to open its page in Kylmora, download the extension, then load it from the Extensions pane."
        for row in autofillRows { row.isHidden = !usesKeychain }
        for row in linkRows { row.isHidden = usesKeychain }
    }

    @objc private func providerChanged() {
        let index = providerPopUp.indexOfSelectedItem
        guard PasswordProvider.allCases.indices.contains(index) else { return }
        settings.passwordProvider = PasswordProvider.allCases[index]
        syncProvider()
    }

    @objc private func toggleChanged() {
        settings.passwordOfferAutofill = offerAutofill.state == .on
        settings.passwordOfferSave = offerSave.state == .on
        settings.passwordSubmitAutomatically = submitAutomatically.state == .on
        settings.passwordUsesTouchID = useTouchID.state == .on
        settings.formAutofillEnabled = identityAutofill.state == .on
        settings.cardAutofillEnabled = cardAutofill.state == .on
    }

    @objc private func manageAutofill() {
        let controller = autofillManager ?? AutofillManagerWindowController()
        autofillManager = controller
        controller.showWindow(self)
        controller.window?.makeKeyAndOrderFront(self)
    }

    @objc private func managePasswords() {
        let controller = manager ?? PasswordsManagerWindowController()
        manager = controller
        controller.showWindow(self)
        controller.window?.makeKeyAndOrderFront(self)
    }

    /// Opens a manager's install page in a Kylmora tab and brings the browser
    /// window forward so the download is right there.
    @objc private func openManager(_ sender: NSButton) {
        guard PasswordManagerLink.common.indices.contains(sender.tag) else { return }
        session.newTab(url: PasswordManagerLink.common[sender.tag].url)
        for window in NSApp.windows where window.windowController is BrowserWindowController {
            window.makeKeyAndOrderFront(nil)
            break
        }
    }
}

/// A small window listing the logins Kylmora has saved to the Keychain, with a way
/// to remove one. Passwords are never shown in the list -- only which sites and
/// usernames are stored.
@MainActor
final class PasswordsManagerWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private var credentials: [PasswordCredential] = []
    private let tableView = NSTableView()
    private let empty = NSTextField(labelWithString: "No saved passwords yet.")

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Passwords"
        super.init(window: window)
        window.center()
        window.isReleasedWhenClosed = false
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("PasswordsManagerWindowController is created in code only")
    }

    private func build() {
        guard let window else { return }
        let host = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("host"))
        host.title = "Website"
        host.width = 230
        let user = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("user"))
        user.title = "Username"
        user.width = 210
        tableView.addTableColumn(host)
        tableView.addTableColumn(user)
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.dataSource = self
        tableView.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        empty.textColor = .secondaryLabelColor
        empty.translatesAutoresizingMaskIntoConstraints = false

        let remove = NSButton(title: "Remove", target: self, action: #selector(removeSelected))
        remove.bezelStyle = .rounded
        let done = NSButton(title: "Done", target: self, action: #selector(closeWindow))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        let buttons = NSStackView(views: [remove, NSView(), done])
        buttons.orientation = .horizontal
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(scroll)
        container.addSubview(empty)
        container.addSubview(buttons)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            buttons.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16)
        ])
        window.contentView = container
        reload()
    }

    override func showWindow(_ sender: Any?) {
        reload()
        super.showWindow(sender)
    }

    private func reload() {
        credentials = KeychainPasswordStore.all()
        empty.isHidden = !credentials.isEmpty
        tableView.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { credentials.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard credentials.indices.contains(row) else { return nil }
        let credential = credentials[row]
        let text = tableColumn?.identifier.rawValue == "host" ? credential.host : credential.username
        let field = NSTextField(labelWithString: text)
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    @objc private func removeSelected() {
        let row = tableView.selectedRow
        guard credentials.indices.contains(row) else { return }
        let credential = credentials[row]
        KeychainPasswordStore.delete(host: credential.host, username: credential.username)
        reload()
    }

    @objc private func closeWindow() {
        window?.close()
    }
}
