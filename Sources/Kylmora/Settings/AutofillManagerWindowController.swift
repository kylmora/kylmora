import AppKit

/// The identities and cards autofill can use: two lists with add, edit and
/// remove. Card numbers are never shown, only the brand and last four.
@MainActor
final class AutofillManagerWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let store: AutofillStore
    private let identitiesTable = NSTableView()
    private let cardsTable = NSTableView()

    init(store: AutofillStore = .shared) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Identities & Cards"
        super.init(window: window)
        window.center()
        window.isReleasedWhenClosed = false
        build()
        store.onChange = { [weak self] in self?.reload() }
    }

    required init?(coder: NSCoder) {
        fatalError("AutofillManagerWindowController is created in code only")
    }

    private func build() {
        guard let window else { return }
        let identities = section(
            title: "Identities", table: identitiesTable,
            columns: [("name", "Name", 200), ("email", "Email", 180), ("address", "Address", 160)],
            buttons: [("Add\u{2026}", #selector(addIdentity)), ("Edit\u{2026}", #selector(editIdentity)), ("Remove", #selector(removeIdentity))]
        )
        let cards = section(
            title: "Cards", table: cardsTable,
            columns: [("card", "Card", 240), ("holder", "Name on card", 180), ("expiry", "Expires", 80)],
            buttons: [("Add\u{2026}", #selector(addCard)), ("Remove", #selector(removeCard))]
        )
        let done = NSButton(title: "Done", target: self, action: #selector(closeWindow))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        let footer = NSStackView(views: [NSView(), done])
        footer.orientation = .horizontal

        let column = NSStackView(views: [identities, cards, footer])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 16
        column.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            column.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            column.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            column.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            identities.widthAnchor.constraint(equalTo: column.widthAnchor),
            cards.widthAnchor.constraint(equalTo: column.widthAnchor),
            footer.widthAnchor.constraint(equalTo: column.widthAnchor)
        ])
        window.contentView = container
        reload()
    }

    private func section(title: String, table: NSTableView, columns: [(String, String, CGFloat)], buttons: [(String, Selector)]) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        for (id, name, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = name
            column.width = width
            table.addTableColumn(column)
        }
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        table.doubleAction = table === identitiesTable ? #selector(editIdentity) : nil
        table.target = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 130).isActive = true
        let row = NSStackView(views: buttons.map { title, action in
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            return button
        })
        row.orientation = .horizontal
        let stack = NSStackView(views: [heading, scroll, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    override func showWindow(_ sender: Any?) {
        reload()
        super.showWindow(sender)
    }

    func reload() {
        identitiesTable.reloadData()
        cardsTable.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === identitiesTable ? store.identities.count : store.cards.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = tableColumn?.identifier.rawValue ?? ""
        let text: String
        if tableView === identitiesTable {
            guard store.identities.indices.contains(row) else { return nil }
            let identity = store.identities[row]
            switch id {
            case "name": text = identity.displayName
            case "email": text = identity.email
            default: text = [identity.street, identity.city].filter { !$0.isEmpty }.joined(separator: ", ")
            }
        } else {
            guard store.cards.indices.contains(row) else { return nil }
            let card = store.cards[row]
            switch id {
            case "card": text = card.displayName
            case "holder": text = card.holder
            default: text = card.expiry
            }
        }
        let field = NSTextField(labelWithString: text)
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    // MARK: - Identities

    @objc private func addIdentity() { present(IdentityEditorViewController(identity: nil, store: store)) }

    @objc private func editIdentity() {
        let row = identitiesTable.selectedRow
        guard store.identities.indices.contains(row) else { return }
        present(IdentityEditorViewController(identity: store.identities[row], store: store))
    }

    @objc private func removeIdentity() {
        let row = identitiesTable.selectedRow
        guard store.identities.indices.contains(row) else { return }
        store.removeIdentity(id: store.identities[row].id)
    }

    // MARK: - Cards

    @objc private func addCard() { present(CardEditorViewController(store: store)) }

    @objc private func removeCard() {
        let row = cardsTable.selectedRow
        guard store.cards.indices.contains(row) else { return }
        store.removeCard(id: store.cards[row].id)
    }

    private func present(_ editor: NSViewController) {
        guard let window else { return }
        let sheet = NSWindow(contentViewController: editor)
        sheet.isReleasedWhenClosed = false
        window.beginSheet(sheet)
    }

    @objc private func closeWindow() { window?.close() }
}

/// A form for one identity.
@MainActor
final class IdentityEditorViewController: NSViewController {
    private var identity: AutofillIdentity
    private let store: AutofillStore
    private var fields: [(WritableKeyPath<AutofillIdentity, String>, NSTextField)] = []

    init(identity: AutofillIdentity?, store: AutofillStore) {
        self.identity = identity ?? AutofillIdentity()
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("IdentityEditorViewController is created in code only") }

    override func loadView() {
        let grid = NSGridView()
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        let rows: [(String, WritableKeyPath<AutofillIdentity, String>)] = [
            ("Label", \.label), ("First name", \.givenName), ("Last name", \.familyName), ("Email", \.email),
            ("Phone", \.phone), ("Company", \.organization), ("Street", \.street), ("Apt, suite", \.street2),
            ("City", \.city), ("State", \.state), ("Postal code", \.postalCode), ("Country", \.country)
        ]
        for (title, path) in rows {
            let label = NSTextField(labelWithString: title)
            label.alignment = .right
            let field = NSTextField(string: identity[keyPath: path])
            field.widthAnchor.constraint(equalToConstant: 280).isActive = true
            fields.append((path, field))
            grid.addRow(with: [label, field])
        }
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, save])
        buttons.orientation = .horizontal
        let column = NSStackView(views: [grid, buttons])
        column.orientation = .vertical
        column.alignment = .trailing
        column.spacing = 14
        column.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        view = column
    }

    /// The identity as the fields describe it.
    func currentIdentity() -> AutofillIdentity {
        var edited = identity
        for (path, field) in fields { edited[keyPath: path] = field.stringValue.trimmingCharacters(in: .whitespaces) }
        return edited
    }

    @objc private func save() {
        let edited = currentIdentity()
        if !edited.isEmpty { store.save(edited) }
        dismissSheet()
    }

    @objc private func cancel() { dismissSheet() }

    private func dismissSheet() {
        guard let window = view.window else { return }
        window.sheetParent?.endSheet(window)
    }
}

/// A form for one new card. The number goes straight to the Keychain.
@MainActor
final class CardEditorViewController: NSViewController {
    private let store: AutofillStore
    private let numberField = NSSecureTextField()
    private let holderField = NSTextField()
    private let labelField = NSTextField()
    private let monthPopUp = NSPopUpButton()
    private let yearPopUp = NSPopUpButton()
    private let problem = NSTextField(labelWithString: "")

    init(store: AutofillStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("CardEditorViewController is created in code only") }

    override func loadView() {
        let grid = NSGridView()
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        numberField.placeholderString = "Card number"
        holderField.placeholderString = "Name as printed on the card"
        labelField.placeholderString = "Optional, e.g. Work"
        monthPopUp.addItems(withTitles: (1...12).map { String(format: "%02d", $0) })
        let year = Calendar.current.component(.year, from: .now)
        yearPopUp.addItems(withTitles: (year...(year + 15)).map(String.init))
        let expiry = NSStackView(views: [monthPopUp, yearPopUp])
        expiry.orientation = .horizontal
        for (title, control) in [("Number", numberField), ("Name on card", holderField), ("Expires", expiry), ("Label", labelField)] as [(String, NSView)] {
            let label = NSTextField(labelWithString: title)
            label.alignment = .right
            if let field = control as? NSTextField { field.widthAnchor.constraint(equalToConstant: 280).isActive = true }
            grid.addRow(with: [label, control])
        }
        problem.textColor = .systemRed
        problem.font = .systemFont(ofSize: 11)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save Card", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        let buttons = NSStackView(views: [problem, cancel, save])
        buttons.orientation = .horizontal
        let note = NSTextField(wrappingLabelWithString: "The number is kept in your login Keychain; only the brand and last four digits are shown anywhere. The security code is never saved.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 380
        let column = NSStackView(views: [grid, note, buttons])
        column.orientation = .vertical
        column.alignment = .trailing
        column.spacing = 14
        column.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        view = column
    }

    @objc private func save() {
        let year = Int(yearPopUp.titleOfSelectedItem ?? "") ?? 0
        let saved = store.addCard(
            number: numberField.stringValue, holder: holderField.stringValue.trimmingCharacters(in: .whitespaces),
            expiryMonth: monthPopUp.indexOfSelectedItem + 1, expiryYear: year, label: labelField.stringValue
        )
        guard saved != nil else {
            problem.stringValue = "That does not look like a card number."
            return
        }
        dismissSheet()
    }

    @objc private func cancel() { dismissSheet() }

    private func dismissSheet() {
        guard let window = view.window else { return }
        window.sheetParent?.endSheet(window)
    }
}
