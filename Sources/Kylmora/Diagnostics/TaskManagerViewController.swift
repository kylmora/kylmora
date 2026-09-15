import AppKit
import Foundation

/// Displays live per-tab CPU, RAM, and process metrics, with actions to suspend, reload, or close tabs.
@MainActor
final class TaskManagerViewController: NSViewController {
    private let session: BrowserSession
    private let searchField = NSSearchField()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let suspendButton = NSButton(title: "Suspend Tab", target: nil, action: nil)
    private let reloadButton = NSButton(title: "Reload Tab", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close Tab", target: nil, action: nil)

    private var allUsages: [TabResourceUsage] = []
    private var filteredUsages: [TabResourceUsage] = []
    private var refreshTimer: Timer?
    private var sortColumn: String = "memory"
    private var sortAscending: Bool = false

    init(session: BrowserSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("TaskManagerViewController is created in code only")
    }

    public override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 440))
        view = root

        setupViews(in: root)
        refreshMetrics()
    }

    public override func viewWillAppear() {
        super.viewWillAppear()
        startTimer()
    }

    public override func viewWillDisappear() {
        super.viewWillDisappear()
        stopTimer()
    }

    private func setupViews(in root: NSView) {
        summaryLabel.font = .systemFont(ofSize: 12, weight: .medium)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "Filter tabs, domains, or spaces…"
        searchField.target = self
        searchField.action = #selector(filterChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let topBar = NSStackView(views: [summaryLabel, searchField])
        topBar.orientation = .horizontal
        topBar.distribution = .fill
        topBar.alignment = .centerY
        topBar.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(equalToConstant: 220).isActive = true

        setupTableView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        suspendButton.bezelStyle = .rounded
        suspendButton.target = self
        suspendButton.action = #selector(suspendSelectedTab)
        suspendButton.isEnabled = false

        reloadButton.bezelStyle = .rounded
        reloadButton.target = self
        reloadButton.action = #selector(reloadSelectedTab)
        reloadButton.isEnabled = false

        closeButton.bezelStyle = .rounded
        closeButton.target = self
        closeButton.action = #selector(closeSelectedTab)
        closeButton.isEnabled = false

        let buttonBar = NSStackView(views: [suspendButton, reloadButton, closeButton])
        buttonBar.orientation = .horizontal
        buttonBar.spacing = 8
        buttonBar.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(topBar)
        root.addSubview(scrollView)
        root.addSubview(buttonBar)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            topBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            topBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: buttonBar.topAnchor, constant: -12),

            buttonBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            buttonBar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14)
        ])
    }

    private func setupTableView() {
        let columns: [(id: String, title: String, width: CGFloat)] = [
            ("site", "Tab / Page", 300),
            ("space", "Space", 90),
            ("memory", "Memory", 100),
            ("cpu", "CPU", 70),
            ("pid", "PID", 60)
        ]

        for col in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(col.id))
            column.title = col.title
            column.width = col.width
            column.sortDescriptorPrototype = NSSortDescriptor(key: col.id, ascending: true)
            tableView.addTableColumn(column)
        }

        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.target = self
        tableView.doubleAction = #selector(tableDoubleClicked)
    }

    private func startTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshMetrics()
            }
        }
    }

    private func stopTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    @objc public func refreshMetrics() {
        allUsages = TabResourceMonitor.shared.sampleAllTabs(in: session)
        applyFilterAndSort()

        let totalStats = TabResourceMonitor.shared.sampleTotalMemory(in: session)
        let totalTabs = allUsages.count
        let suspendedCount = allUsages.filter(\.isSuspended).count
        let activeCount = totalTabs - suspendedCount

        let totalMB = Double(totalStats.total) / (1024 * 1024)
        let appMB = Double(totalStats.browser) / (1024 * 1024)
        let webMB = Double(totalStats.webContent) / (1024 * 1024)

        summaryLabel.stringValue = "\(totalTabs) tabs (\(activeCount) active, \(suspendedCount) suspended) • Total RAM: \(String(format: "%.0f MB", totalMB)) (Kylmora: \(String(format: "%.0f MB", appMB)), WebKit: \(String(format: "%.0f MB", webMB)))"

        tableView.reloadData()
        updateButtonStates()
    }

    @objc private func filterChanged() {
        applyFilterAndSort()
        tableView.reloadData()
        updateButtonStates()
    }

    private func applyFilterAndSort() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty {
            filteredUsages = allUsages
        } else {
            filteredUsages = allUsages.filter {
                $0.title.lowercased().contains(query) ||
                $0.domain.lowercased().contains(query) ||
                $0.spaceName.lowercased().contains(query)
            }
        }

        filteredUsages.sort { a, b in
            let result: Bool
            switch sortColumn {
            case "memory":
                result = a.memoryBytes < b.memoryBytes
            case "cpu":
                result = a.cpuPercentage < b.cpuPercentage
            case "space":
                result = a.spaceName.localizedCaseInsensitiveCompare(b.spaceName) == .orderedAscending
            case "pid":
                result = (a.pid ?? 0) < (b.pid ?? 0)
            default: // "site"
                result = a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
            return sortAscending ? result : !result
        }
    }

    private func updateButtonStates() {
        let selectedIndex = tableView.selectedRow
        guard selectedIndex >= 0 && selectedIndex < filteredUsages.count else {
            suspendButton.isEnabled = false
            reloadButton.isEnabled = false
            closeButton.isEnabled = false
            return
        }

        let usage = filteredUsages[selectedIndex]
        suspendButton.isEnabled = !usage.isSuspended
        reloadButton.isEnabled = true
        closeButton.isEnabled = true
    }

    @objc private func suspendSelectedTab() {
        let selectedIndex = tableView.selectedRow
        guard selectedIndex >= 0 && selectedIndex < filteredUsages.count else { return }
        let usage = filteredUsages[selectedIndex]

        if let tab = session.allTabs.first(where: { $0.id == usage.tabId }) {
            tab.unload()
            refreshMetrics()
        }
    }

    @objc private func reloadSelectedTab() {
        let selectedIndex = tableView.selectedRow
        guard selectedIndex >= 0 && selectedIndex < filteredUsages.count else { return }
        let usage = filteredUsages[selectedIndex]

        if let tab = session.allTabs.first(where: { $0.id == usage.tabId }) {
            tab.reload()
            refreshMetrics()
        }
    }

    @objc private func closeSelectedTab() {
        let selectedIndex = tableView.selectedRow
        guard selectedIndex >= 0 && selectedIndex < filteredUsages.count else { return }
        let usage = filteredUsages[selectedIndex]

        if let tab = session.allTabs.first(where: { $0.id == usage.tabId }) {
            _ = session.closeTab(tab)
            refreshMetrics()
        }
    }

    @objc private func tableDoubleClicked() {
        let selectedIndex = tableView.selectedRow
        guard selectedIndex >= 0 && selectedIndex < filteredUsages.count else { return }
        let usage = filteredUsages[selectedIndex]

        // Focus the selected tab
        if let space = session.spaces.first(where: { $0.tabs.contains(where: { $0.id == usage.tabId }) }),
           let tab = session.allTabs.first(where: { $0.id == usage.tabId }) {
            session.selectSpace(space)
            session.selectTab(tab)
        }
    }
}

