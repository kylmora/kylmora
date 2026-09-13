import AppKit
import Combine

/// The downloads list.
///
/// A window of its own rather than a popover on the chrome: downloads outlive
/// the tab that started them (Kylmora gives the browser one window, so there
/// is no per-window list to attach to), and a list the user can leave open
/// while a large file transfers is the point of having one at all.
@MainActor
final class DownloadsWindowController: NSWindowController {
    private let manager: DownloadManager
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No Downloads")
    private let clearButton = NSButton(title: "Clear", target: nil, action: nil)

    private var downloads: [Download] = []
    private var cancellables: Set<AnyCancellable> = []

    /// Refreshes the "2.4 MB of 9.1 MB" line while something is transferring.
    /// The bar itself needs no help — it observes WebKit's `Progress` directly —
    /// so this only exists for the text, and only runs while the window is on
    /// screen with something to say.
    private var ticker: Task<Void, Never>?
    private static let tickInterval = Duration.milliseconds(500)

    init(manager: DownloadManager = .shared) {
        self.manager = manager

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 340),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "Downloads"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 200)
        window.setFrameAutosaveName("KylmoraDownloads")

        super.init(window: window)

        buildLayout()
        window.delegate = self
        observe()
        reload()
    }

    required init?(coder: NSCoder) {
        fatalError("DownloadsWindowController is created in code only")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        updateTicker()
    }

    private func buildLayout() {
        guard let contentView = window?.contentView else { return }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("download"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .inset
        tableView.rowHeight = DownloadCellView.rowHeight
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openSelected)
        tableView.menu = rowMenu()

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 15)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        clearButton.target = self
        clearButton.action = #selector(clearCompleted)
        clearButton.bezelStyle = .rounded
        clearButton.toolTip = "Remove finished downloads from this list. The files are not deleted."
        clearButton.translatesAutoresizingMaskIntoConstraints = false

        [scrollView, emptyLabel, clearButton].forEach(contentView.addSubview)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: clearButton.topAnchor, constant: -8),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            clearButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            clearButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])
    }

    private func rowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open", action: #selector(openClicked), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Show in Finder", action: #selector(revealClicked), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Copy Address", action: #selector(copyAddressClicked), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Remove From List", action: #selector(removeClicked), keyEquivalent: ""))
        menu.items.forEach { $0.target = self }
        return menu
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

    private func reload() {
        downloads = manager.downloads
        tableView.reloadData()
        emptyLabel.isHidden = !downloads.isEmpty
        clearButton.isEnabled = downloads.contains { $0.state != .running }
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

    private func updateTicker() {
        let wanted = (window?.isVisible ?? false) && manager.hasActiveDownloads
        guard wanted else {
            ticker?.cancel()
            ticker = nil
            return
        }
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                guard let self, !Task.isCancelled else { return }
                guard (self.window?.isVisible ?? false), self.manager.hasActiveDownloads else {
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

// MARK: - Menu validation

extension DownloadsWindowController: NSMenuItemValidation {
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

// MARK: - Window delegate

extension DownloadsWindowController: NSWindowDelegate {
    /// Nothing needs refreshing behind a closed window.
    func windowWillClose(_ notification: Notification) {
        ticker?.cancel()
        ticker = nil
    }
}

// MARK: - Table

extension DownloadsWindowController: NSTableViewDataSource, NSTableViewDelegate {
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
        return cell
    }
}
