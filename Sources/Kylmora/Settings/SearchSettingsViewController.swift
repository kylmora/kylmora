import AppKit

/// The Search pane: which engine, which engine in private spaces, the user's
/// own engines, and what the command bar suggests from.
@MainActor
final class SearchSettingsViewController: NSViewController {
    private let settings: Settings
    private let enginePopUp = NSPopUpButton()
    private let sameInPrivate = NSButton(checkboxWithTitle: "Also use in Private Browsing", target: nil, action: nil)
    private let privatePopUp = NSPopUpButton()
    private let topHits = NSButton(checkboxWithTitle: "Top Hits", target: nil, action: nil)
    private let searchEngine = NSButton(checkboxWithTitle: "Search engine", target: nil, action: nil)
    private let history = NSButton(checkboxWithTitle: "History", target: nil, action: nil)
    private let bookmarks = NSButton(checkboxWithTitle: "Bookmarks", target: nil, action: nil)
    private let openTabs = NSButton(checkboxWithTitle: "Open tabs", target: nil, action: nil)

    init(settings: Settings = .shared) {
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("SearchSettingsViewController is created in code only")
    }

    override func loadView() {
        let form = SettingsForm()
        view = form
        buildLayout(in: form)
        reload()
    }

    private func buildLayout(in form: SettingsForm) {
        enginePopUp.target = self
        enginePopUp.action = #selector(engineChanged)
        form.addRow("Search engine", SettingsForm.fill(enginePopUp))
        sameInPrivate.target = self
        sameInPrivate.action = #selector(sameInPrivateChanged)
        form.addContinuation(sameInPrivate)

        privatePopUp.target = self
        privatePopUp.action = #selector(privateEngineChanged)
        form.addRow("Private Browsing search engine", SettingsForm.fill(privatePopUp))

        let manage = NSButton(title: "Manage Search Engines\u{2026}", target: self, action: #selector(manageEngines))
        manage.bezelStyle = .rounded
        form.addRow("Custom search engines", manage)
        form.addNote("Kylmora can make any site with a search box into a search engine. Give it a keyword, then type "
            + "the keyword, a space and your search in the command bar.")

        let boxes = [topHits, searchEngine, history, bookmarks, openTabs]
        for box in boxes {
            box.target = self
            box.action = #selector(sourcesChanged)
        }
        let stack = NSStackView(views: boxes)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        form.addRow("Autocomplete suggestions", stack)
    }

    /// The pop-ups list every engine, the user's own after the built-in ones.
    private func reload() {
        let engines = settings.searchEngines
        for popUp in [enginePopUp, privatePopUp] {
            popUp.removeAllItems()
            popUp.addItems(withTitles: engines.map(\.name))
        }
        if let index = engines.firstIndex(of: settings.searchEngine) { enginePopUp.selectItem(at: index) }
        if let index = engines.firstIndex(of: settings.chosenPrivateSearchEngine) { privatePopUp.selectItem(at: index) }
        sameInPrivate.state = settings.usesSameSearchEngineInPrivate ? .on : .off
        privatePopUp.isEnabled = !settings.usesSameSearchEngineInPrivate

        let sources = settings.suggestionSources
        topHits.state = sources.topHits ? .on : .off
        searchEngine.state = sources.searchEngine ? .on : .off
        history.state = sources.history ? .on : .off
        bookmarks.state = sources.bookmarks ? .on : .off
        openTabs.state = sources.openTabs ? .on : .off
    }

    @objc private func engineChanged() {
        let engines = settings.searchEngines
        guard engines.indices.contains(enginePopUp.indexOfSelectedItem) else { return }
        settings.searchEngine = engines[enginePopUp.indexOfSelectedItem]
    }

    @objc private func privateEngineChanged() {
        let engines = settings.searchEngines
        guard engines.indices.contains(privatePopUp.indexOfSelectedItem) else { return }
        settings.privateSearchEngine = engines[privatePopUp.indexOfSelectedItem]
    }

    @objc private func sameInPrivateChanged() {
        settings.usesSameSearchEngineInPrivate = sameInPrivate.state == .on
        privatePopUp.isEnabled = !settings.usesSameSearchEngineInPrivate
    }

    @objc private func sourcesChanged() {
        settings.suggestionSources = Settings.SuggestionSources(
            topHits: topHits.state == .on,
            searchEngine: searchEngine.state == .on,
            history: history.state == .on,
            bookmarks: bookmarks.state == .on,
            openTabs: openTabs.state == .on
        )
    }

    @objc private func manageEngines() {
        let sheet = SearchEnginesViewController(settings: settings)
        sheet.onDismiss = { [weak self] in self?.reload() }
        presentAsSheet(sheet)
    }
}

/// The list of engines, and a form for adding one of the user's own.
@MainActor
final class SearchEnginesViewController: NSViewController {
    var onDismiss: (() -> Void)?

