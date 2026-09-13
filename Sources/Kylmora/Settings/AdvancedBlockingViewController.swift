import AppKit

/// The list chooser behind the Privacy pane's Advanced Settings button.
///
/// Every list in the catalogue, by category, with a checkbox and an info
/// button that says what the list is, where it comes from and whether it is
/// working. A sheet: it is a detail of one setting, not a place.
@MainActor
final class AdvancedBlockingViewController: NSViewController {
    var onDismiss: (() -> Void)?

    private let settings: Settings
    private let blocker: ContentBlocker
    private var checkboxes: [String: NSButton] = [:]

    init(settings: Settings = .shared, blocker: ContentBlocker = .shared) {
        self.settings = settings
        self.blocker = blocker
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("AdvancedBlockingViewController is created in code only")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 520))
        buildLayout()
    }

    private func buildLayout() {
        let title = NSTextField(labelWithString: "Advanced Ad Block Settings")
        title.font = .systemFont(ofSize: 17, weight: .bold)

        let blurb = NSTextView()
        blurb.isEditable = false
        blurb.isSelectable = true
        blurb.drawsBackground = false
        blurb.textContainerInset = .zero
        blurb.textContainer?.lineFragmentPadding = 0
        let text = NSMutableAttributedString(
            string: "Block common components found across the web by using additional rules and filters. ",
            attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
        )
        text.append(NSAttributedString(string: "Learn more", attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .link: URL(string: "https://easylist.to/")!,
            .foregroundColor: NSColor.linkColor
        ]))
        blurb.textStorage?.setAttributedString(text)
        blurb.translatesAutoresizingMaskIntoConstraints = false
        blurb.heightAnchor.constraint(equalToConstant: 40).isActive = true

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

        let done = NSButton(title: "Done", target: self, action: #selector(dismissSheet))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        let footer = NSStackView(views: [NSView(), done])
        footer.orientation = .horizontal
        footer.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [title, blurb, scroll, footer])
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
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func makeRow(for list: FilterList, isOn: Bool) -> NSView {
        let checkbox = NSButton(checkboxWithTitle: list.name, target: self, action: #selector(toggled(_:)))
        checkbox.state = isOn ? .on : .off
        checkbox.identifier = NSUserInterfaceItemIdentifier(list.id)
        checkboxes[list.id] = checkbox

        let info = NSButton(image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: "About \(list.name)")!,
                            target: self, action: #selector(showInfo(_:)))
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
        // Back at the default, the override goes rather than staying as a
        // copy of it, so a future change of default reaches this user.
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

    @objc private func dismissSheet() {
        onDismiss?()
        dismiss(nil)
    }

    /// The scroll view's document, top-anchored so the list starts at the top
    /// rather than the bottom.
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
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
