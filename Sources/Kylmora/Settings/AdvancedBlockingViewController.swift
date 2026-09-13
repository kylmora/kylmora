import AppKit

/// Advanced content blocking settings: built-in filter lists, custom filter list
/// subscriptions, and the "My Rules" multiline Adblock Plus rule editor.
@MainActor
final class AdvancedBlockingViewController: NSViewController {
    var onDismiss: (() -> Void)?

    private let settings: Settings
    private let blocker: ContentBlocker
    private var checkboxes: [String: NSButton] = [:]

    private let segmentedControl = NSSegmentedControl(
        labels: ["Filter Lists", "Custom Lists", "My Rules"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )

    private let containerView = NSView()
    private var filterListsView: NSView!
    private var customListsView: NSView!
    private var myRulesView: NSView!

    // Custom lists UI
    private let customListStack = NSStackView()
    private var customScroll: NSScrollView!

    // My Rules UI
    private var rulesTextView: NSTextView!
    private let rulesCountLabel = NSTextField(labelWithString: "")

    init(settings: Settings = .shared, blocker: ContentBlocker = .shared) {
        self.settings = settings
        self.blocker = blocker
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("AdvancedBlockingViewController is created in code only")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 580))
        buildLayout()
    }

    private func buildLayout() {
        let title = NSTextField(labelWithString: "Advanced Content Blocking")
        title.font = .systemFont(ofSize: 17, weight: .bold)

        segmentedControl.selectedSegment = 0
        segmentedControl.target = self
        segmentedControl.action = #selector(segmentChanged)
        segmentedControl.translatesAutoresizingMaskIntoConstraints = false

        containerView.translatesAutoresizingMaskIntoConstraints = false

        buildFilterListsView()
        buildCustomListsView()
        buildMyRulesView()

        containerView.addSubview(filterListsView)
        containerView.addSubview(customListsView)
        containerView.addSubview(myRulesView)

        NSLayoutConstraint.activate([
            filterListsView.topAnchor.constraint(equalTo: containerView.topAnchor),
            filterListsView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            filterListsView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            filterListsView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),

            customListsView.topAnchor.constraint(equalTo: containerView.topAnchor),
            customListsView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            customListsView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            customListsView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),

            myRulesView.topAnchor.constraint(equalTo: containerView.topAnchor),
            myRulesView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            myRulesView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            myRulesView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])

        updateSegmentVisibility()

        let done = NSButton(title: "Done", target: self, action: #selector(dismissSheet))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        let footer = NSStackView(views: [NSView(), done])
        footer.orientation = .horizontal
        footer.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [title, segmentedControl, containerView, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),

            segmentedControl.widthAnchor.constraint(equalTo: stack.widthAnchor),
            containerView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    @objc private func segmentChanged() {
        updateSegmentVisibility()
        if segmentedControl.selectedSegment == 1 {
            rebuildCustomListRows()
        } else if segmentedControl.selectedSegment == 2 {
            updateRulesCount()
        }
    }

    private func updateSegmentVisibility() {
        let index = segmentedControl.selectedSegment
        filterListsView.isHidden = index != 0
        customListsView.isHidden = index != 1
        myRulesView.isHidden = index != 2
    }

    // MARK: - Filter Lists View (Segment 0)

    private func buildFilterListsView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let cookieCheckbox = NSButton(
            checkboxWithTitle: "Automatically reject cookie consent notices (OneTrust, Cookiebot, etc.)",
            target: self,
            action: #selector(cookieRejectToggled(_:))
        )
        cookieCheckbox.state = settings.autoRejectCookieBanners ? .on : .off
        cookieCheckbox.font = .systemFont(ofSize: 13, weight: .medium)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 4
        list.translatesAutoresizingMaskIntoConstraints = false
        let preferences = settings.contentBlocking
        for category in FilterList.Category.allCases {
            let header = NSTextField(labelWithString: category.title)
            header.font = .systemFont(ofSize: 13, weight: .semibold)
            list.addArrangedSubview(header)
            list.setCustomSpacing(6, after: header)
            for entry in FilterList.lists(in: category) {
                let row = makeRow(for: entry, isOn: preferences.isListChosen(entry))
                list.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            }
            if let last = list.arrangedSubviews.last { list.setCustomSpacing(14, after: last) }
        }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        scroll.documentView = document
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: document.topAnchor),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])

        let stack = NSStackView(views: [cookieCheckbox, divider, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            cookieCheckbox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            divider.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        filterListsView = root
    }

    @objc private func cookieRejectToggled(_ sender: NSButton) {
        settings.autoRejectCookieBanners = sender.state == .on
        CookieConsentAutoReject.shared.preferencesChanged()
    }

    private func makeRow(for list: FilterList, isOn: Bool) -> NSView {
        let checkbox = NSButton(checkboxWithTitle: list.name, target: self, action: #selector(toggled(_:)))
        checkbox.state = isOn ? .on : .off
        checkbox.identifier = NSUserInterfaceItemIdentifier(list.id)
        checkboxes[list.id] = checkbox

        let info = NSButton(
            image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: "About \(list.name)")!,
            target: self,
            action: #selector(showInfo(_:))
        )
        info.isBordered = false
        info.identifier = NSUserInterfaceItemIdentifier(list.id)
        info.setAccessibilityLabel("About \(list.name)")

        let row = NSStackView(views: [checkbox, NSView(), info])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    @objc private func toggled(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let list = FilterList.named(id) else { return }
        var preferences = settings.contentBlocking
        let chosen = sender.state == .on
        if chosen == list.isDefault {
            preferences.listOverrides[id] = nil
        } else {
            preferences.listOverrides[id] = chosen
        }
        settings.contentBlocking = preferences
        blocker.preferencesChanged()
    }

    @objc private func showInfo(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let list = FilterList.named(id) else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = FilterListInfoViewController(list: list, status: blocker.statuses[id] ?? .idle) { [weak self] in
            self?.blocker.refresh(list)
            popover.close()
        }
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxX)
    }

    // MARK: - Custom Lists View (Segment 1)

    private func buildCustomListsView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let blurb = NSTextField(wrappingLabelWithString: "Subscribe to third-party Adblock Plus or uBlock Origin filter lists by URL. Kylmora fetches and compiles them locally.")
        blurb.font = .systemFont(ofSize: 12)
        blurb.textColor = .secondaryLabelColor

        customListStack.orientation = .vertical
        customListStack.alignment = .leading
        customListStack.spacing = 8
        customListStack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(customListStack)
        scroll.documentView = document
        customScroll = scroll

        NSLayoutConstraint.activate([
            customListStack.topAnchor.constraint(equalTo: document.topAnchor, constant: 8),
            customListStack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 8),
            customListStack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -8),
            customListStack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])

        let addButton = NSButton(title: "+ Add Filter List\u{2026}", target: self, action: #selector(addCustomListTapped))
        addButton.bezelStyle = .rounded
        addButton.controlSize = .regular

        let stack = NSStackView(views: [blurb, scroll, addButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            blurb.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        customListsView = root
        rebuildCustomListRows()
    }

    private func rebuildCustomListRows() {
        for view in customListStack.arrangedSubviews {
            customListStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let lists = settings.customFilterLists
        if lists.isEmpty {
            let emptyLabel = NSTextField(labelWithString: "No custom filter lists added yet.")
            emptyLabel.font = .systemFont(ofSize: 12)
            emptyLabel.textColor = .tertiaryLabelColor
            customListStack.addArrangedSubview(emptyLabel)
            return
        }

        for item in lists {
            let checkbox = NSButton(checkboxWithTitle: item.name, target: self, action: #selector(customListToggled(_:)))
            checkbox.state = item.isEnabled ? .on : .off
            checkbox.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)

            let urlLabel = NSTextField(labelWithString: item.url.absoluteString)
            urlLabel.font = .systemFont(ofSize: 11)
            urlLabel.textColor = .secondaryLabelColor

            let textStack = NSStackView(views: [checkbox, urlLabel])
            textStack.orientation = .vertical
            textStack.alignment = .leading
            textStack.spacing = 2

            let status = blocker.customStatuses[item.id] ?? .idle
            let statusText: String = switch status {
            case .idle: "Ready"
            case .fetching: "Updating\u{2026}"
            case .ready(let count, _): "\(count) rules"
            case .failed(let msg): "Failed: \(msg)"
            }

            let statusLabel = NSTextField(labelWithString: statusText)
            statusLabel.font = .systemFont(ofSize: 11)
            statusLabel.textColor = .secondaryLabelColor

            let removeBtn = NSButton(
                image: NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")!,
                target: self,
                action: #selector(removeCustomListTapped(_:))
            )
            removeBtn.isBordered = false
            removeBtn.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)

            let row = NSStackView(views: [textStack, NSView(), statusLabel, removeBtn])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            row.translatesAutoresizingMaskIntoConstraints = false

            customListStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: customListStack.widthAnchor).isActive = true
        }
    }

    @objc private func customListToggled(_ sender: NSButton) {
        guard let idStr = sender.identifier?.rawValue, let uuid = UUID(uuidString: idStr) else { return }
        var lists = settings.customFilterLists
        guard let idx = lists.firstIndex(where: { $0.id == uuid }) else { return }
        lists[idx].isEnabled = sender.state == .on
        settings.customFilterLists = lists
        blocker.compileCustomLists()
    }

    @objc private func removeCustomListTapped(_ sender: NSButton) {
        guard let idStr = sender.identifier?.rawValue, let uuid = UUID(uuidString: idStr) else { return }
        var lists = settings.customFilterLists
        lists.removeAll(where: { $0.id == uuid })
        settings.customFilterLists = lists
        blocker.compileCustomLists()
        rebuildCustomListRows()
    }

    @objc private func addCustomListTapped() {
        let alert = NSAlert()
        alert.messageText = "Add Custom Filter List"
        alert.informativeText = "Enter a name and the subscription URL for the Adblock Plus / uBlock filter list:"
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let inputStack = NSStackView()
        inputStack.orientation = .vertical
        inputStack.spacing = 8

        let nameField = NSTextField(string: "")
        nameField.placeholderString = "List Name (e.g. Fanboy's Annoyances)"

        let urlField = NSTextField(string: "")
        urlField.placeholderString = "https://example.com/filter-list.txt"

        inputStack.addArrangedSubview(nameField)
        inputStack.addArrangedSubview(urlField)
        inputStack.frame = NSRect(x: 0, y: 0, width: 340, height: 60)
        nameField.widthAnchor.constraint(equalToConstant: 340).isActive = true
        urlField.widthAnchor.constraint(equalToConstant: 340).isActive = true

        alert.accessoryView = inputStack

        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawURL = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, let url = URL(string: rawURL), url.scheme == "https" || url.scheme == "http" else {
                return
            }
            let newList = CustomFilterList(name: name, url: url, isEnabled: true)
            var current = self.settings.customFilterLists
            current.append(newList)
            self.settings.customFilterLists = current
            self.blocker.compileCustomLists()
            self.rebuildCustomListRows()
        }
    }

    // MARK: - My Rules View (Segment 2)

    private func buildMyRulesView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let blurb = NSTextField(wrappingLabelWithString: "Write your own cosmetic hiding rules (domain.com##selector), network block rules (||ads.example.com^), or exception rules (@@||trusted.com^). One rule per line.")
        blurb.font = .systemFont(ofSize: 12)
        blurb.textColor = .secondaryLabelColor

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let textView = NSTextView()
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.string = settings.userRulesText
        textView.delegate = self
        rulesTextView = textView
        scroll.documentView = textView

        rulesCountLabel.font = .systemFont(ofSize: 11)
        rulesCountLabel.textColor = .secondaryLabelColor
        updateRulesCount()

        let applyBtn = NSButton(title: "Save & Apply Rules", target: self, action: #selector(saveRulesTapped))
        applyBtn.bezelStyle = .rounded

        let footerStack = NSStackView(views: [rulesCountLabel, NSView(), applyBtn])
        footerStack.orientation = .horizontal
        footerStack.alignment = .centerY
        footerStack.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [blurb, scroll, footerStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            blurb.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footerStack.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        myRulesView = root
    }

    private func updateRulesCount() {
        guard let text = rulesTextView?.string else { return }
        let output = AdblockRuleConverter().convert(text)
        rulesCountLabel.stringValue = "\(output.rules.count) valid rules (\(output.skipped) skipped)"
    }

    @objc private func saveRulesTapped() {
        guard let text = rulesTextView?.string else { return }
        settings.userRulesText = text
        blocker.compileUserRules()
        updateRulesCount()
    }

    @objc private func dismissSheet() {
        if let text = rulesTextView?.string, text != settings.userRulesText {
            settings.userRulesText = text
            blocker.compileUserRules()
        }
        onDismiss?()
        dismiss(nil)
    }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }
}

