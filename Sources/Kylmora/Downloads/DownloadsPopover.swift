import AppKit
import QuickLookUI
import Combine

/// The downloads list, in a popover hung off the sidebar's Downloads button.
///
/// A popover rather than a window of its own. Kylmora gives the browser one
/// window, and a list in its own frame beside it reads as a second app rather
/// than as part of the chrome; anchored to the button that owns it, the list
/// opens next to the thing it belongs to.
///
/// Closing on a click back into the page is the trade that comes with hanging
/// off a button, so nothing a download does depends on the list being open: the
/// transfer, the file and the saved row all carry on without it.
@MainActor
final class DownloadsPopover: NSViewController {
    /// The popover's width -- the same as the settings popover that hangs off
    /// the top bar's gear, so the two read as one kind of surface.
    static let width: CGFloat = 340
    /// How tall the list gets before it scrolls. A popover that grows to the
    /// height of the screen has stopped being a popover.
    static let maximumListHeight: CGFloat = DownloadCellView.rowHeight * 6
    /// What the empty state needs to say its piece without a window of blank
    /// space around it.
    static let emptyListHeight: CGFloat = 96

    private let manager: DownloadManager
    private let tableView = DownloadTableView()
    private let scrollView = NSScrollView()
    private let clearButton = NSButton(title: "Clear", target: nil, action: nil)
    private let emptyTitle = NSTextField(labelWithString: "No Downloads")
    private let emptyDetail = NSTextField(labelWithString: "Files you download show up here.")
    private var listHeight: NSLayoutConstraint?

    private var downloads: [Download] = []
    private var cancellables: Set<AnyCancellable> = []

    /// Refreshes the "2.4 MB of 9.1 MB" line while something is transferring.
    /// The bars need no help -- they observe WebKit's `Progress` directly -- so
    /// this exists only for the text, and only while the list is on screen.
    private var ticker: Task<Void, Never>?
    private static let tickInterval = Duration.milliseconds(500)

    /// The popover is on screen, which is the only time the progress text is
    /// worth recomputing. Driven by the popover's own delegate callbacks.
    private var isShown = false

    init(manager: DownloadManager) {
        self.manager = manager
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("DownloadsPopover is created in code only")
    }

    // MARK: - Layout

    override func loadView() {
        let container = NSView()

        let title = NSTextField(labelWithString: "Downloads")
        title.font = Style.Fonts.emphasis
        title.textColor = Style.Colors.primaryText
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)

        clearButton.target = self
        clearButton.action = #selector(clearCompleted)
        clearButton.bezelStyle = .rounded
        clearButton.controlSize = .small
        clearButton.toolTip = "Remove finished downloads from this list. The files are not deleted."
        clearButton.setContentHuggingPriority(.required, for: .horizontal)

        let header = NSStackView(views: [title, clearButton])
        header.orientation = .horizontal
        header.distribution = .fill
        header.translatesAutoresizingMaskIntoConstraints = false

        let empty = emptyStack

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        configureTable()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        [header, separator, scrollView, empty].forEach(container.addSubview)

