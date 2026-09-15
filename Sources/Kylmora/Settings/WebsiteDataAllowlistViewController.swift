import AppKit

/// Manages the list of domains whose cookies and data are preserved when clearing on quit.
@MainActor
final class WebsiteDataAllowlistViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let settings: Settings
    private let session: BrowserSession?
    private let table = NSTableView()
    private let inputField = NSTextField()
    private let addButton = NSButton(title: "Add", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let addOpenTabsButton = NSButton(title: "Add Open Sites", target: nil, action: nil)
    private var allowedHosts: [String] = []

    init(settings: Settings = .shared, session: BrowserSession? = nil) {
        self.settings = settings
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("WebsiteDataAllowlistViewController is created in code only")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 380))
        let title = NSTextField(labelWithString: "Quit Data Allow-List")
        title.font = .systemFont(ofSize: 17, weight: .bold)
        let blurb = NSTextField(wrappingLabelWithString: "Websites on this list keep their cookies, cache, and local storage when Kylmora quits with data clearing enabled.")
        blurb.font = .systemFont(ofSize: 12)
        blurb.textColor = .secondaryLabelColor

        inputField.placeholderString = "example.com"
        inputField.target = self
        inputField.action = #selector(addEntered)

        addButton.target = self
        addButton.action = #selector(addEntered)
        addButton.bezelStyle = .rounded

        addOpenTabsButton.target = self
        addOpenTabsButton.action = #selector(addOpenSites)
        addOpenTabsButton.bezelStyle = .rounded

        let addRow = NSStackView(views: [inputField, addButton, addOpenTabsButton])
        addRow.orientation = .horizontal
        addRow.spacing = 8

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("host"))
        col.title = "Allowed Website"
        col.width = 420
        table.addTableColumn(col)
        table.rowHeight = 24
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 200).isActive = true

        removeButton.target = self
        removeButton.action = #selector(removeSelected)
        removeButton.bezelStyle = .rounded
        removeButton.isEnabled = false

        let done = NSButton(title: "Done", target: self, action: #selector(dismissSheet))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"

        let footer = NSStackView(views: [removeButton, NSView(), done])
        footer.orientation = .horizontal
        footer.spacing = 8

        let stack = NSStackView(views: [title, blurb, addRow, scroll, footer])
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
            addRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        reload()
    }

    private func reload() {
        allowedHosts = settings.websiteDataQuitAllowlist.sorted()
        table.reloadData()
        removeButton.isEnabled = !table.selectedRowIndexes.isEmpty
    }

    @objc private func addEntered() {
        let text = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        settings.addToQuitAllowlist(text)
        inputField.stringValue = ""
        reload()
    }

    @objc private func addOpenSites() {
        guard let session else { return }
        for tab in session.allTabs {
            if let host = tab.url.host(), !host.isEmpty {
                settings.addToQuitAllowlist(host)
            }
        }
        reload()
    }

    @objc private func removeSelected() {
        let selectedIndices = table.selectedRowIndexes
        let hostsToRemove = selectedIndices.compactMap { allowedHosts.indices.contains($0) ? allowedHosts[$0] : nil }
        for host in hostsToRemove {
            settings.removeFromQuitAllowlist(host)
        }
        reload()
    }

    @objc private func dismissSheet() {
        dismiss(nil)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        allowedHosts.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard allowedHosts.indices.contains(row) else { return nil }
        let text = allowedHosts[row]
        let cell = NSTextField(labelWithString: text)
        cell.font = .systemFont(ofSize: 13)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton.isEnabled = !table.selectedRowIndexes.isEmpty
    }
}