    private let settings: Settings
    private let table = NSTableView()
    private let nameField = NSTextField()
    private let keywordField = NSTextField()
    private let addressField = NSTextField()
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let problem = NSTextField(wrappingLabelWithString: "")
    private var engines: [SearchEngine] = []

    init(settings: Settings = .shared) {
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("SearchEnginesViewController is created in code only")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 460))
        buildLayout()
        reload()
    }

    private func buildLayout() {
        let title = NSTextField(labelWithString: "Search Engines")
        title.font = .systemFont(ofSize: 17, weight: .bold)

        for (identifier, heading, width) in [("name", "Name", 150.0), ("keyword", "Keyword", 80.0), ("address", "Search Address", 270.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = heading
            column.width = width
            table.addTableColumn(column)
        }
        table.rowHeight = 24
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 180).isActive = true

        removeButton.target = self
        removeButton.action = #selector(removeSelected)
        removeButton.bezelStyle = .rounded
        removeButton.isEnabled = false

        let addHeading = NSTextField(labelWithString: "Add a search engine")
        addHeading.font = .systemFont(ofSize: 13, weight: .semibold)
        nameField.placeholderString = "Name"
        keywordField.placeholderString = "Keyword, such as w"
        addressField.placeholderString = "Search address with %s where the words go, such as https://en.wikipedia.org/w/index.php?search=%s"
        for field in [nameField, keywordField, addressField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 520).isActive = true
        }
        let add = NSButton(title: "Add", target: self, action: #selector(addEngine))
        add.bezelStyle = .rounded
        problem.font = .systemFont(ofSize: 11)
        problem.textColor = .systemRed

        let done = NSButton(title: "Done", target: self, action: #selector(dismissSheet))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        let footer = NSStackView(views: [removeButton, NSView(), done])
        footer.orientation = .horizontal
        footer.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [title, scroll, addHeading, nameField, keywordField, addressField, add, problem, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            problem.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func reload() {
        engines = settings.searchEngines
        table.reloadData()
        removeButton.isEnabled = false
    }

    @objc private func addEngine() {
        guard let engine = SearchEngine.custom(name: nameField.stringValue, address: addressField.stringValue,
                                               keyword: keywordField.stringValue) else {
            problem.stringValue = "The address needs %s where the search words go, and a name."
            return
        }
        if let keyword = engine.keyword, engines.contains(where: { $0.keyword == keyword }) {
            problem.stringValue = "Another engine already uses the keyword \u{201c}\(keyword)\u{201d}."
            return
        }
        problem.stringValue = ""
        settings.customSearchEngines.append(engine)
        nameField.stringValue = ""
        keywordField.stringValue = ""
        addressField.stringValue = ""
        reload()
    }

    @objc private func removeSelected() {
        guard engines.indices.contains(table.selectedRow), !engines[table.selectedRow].isBuiltIn else { return }
        settings.removeCustomSearchEngine(engines[table.selectedRow].id)
        reload()
    }

    @objc private func dismissSheet() {
        onDismiss?()
        dismiss(nil)
    }
}

extension SearchEnginesViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { engines.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard engines.indices.contains(row) else { return nil }
        let engine = engines[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "name": text = engine.name + (engine.isBuiltIn ? "  (built in)" : "")
        case "keyword": text = engine.keyword ?? ""
        default: text = engine.queryTemplate.replacingOccurrences(of: "{query}", with: "%s")
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingMiddle
        label.textColor = engine.isBuiltIn ? .secondaryLabelColor : .labelColor
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
        removeButton.isEnabled = engines.indices.contains(table.selectedRow) && !engines[table.selectedRow].isBuiltIn
    }
}
