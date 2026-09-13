import AppKit
import WebKit

/// One line in the folder-tabs popup.
@MainActor
struct FolderTabsItem {
    let tabID: Tab.ID
    let url: URL
    let title: String
    /// Drives the "3 minutes ago" half of the subtitle.
    let lastActiveAt: Date
    /// The folder the tab is actually in, which is not always the folder that
    /// was hovered: a collapsed folder lists its subfolders' tabs too, and
    /// without this the list is a pile of titles with no idea where they came
    /// from.
    let folderName: String
    /// Only used to read the page's declared icon, and only when the tab
    /// already has a web view. Never created for the popup.
    let webView: WKWebView?
    let isPrivate: Bool

    init(
        tabID: Tab.ID,
        url: URL,
        title: String,
        lastActiveAt: Date,
        folderName: String,
        webView: WKWebView?,
        isPrivate: Bool
    ) {
        self.tabID = tabID
        self.url = url
        self.title = title
        self.lastActiveAt = lastActiveAt
        self.folderName = folderName
        self.webView = webView
        self.isPrivate = isPrivate
    }

    /// Everything the search field matches against. The host is included
    /// because half of what people remember about a tab is the site, not the
    /// title the site chose.
    var searchText: String {
        [title, url.host() ?? "", url.path()].joined(separator: " ").lowercased()
    }
}

/// The popup a collapsed folder shows instead of a "+N" badge.
///
/// This replaces the native overflow count, and it is the better
/// trade: a badge tells you a number, a searchable list tells you which tab. It
/// appears on hover rather than on click because the gesture it replaces --
/// expanding the folder to look, then collapsing it again -- is not worth a
/// click either.
///
/// The controller owns the three timings that make hover-to-open bearable: a
/// dwell before it opens so passing the pointer over a folder does nothing, a
/// grace period after leaving so the diagonal trip from the label to the list
/// does not dismiss it, and an outright cancel when a drag starts, because a
/// popup appearing under a dragged tab is never what was wanted.
@MainActor
final class FolderTabsPopoverController: NSObject, NSPopoverDelegate {
    static let hoverDelay: TimeInterval = 0.5
    /// Long enough to cross the gap between the label and the popup.
    static let leaveGrace: TimeInterval = 0.2

    /// Called with the tab the user picked.
    var onSelect: ((Tab.ID) -> Void)?

    private var popover: NSPopover?
    private var content: FolderTabsListViewController?
    private var openTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?

    var isShown: Bool { popover?.isShown ?? false }

    /// Opens the popup after the dwell, unless something cancels first.
    func scheduleShow(
        items: [FolderTabsItem],
        folderName: String,
        relativeTo rect: NSRect,
        of view: NSView
    ) {
        closeTask?.cancel()
        closeTask = nil
        guard !items.isEmpty else { return }
        if isShown {
            content?.show(items: items)
            return
        }
        openTask?.cancel()
        openTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.hoverDelay))
            guard !Task.isCancelled, let self else { return }
            self.present(items: items, folderName: folderName, relativeTo: rect, of: view)
        }
    }

    /// The pointer left the label or the list. Closes after the grace period,
    /// so moving between the two does not count as leaving.
    func scheduleHide() {
        openTask?.cancel()
        openTask = nil
        closeTask?.cancel()
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.leaveGrace))
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    /// The pointer came back before the grace ran out.
    func cancelHide() {
        closeTask?.cancel()
        closeTask = nil
    }

    /// A drag started. Nothing about this popup is wanted during a drag, and it
    /// must not be left half-scheduled either.
    func cancel() {
        openTask?.cancel()
        openTask = nil
        close()
    }

    func close() {
        closeTask?.cancel()
        closeTask = nil
        popover?.performClose(nil)
        popover = nil
        content = nil
    }

    private func present(
        items: [FolderTabsItem],
        folderName: String,
        relativeTo rect: NSRect,
        of view: NSView
    ) {
        guard view.window != nil else { return }
        let list = FolderTabsListViewController()
        list.onSelect = { [weak self] id in
            self?.close()
            self?.onSelect?(id)
        }
        list.onPointerInside = { [weak self] inside in
            if inside { self?.cancelHide() } else { self?.scheduleHide() }
        }
        list.onCancel = { [weak self] in self?.close() }

        let popover = NSPopover()
        popover.contentViewController = list
        popover.behavior = .semitransient
        popover.delegate = self
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxX)
        list.show(items: items)
        list.view.setAccessibilityLabel("Tabs in \(folderName)")

        self.popover = popover
        self.content = list
    }

    func popoverDidClose(_ notification: Notification) {
        popover = nil
        content = nil
    }
}

/// The list inside the popup: a search field over a table of tabs.
@MainActor
final class FolderTabsListViewController: NSViewController {
    /// Sized 250 wide, list capped at 263, rows 40 with a 6-point radius. The
    /// cap is deliberately not a round number of rows -- it stops on a half
    /// row, which is how a list says "there is more" without a scrollbar
    /// having to appear.
    private static let width: CGFloat = 250
    private static let listMaxHeight: CGFloat = 263
    private static let rowHeight: CGFloat = 40