extension TaskManagerViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredUsages.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filteredUsages.count, let column = tableColumn else { return nil }
        let usage = filteredUsages[row]
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])

        switch column.identifier.rawValue {
        case "site":
            var prefix = ""
            if usage.isMemoryHog {
                prefix = "⚠️ "
            } else if usage.isSuspended {
                prefix = "💤 "
            } else if usage.isPlayingAudio {
                prefix = "🔊 "
            }
            label.stringValue = "\(prefix)\(usage.title)"
            if usage.isMemoryHog {
                label.textColor = .systemOrange
            } else if usage.isSuspended {
                label.textColor = .secondaryLabelColor
            }
        case "space":
            label.stringValue = usage.spaceName
            label.textColor = .secondaryLabelColor
        case "memory":
            label.stringValue = usage.formattedMemory
            if usage.isMemoryHog {
                label.textColor = .systemRed
                label.font = .systemFont(ofSize: 12, weight: .bold)
            }
        case "cpu":
            label.stringValue = usage.formattedCPU
            if usage.isCpuHog {
                label.textColor = .systemRed
                label.font = .systemFont(ofSize: 12, weight: .bold)
            }
        case "pid":
            label.stringValue = usage.pid.map { String($0) } ?? "—"
            label.textColor = .tertiaryLabelColor
        default:
            break
        }

        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtonStates()
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else { return }
        sortColumn = key
        sortAscending = descriptor.ascending
        applyFilterAndSort()
        tableView.reloadData()
    }
}
