import AppKit

/// The archive, as a list the sidebar shows in place of a space's own tabs.
///
/// A view rather than a window of its own. The archive holds the rows that left
/// the sidebar, and the sidebar is where someone goes looking for them; a second
/// window for it reads as a second app. It owns its table and its empty state,
/// so the sidebar's job is to hand it records and to act on what the user picks.
@MainActor
final class ArchiveListView: NSView {
    /// One archived tab, with the space it came from already resolved: the
    /// sidebar knows the spaces, and this list has no reason to.
    struct Entry {
        let record: BrowserSession.ArchivedTab
        let spaceName: String?
    }

    /// A row was picked: put the tab back, and go to it.
    var onRestore: ((BrowserSession.ArchivedTab) -> Void)?
    /// A row's remove button, or its menu: drop it from the archive.
    var onForget: ((BrowserSession.ArchivedTab) -> Void)?
    /// Empty the archive, which is everything this list is showing.
    var onClear: (() -> Void)?

    private let clearButton = NSButton(title: "Clear", target: nil, action: nil)
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    /// What the list is showing, most recently archived first -- the order
    /// someone hunting for "the thing that just vanished" reads in.
    private var entries: [Entry] = []

    /// Nothing to show. Exposed so the sidebar and the tests can tell an empty
    /// archive from a hidden one.
    var isEmpty: Bool { entries.isEmpty }

    /// How many rows are listed.
    var count: Int { entries.count }

    /// Lines the title and the Clear button up with the rows' favicons: the
    /// same margin a row keeps between its edge and its content.
    private static let contentInset = Style.Metrics.sidebarInset
        + Style.Metrics.rowContentInset
        + (Style.Metrics.rowHeight - Style.Metrics.rowPillHeight) / 2

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // The list is what fills the sidebar's remaining height, the same way
        // the tab list does when it is the one on screen.
        setContentHuggingPriority(.defaultLow, for: .vertical)
        buildLayout()
    }

    required init?(coder: NSCoder) {
        fatalError("ArchiveListView is created in code only")
    }

    // MARK: - Layout

    private func buildLayout() {
        let title = NSTextField(labelWithString: "Archive")
        title.font = Style.Fonts.emphasis
        title.textColor = Style.Colors.primaryText
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)

        clearButton.target = self
        clearButton.action = #selector(clear)
        clearButton.bezelStyle = .rounded
        clearButton.controlSize = .small
        clearButton.toolTip = "Remove every tab listed here from the archive. They will not come back."
        clearButton.setContentHuggingPriority(.required, for: .horizontal)

        let header = NSStackView(views: [title, clearButton])
        header.orientation = .horizontal
        header.distribution = .fill
        header.translatesAutoresizingMaskIntoConstraints = false

        configureTable()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = Style.Fonts.body
        emptyLabel.textColor = Style.Colors.secondaryText
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        [header, scrollView, emptyLabel].forEach(addSubview)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.contentInset),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.contentInset),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 18),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -18)
        ])

        setAccessibilityRole(.group)
        setAccessibilityLabel("Archive")
    }

    private func configureTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("archived"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        // A row acts on a single click -- it goes back to the sidebar -- so
        // there is no selection to draw. The hover pill is the only state.
        tableView.selectionHighlightStyle = .none
        tableView.rowHeight = ArchivedRowView.rowHeight
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.allowsEmptySelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.menu = rowMenu()
    }

    private func rowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Put Back", action: #selector(restoreClicked), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Copy Address", action: #selector(copyAddressClicked), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Remove From Archive", action: #selector(forgetClicked), keyEquivalent: ""))
        menu.items.forEach { $0.target = self }
        return menu
    }

    // MARK: - Contents

    /// Rebuilt with the session's records, newest first.
    ///
    /// - Parameter isArchivingEnabled: whether the sweep is switched on, which
    ///   is what the empty state has something different to say about.
    func show(_ entries: [Entry], isArchivingEnabled: Bool) {
        self.entries = entries
        tableView.reloadData()
        emptyLabel.stringValue = Self.emptyText(
            isEmpty: entries.isEmpty,
            isArchivingEnabled: isArchivingEnabled
        )
        emptyLabel.isHidden = !entries.isEmpty
        clearButton.isEnabled = !entries.isEmpty
        setAccessibilityLabel("Archive, \(entries.count) tab\(entries.count == 1 ? "" : "s")")
    }

    /// Two empty states, because "nothing is archived" would be wrong in one of
    /// them: nothing has ever been archived, and archiving being switched off
    /// entirely are different situations, and only the last is the user's next
    /// move. The window had a third, for a search that matched nothing, which a
    /// list with no search field cannot reach.
    private static func emptyText(isEmpty: Bool, isArchivingEnabled: Bool) -> String {
        guard isEmpty else { return "" }
        if !isArchivingEnabled {
            return "Nothing is archived.\nTurn on archiving in Settings \u{203a} General to have sleeping tabs move here."
        }
        return "Nothing is archived yet.\nSleeping tabs move here once they have been untouched for long enough."
    }

    // MARK: - Actions

    private var clickedEntry: Entry? {
        let row = tableView.clickedRow
        return entries.indices.contains(row) ? entries[row] : nil
    }

    @objc private func restoreClicked() {
        guard let entry = clickedEntry else { return }
        onRestore?(entry.record)
    }

    @objc private func forgetClicked() {
        guard let entry = clickedEntry else { return }
        onForget?(entry.record)
    }

    @objc private func copyAddressClicked() {
        guard let entry = clickedEntry else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.record.snapshot.url.absoluteString, forType: .string)
    }

    @objc private func clear() {
        onClear?()
    }
}

// MARK: - Table

extension ArchiveListView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    /// Rows are pressed, not selected: a click is the whole action, so the
    /// table is asked for no selection at all.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let entry = entries[row]

        let cell = tableView.makeView(withIdentifier: ArchivedRowView.reuseIdentifier, owner: self)
            as? ArchivedRowView ?? {
                let created = ArchivedRowView()
                created.identifier = ArchivedRowView.reuseIdentifier
                return created
            }()

        cell.configure(
            title: entry.record.title,
            url: entry.record.snapshot.url,
            spaceName: entry.spaceName,
            archivedAt: entry.record.archivedAt
        )
        cell.onPick = { [weak self] in self?.onRestore?(entry.record) }
        cell.onRemove = { [weak self] in self?.onForget?(entry.record) }
        return cell
    }
}