        let height = scrollView.heightAnchor.constraint(equalToConstant: Self.emptyListHeight)
        listHeight = height

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Self.width),

            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            separator.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            height,

            // Centred on the list rather than pinned to it, so the two lines of
            // the empty state sit together in the middle of the space.
            empty.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor)
        ])

        view = container
    }

    /// The empty state, in the app's own type rather than a window's.
    private lazy var emptyStack: NSStackView = {
        emptyTitle.font = Style.Fonts.body
        emptyTitle.textColor = Style.Colors.secondaryText
        emptyDetail.font = Style.Fonts.badge
        emptyDetail.textColor = Style.Colors.tertiaryText
        for label in [emptyTitle, emptyDetail] {
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        let stack = NSStackView(views: [emptyTitle, emptyDetail])
        stack.orientation = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private func configureTable() {
        tableView.onQuickLook = { [weak self] in self?.quickLook() }
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("download"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        // Rows draw their own hover and selection pill, which the table's own
        // highlight cannot be -- the same split the sidebar uses.
        tableView.style = .plain
        tableView.selectionHighlightStyle = .none
        tableView.rowHeight = DownloadCellView.rowHeight
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openSelected)
        tableView.menu = rowMenu()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observe()
        reload()
    }

    private func observe() {
        manager.changes
            .sink { [weak self] change in
                guard let self else { return }
                switch change {
                case .list:
                    self.reload()
                case .download(let download):
                    self.refresh(download)
                }
                self.updateTicker()
            }
            .store(in: &cancellables)
    }

    // MARK: - Refreshing

    /// Whether the popover is showing its empty state. Exposed so the two
    /// states can be told apart without walking the view tree.
    var isShowingEmptyState: Bool { !emptyStack.isHidden }

    /// Re-reads the manager's list and resizes to it. Called by the manager as
    /// well as here, because a row can finish while the list is closed.
    func reload() {
        downloads = manager.downloads
        tableView.reloadData()
        emptyStack.isHidden = !downloads.isEmpty
        clearButton.isEnabled = downloads.contains { $0.state != .running }
        resize()
    }

    /// The list is as tall as what it holds, up to the point where it scrolls,
    /// and the empty state is a short panel rather than a tall blank one.
    private func resize() {
        let rows = CGFloat(downloads.count) * DownloadCellView.rowHeight
        listHeight?.constant = downloads.isEmpty
            ? Self.emptyListHeight
            : min(rows, Self.maximumListHeight)
        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: Self.width, height: view.fittingSize.height)
    }

    /// Redraws one row in place, so a finishing download does not throw away
    /// the selection or the scroll position of the whole list.
    private func refresh(_ download: Download) {
        guard let index = downloads.firstIndex(where: { $0 === download }) else { return reload() }
        configureCell(at: index)
        clearButton.isEnabled = downloads.contains { $0.state != .running }
    }

    private func configureCell(at index: Int) {
        guard let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? DownloadCellView
        else { return }
        cell.configure(with: downloads[index])
    }

    // MARK: - The progress ticker

    private func updateTicker() {
        guard isShown, manager.hasActiveDownloads else {
            ticker?.cancel()
            ticker = nil
            return
        }
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                guard let self, !Task.isCancelled else { return }
                guard self.isShown, self.manager.hasActiveDownloads else {
                    self.ticker = nil
                    return
                }
                self.tickVisibleRows()
            }
        }
    }

    /// Only the rows on screen and only the ones actually moving.
    private func tickVisibleRows() {
        let visible = tableView.rows(in: tableView.visibleRect)
        for index in visible.lowerBound..<visible.upperBound
        where downloads.indices.contains(index) && downloads[index].state == .running {
            configureCell(at: index)
        }
    }

    // MARK: - The row menu

    private func rowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open", action: #selector(openClicked), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Show in Finder", action: #selector(revealClicked), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quick Look", action: #selector(quickLookClicked), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Copy Address", action: #selector(copyAddressClicked), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Remove From List", action: #selector(removeClicked), keyEquivalent: ""))
        menu.items.forEach { $0.target = self }
        return menu
    }

    // MARK: - Actions

    private var clickedDownload: Download? {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        return downloads.indices.contains(row) ? downloads[row] : nil
    }

    /// The one action a row currently affords, which is what its button shows.
    private func performRowAction(_ download: Download) {
        switch download.state {
        case .running: manager.cancel(download)
        case .finished: manager.revealInFinder(download)
        case .failed, .cancelled:
            if download.host != nil { manager.retry(download) } else { manager.remove(download) }
        }
    }

    @objc private func openSelected() {
        guard let download = clickedDownload, download.fileExists else { return }
        manager.open(download)
    }

    @objc private func openClicked() { openSelected() }

    /// The file under the cursor or selection, if it is on disk.
    var quickLookURL: URL? {
        guard let download = clickedDownload, download.fileExists else { return nil }
        return download.destination
    }

    @objc private func quickLookClicked() { quickLook() }

    /// Space bar, like the Finder: the file in a Quick Look panel.
    func quickLook() {
        guard quickLookURL != nil, let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func revealClicked() {
        guard let download = clickedDownload, download.fileExists else { return }
        manager.revealInFinder(download)
    }

    @objc private func copyAddressClicked() {
        guard let download = clickedDownload else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(download.sourceURL.absoluteString, forType: .string)
    }

    @objc private func removeClicked() {
        guard let download = clickedDownload else { return }
        manager.remove(download)
    }

    @objc private func clearCompleted() {
        manager.clearCompleted()
    }
}

// MARK: - Popover delegate

extension DownloadsPopover: NSPopoverDelegate {
    /// The one moment the progress text is worth walking: while the list is on
    /// screen.
    func popoverDidShow(_ notification: Notification) {
        isShown = true
        updateTicker()
    }

    func popoverDidClose(_ notification: Notification) {
        isShown = false
        updateTicker()
    }
}

// MARK: - Menu validation

extension DownloadsPopover: NSMenuItemValidation {
    /// Open and Show in Finder are offered only when the file is really there.
    /// A download can be moved or deleted in Finder behind our back, and a menu
    /// item that quietly does nothing is worse than one that is dimmed.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let download = clickedDownload else { return false }
        switch menuItem.action {
        case #selector(openClicked), #selector(revealClicked): return download.fileExists
        default: return true
        }
    }
}

// MARK: - Table

extension DownloadsPopover: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        downloads.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard downloads.indices.contains(row) else { return nil }
        let download = downloads[row]

        let cell = tableView.makeView(withIdentifier: DownloadCellView.reuseIdentifier, owner: self)
            as? DownloadCellView ?? {
                let created = DownloadCellView()
                created.identifier = DownloadCellView.reuseIdentifier
                return created
            }()

        cell.configure(with: download)
        cell.onAction = { [weak self] in self?.performRowAction(download) }
        cell.isSelected = row == tableView.selectedRow
        return cell
    }

    /// Rows draw their own pill, so both ends of a selection move have to be
    /// told -- the same arrangement the sidebar's tab list uses.
    func tableViewSelectionDidChange(_ notification: Notification) {
        for index in downloads.indices {
            let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? DownloadCellView
            cell?.isSelected = index == tableView.selectedRow
        }
    }
}

extension DownloadsPopover: @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        quickLookURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        quickLookURL as NSURL?
    }
}

/// The downloads table, with the space bar wired to Quick Look.
@MainActor
final class DownloadTableView: NSTableView {
    var onQuickLook: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            onQuickLook?()
            return
        }
        super.keyDown(with: event)
    }
}