extension AdvancedBlockingViewController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        updateRulesCount()
    }
}

/// What one list is, where it comes from, and how it is doing.
@MainActor
private final class FilterListInfoViewController: NSViewController {
    private let list: FilterList
    private let status: ContentBlocker.ListStatus
    private let onRefresh: () -> Void

    init(list: FilterList, status: ContentBlocker.ListStatus, onRefresh: @escaping () -> Void) {
        self.list = list
        self.status = status
        self.onRefresh = onRefresh
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("FilterListInfoViewController is created in code only")
    }

    override func loadView() {
        let name = NSTextField(labelWithString: list.name)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        let summary = NSTextField(wrappingLabelWithString: list.summary)
        summary.font = .systemFont(ofSize: 12)
        let source = NSTextField(wrappingLabelWithString: "Source: \(list.url.absoluteString)\nLicence: \(list.licence)")
        source.font = .systemFont(ofSize: 11)
        source.textColor = .secondaryLabelColor
        let state = NSTextField(wrappingLabelWithString: Self.describe(status))
        state.font = .systemFont(ofSize: 11)
        state.textColor = .secondaryLabelColor

        let refresh = NSButton(title: "Update Now", target: self, action: #selector(refreshTapped))
        refresh.bezelStyle = .rounded
        refresh.controlSize = .small

        let stack = NSStackView(views: [name, summary, source, state, refresh])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
            container.widthAnchor.constraint(equalToConstant: 320),
            summary.widthAnchor.constraint(equalTo: stack.widthAnchor),
            source.widthAnchor.constraint(equalTo: stack.widthAnchor),
            state.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        view = container
    }

    @objc private func refreshTapped() { onRefresh() }

    private static func describe(_ status: ContentBlocker.ListStatus) -> String {
        switch status {
        case .idle: return "Not in use."
        case .fetching: return "Downloading\u{2026}"
        case .ready(let rules, let fetched):
            let when = fetched.formatted(date: .abbreviated, time: .shortened)
            return rules >= 0 ? "\(rules) rules, updated \(when)." : "Applied, updated \(when)."
        case .failed(let message): return "Could not be applied: \(message)"
        }
    }
}
