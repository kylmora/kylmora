import AppKit
import Foundation

/// A sleek popover displaying saved Reading List articles with search,
/// filtering, offline status, and read/unread toggles.
@MainActor
final class ReadingListPopover: NSPopover {
    private let listController: ReadingListViewController

    init(session: BrowserSession? = nil) {
        self.listController = ReadingListViewController(session: session)
        super.init()
        self.contentViewController = listController
        self.behavior = .transient
        self.contentSize = NSSize(width: 360, height: 480)
    }

    required init?(coder: NSCoder) {
        fatalError("ReadingListPopover is created in code only")
    }
}

@MainActor
final class ReadingListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let session: BrowserSession?
    private let store: ReadingListStore

    private let searchField = NSSearchField()
    private let filterSegment = NSSegmentedControl(labels: ["All", "Unread"], trackingMode: .selectOne, target: nil, action: nil)
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "No articles saved in Reading List")
    private let addCurrentButton = NSButton(title: "Add Current Page", target: nil, action: nil)

    private var displayedItems: [ReadingListItem] = []
    nonisolated(unsafe) private var observerToken: (any NSObjectProtocol)?

    init(store: ReadingListStore = .shared, session: BrowserSession? = nil) {
        self.store = store
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("ReadingListViewController is created in code only")
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 480))
        view = container

        // Header: Title + Add Current Page button
        let titleLabel = NSTextField(labelWithString: "Reading List")
        titleLabel.font = .systemFont(ofSize: 15, weight: .bold)

        addCurrentButton.bezelStyle = .rounded
        addCurrentButton.font = .systemFont(ofSize: 11)
        addCurrentButton.target = self
        addCurrentButton.action = #selector(addCurrentPage)

        let topHeader = NSStackView(views: [titleLabel, NSView(), addCurrentButton])
        topHeader.orientation = .horizontal
        topHeader.alignment = .centerY

        // Search + Segment
        searchField.placeholderString = "Search Reading List"
        searchField.target = self
        searchField.action = #selector(searchChanged)

        filterSegment.selectedSegment = 0
        filterSegment.target = self
        filterSegment.action = #selector(filterChanged)

        // Table
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ArticleColumn"))
        column.width = 330
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 64
        tableView.selectionHighlightStyle = .regular
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.isHidden = true

        let stack = NSStackView(views: [topHeader, searchField, filterSegment, scrollView])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        container.addSubview(emptyLabel)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor)
        ])

        observerToken = NotificationCenter.default.addObserver(
            forName: .readingListDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The observer is registered on `.main`, so this runs on the main
            // thread -- but the block is imported as `@Sendable` and the
            // compiler cannot prove it. Assume what is true.
            MainActor.assumeIsolated {
                self?.reloadItems()
            }
        }

        reloadItems()
    }

    deinit {
        if let observerToken {
            NotificationCenter.default.removeObserver(observerToken)
        }
    }

    @objc private func addCurrentPage() {
        guard let tab = session?.activeTab else { return }
        let url = tab.displayURL
        let title = tab.displayTitle
        store.add(url: url, title: title)
        session?.showToast?(Toast(
            symbolName: "eyeglasses",
            message: "Added to Reading List",
            identity: "reading-list-added"
        ))
    }

    @objc private func searchChanged() {
        reloadItems()
    }

    @objc private func filterChanged() {
        reloadItems()
    }

    private func reloadItems() {
        var items = filterSegment.selectedSegment == 1 ? store.unreadItems : store.items
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            items = items.filter {
                $0.title.lowercased().contains(query) || $0.host.lowercased().contains(query) || $0.previewText.lowercased().contains(query)
            }
        }
        displayedItems = items
        emptyLabel.isHidden = !displayedItems.isEmpty
        tableView.reloadData()
    }

    // MARK: - Table View
    func numberOfRows(in tableView: NSTableView) -> Int {
        displayedItems.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard displayedItems.indices.contains(row) else { return nil }
        let item = displayedItems[row]

        let cell = NSTableCellView()

        let titleLabel = NSTextField(wrappingLabelWithString: item.title)
        titleLabel.font = item.isRead ? .systemFont(ofSize: 13) : .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = item.isRead ? .secondaryLabelColor : .labelColor
        titleLabel.maximumNumberOfLines = 2

        let hostLabel = NSTextField(labelWithString: item.host)
        hostLabel.font = .systemFont(ofSize: 11)
        hostLabel.textColor = .tertiaryLabelColor

        let readButton = NSButton(
            image: NSImage(systemSymbolName: item.isRead ? "checkmark.circle.fill" : "circle", accessibilityDescription: "Toggle Read")!,
            target: self,
            action: #selector(toggleReadClicked(_:))
        )
        readButton.isBordered = false
        readButton.tag = row
        readButton.contentTintColor = item.isRead ? .systemGreen : .secondaryLabelColor

        let deleteButton = NSButton(
            image: NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")!,
            target: self,
            action: #selector(deleteClicked(_:))
        )
        deleteButton.isBordered = false
        deleteButton.tag = row
        deleteButton.contentTintColor = .secondaryLabelColor

        let textStack = NSStackView(views: [titleLabel, hostLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let rowStack = NSStackView(views: [readButton, textStack, deleteButton])
        rowStack.orientation = .horizontal
        rowStack.alignment = .centerY
        rowStack.spacing = 8
        rowStack.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(rowStack)
        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            rowStack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            rowStack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])

        return cell
    }

    @objc private func toggleReadClicked(_ sender: NSButton) {
        guard displayedItems.indices.contains(sender.tag) else { return }
        let item = displayedItems[sender.tag]
        store.toggleRead(id: item.id)
    }

    @objc private func deleteClicked(_ sender: NSButton) {
        guard displayedItems.indices.contains(sender.tag) else { return }
        let item = displayedItems[sender.tag]
        store.remove(id: item.id)
    }

    @objc private func rowDoubleClicked() {
        let row = tableView.clickedRow
        guard displayedItems.indices.contains(row) else { return }
        let item = displayedItems[row]

        if let session {
            if let activeTab = session.activeTab {
                activeTab.load(item.url)
            } else {
                _ = session.newTab(url: item.url)
            }
        }
    }
}
