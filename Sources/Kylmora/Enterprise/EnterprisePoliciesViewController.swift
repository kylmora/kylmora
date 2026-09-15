import AppKit

/// Displays the active enterprise and MDM policies enforced on the browser.
@MainActor
public final class EnterprisePoliciesViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let manager: EnterprisePolicyManager
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var policies: [EnforcedPolicy] = []
    private let emptyLabel = NSTextField(labelWithString: "No enterprise management policies are currently active on this device.")

    public init(manager: EnterprisePolicyManager = .shared) {
        self.manager = manager
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("EnterprisePoliciesViewController is created in code only")
    }

    public override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        view = container

        // Sizing
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 620),
            container.heightAnchor.constraint(equalToConstant: 480)
        ])

        buildLayout()
        reload()
    }

    private func buildLayout() {
        // Icon and Header
        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: "building.2.crop.circle.fill",
            accessibilityDescription: "Enterprise Management"
        )
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 32, weight: .regular)
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        // Honest about an unmanaged Mac: "Managed by Your Organization" over
        // an empty table told the reader the opposite of the truth.
        let isManaged = manager.isManaged
        let title = NSTextField(labelWithString: isManaged ? "Managed by \(manager.organizationName)" : "Enterprise Policies")
        title.font = .systemFont(ofSize: 18, weight: .bold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(wrappingLabelWithString: isManaged
            ? "Your system administrator has applied configuration policies to Kylmora using Apple Mobile Device Management (MDM) or Managed Preferences."
            : "Nothing is managed on this Mac. Policies arrive through Apple Mobile Device Management (MDM), Managed Preferences, or a policies.json file, and would be listed here.")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        let headerStack = NSStackView(views: [title, subtitle])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 3
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        let topBar = NSStackView(views: [icon, headerStack])
        topBar.orientation = .horizontal
        topBar.alignment = .centerY
        topBar.spacing = 14
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)

        // Table Setup
        let keyCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("key"))
        keyCol.title = "Policy"
        keyCol.width = 180

        let valueCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
        valueCol.title = "Enforced Value"
        valueCol.width = 300

        let statusCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("status"))
        statusCol.title = "Status"
        statusCol.width = 90

        tableView.addTableColumn(keyCol)
        tableView.addTableColumn(valueCol)
        tableView.addTableColumn(statusCol)
        tableView.headerView = NSTableHeaderView()
        tableView.style = .inset
        tableView.rowHeight = 32
        tableView.dataSource = self
        tableView.delegate = self
        tableView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        // Empty state label
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true
        view.addSubview(emptyLabel)

        // Bottom Bar
        let exportButton = NSButton(title: "Export Policies\u{2026}", target: self, action: #selector(exportPolicies))
        exportButton.bezelStyle = .rounded
        exportButton.translatesAutoresizingMaskIntoConstraints = false

        let doneButton = NSButton(title: "Done", target: self, action: #selector(dismissSheet))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        doneButton.translatesAutoresizingMaskIntoConstraints = false

        let bottomBar = NSView()
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(exportButton)
        bottomBar.addSubview(doneButton)
        view.addSubview(bottomBar)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            scrollView.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 16),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -16),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            bottomBar.heightAnchor.constraint(equalToConstant: 32),

            exportButton.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor),
            exportButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),

            doneButton.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor),
            doneButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor)
        ])
    }

    public func reload() {
        policies = manager.activePolicies
        tableView.reloadData()
        emptyLabel.isHidden = !policies.isEmpty
        scrollView.isHidden = policies.isEmpty
    }

    /// Closes the sheet however it was opened.
    ///
    /// The Settings spine puts this controller in a window of its own and
    /// runs that as a sheet on the Settings window. `dismiss(nil)` only knows
    /// about a controller presented by another controller, so on that path it
    /// did nothing, and a sheet has no close button: Done was the only way
    /// out and Done was broken.
    @objc private func dismissSheet() {
        if presentingViewController != nil {
            dismiss(nil)
        } else if let window = view.window, let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            view.window?.close()
        }
    }

    /// Escape closes it too, as it does every sheet.
    public override func cancelOperation(_ sender: Any?) {
        dismissSheet()
    }

    public var displayedPolicies: [EnforcedPolicy] {
        policies
    }

    public func exportPoliciesData() -> Data? {
        let exportDict: [String: Any] = [
            "Organization": manager.organizationName,
            "ExportDate": ISO8601DateFormatter().string(from: Date()),
            "Policies": Dictionary(uniqueKeysWithValues: policies.map { ($0.key.rawValue, $0.valueDescription) })
        ]
        var options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
        options.insert(.withoutEscapingSlashes)
        return try? JSONSerialization.data(withJSONObject: exportDict, options: options)
    }

    @objc private func exportPolicies() {
        guard let data = exportPoliciesData() else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Kylmora-Corporate-Policies.json"
        panel.prompt = "Export"
        panel.message = "Save active enterprise policies"

        panel.beginSheetModal(for: view.window ?? NSApp.keyWindow!) { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
    }

    // MARK: - NSTableViewDataSource & Delegate

    public func numberOfRows(in tableView: NSTableView) -> Int {
        policies.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard policies.indices.contains(row), let colId = tableColumn?.identifier.rawValue else { return nil }
        let policy = policies[row]

        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])

        switch colId {
        case "key":
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.stringValue = policy.key.title
            label.toolTip = "\(policy.key.rawValue): \(policy.key.summary)"
        case "value":
            label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingMiddle
            label.stringValue = policy.valueDescription
            label.toolTip = policy.valueDescription
        case "status":
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .systemGreen
            label.stringValue = "Enforced"
        default:
            break
        }

        return cell
    }
}