    var onSelect: ((Tab.ID) -> Void)?
    var onPointerInside: ((Bool) -> Void)?
    var onCancel: (() -> Void)?

    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var listHeight: NSLayoutConstraint?
    private var trackingArea: NSTrackingArea?

    private var allItems: [FolderTabsItem] = []
    private var visibleItems: [FolderTabsItem] = []

    /// One formatter, because building a `RelativeDateTimeFormatter` is not
    /// cheap and this list rebuilds on every keystroke.
    private let relativeTime: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    override func loadView() {
        let root = FolderTabsHoverView()
        root.onPointerInside = { [weak self] inside in self?.onPointerInside?(inside) }
        root.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "Search tabs"
        searchField.font = Style.Fonts.body
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tab"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.selectionHighlightStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = Style.Fonts.body
        emptyLabel.textColor = Style.Colors.secondaryText
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(searchField)
        root.addSubview(scrollView)
        root.addSubview(emptyLabel)

        let height = scrollView.heightAnchor.constraint(equalToConstant: Self.rowHeight)
        listHeight = height

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.width),
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
            height,
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor)
        ])

        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(searchField)
    }

    func show(items: [FolderTabsItem]) {
        allItems = items
        applyFilter()
    }

    private func applyFilter() {
        let query = searchField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        visibleItems = query.isEmpty ? allItems : allItems.filter { $0.searchText.contains(query) }

        let rows = CGFloat(max(visibleItems.count, 1))
        listHeight?.constant = min(rows * Self.rowHeight, Self.listMaxHeight)
        emptyLabel.stringValue = allItems.isEmpty ? "No tabs" : "No matches"
        emptyLabel.isHidden = !visibleItems.isEmpty
        tableView.reloadData()

        // Something is always selected, so Return means something the moment
        // the popup opens rather than only after an arrow key.
        if !visibleItems.isEmpty {
            tableView.selectRowIndexes([0], byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
    }

    private func move(by delta: Int) {
        guard !visibleItems.isEmpty else { return }
        let current = tableView.selectedRow
        let next = (current + delta + visibleItems.count) % visibleItems.count
        tableView.selectRowIndexes([next], byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    private func activateSelection() {
        guard visibleItems.indices.contains(tableView.selectedRow) else { return }
        onSelect?(visibleItems[tableView.selectedRow].tabID)
    }

    @objc private func rowClicked() {
        guard visibleItems.indices.contains(tableView.clickedRow) else { return }
        onSelect?(visibleItems[tableView.clickedRow].tabID)
    }

    private func subtitle(for item: FolderTabsItem) -> String {
        let when = relativeTime.localizedString(for: item.lastActiveAt, relativeTo: .now)
        return "\(when) • \(item.folderName)"
    }
}

extension FolderTabsListViewController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        applyFilter()
    }

    /// Up/Down/Tab move the selection and Return opens it, all without the
    /// search field ever losing focus -- which is the whole point of typing to
    /// filter.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)):
            move(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.insertBacktab(_:)):
            move(by: -1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            activateSelection()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        default:
            return false
        }
    }
}

extension FolderTabsListViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { visibleItems.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        FolderTabsRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visibleItems.indices.contains(row) else { return nil }
        let item = visibleItems[row]
        let identifier = NSUserInterfaceItemIdentifier("FolderTabsCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? FolderTabsCellView
            ?? FolderTabsCellView(identifier: identifier)
        cell.configure(
            title: item.title,
            subtitle: subtitle(for: item),
            url: item.url,
            webView: item.webView,
            isPrivate: item.isPrivate
        )
        return cell
    }
}

/// The row background. A 6-point radius rather than the sidebar's 14: this is a
/// list inside a popover, and a pill that round would read as a second set of
/// tabs floating over the first.
@MainActor
private final class FolderTabsRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        Style.Colors.rowHoverFill.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 2), xRadius: 6, yRadius: 6).fill()
    }

    override var isEmphasized: Bool {
        get { true }
        set { _ = newValue }
    }
}

@MainActor
private final class FolderTabsCellView: NSTableCellView {
    private let icon = FaviconImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        titleLabel.font = Style.Fonts.body
        titleLabel.textColor = Style.Colors.primaryText
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.usesSingleLineMode = true

        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = Style.Colors.secondaryText
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.cell?.usesSingleLineMode = true

        let text = NSStackView(views: [titleLabel, subtitleLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(text)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            text.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("FolderTabsCellView is created in code only")
    }

    func configure(title: String, subtitle: String, url: URL, webView: WKWebView?, isPrivate: Bool) {
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        icon.show(for: url, in: webView, isPrivate: isPrivate)
        setAccessibilityLabel("\(title), \(subtitle)")
    }
}

/// Reports pointer entry and exit for the whole popup, so the controller can
/// tell "moved onto the list" from "left the folder entirely".
@MainActor
private final class FolderTabsHoverView: NSView {
    var onPointerInside: ((Bool) -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let new = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(new)
        area = new
    }

    override func mouseEntered(with event: NSEvent) { onPointerInside?(true) }
    override func mouseExited(with event: NSEvent) { onPointerInside?(false) }
}
