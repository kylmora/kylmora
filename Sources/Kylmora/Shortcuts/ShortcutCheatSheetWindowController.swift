import AppKit

/// Every shortcut on one page, grouped the way the Shortcuts pane groups
/// them, with custom commands at the end. ⌘/ opens it.
@MainActor
final class ShortcutCheatSheetWindowController: NSWindowController {
    private let manager: ShortcutManager
    private let automations: AutomationService

    init(manager: ShortcutManager = .shared, automations: AutomationService = .shared) {
        self.manager = manager
        self.automations = automations
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Keyboard Shortcuts"
        super.init(window: window)
        window.center()
        window.isReleasedWhenClosed = false
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("ShortcutCheatSheetWindowController is created in code only")
    }

    /// The rows as shown: a heading, then title and keys, per category.
    struct Row: Equatable {
        let heading: String?
        let title: String
        let keys: String
    }

    func rows() -> [Row] {
        var rows: [Row] = []
        for category in ShortcutCategory.allCases {
            let definitions = manager.definitions.filter { $0.category == category }
            guard !definitions.isEmpty else { continue }
            rows.append(Row(heading: category.rawValue, title: "", keys: ""))
            for definition in definitions {
                let keys = manager.displayString(for: definition.id)
                rows.append(Row(heading: nil, title: definition.title, keys: keys.isEmpty ? "—" : keys))
            }
        }
        let commands = automations.rules.rules.filter { $0.isEnabled && $0.trigger.kind == .manual }
        if !commands.isEmpty {
            rows.append(Row(heading: "Custom commands", title: "", keys: ""))
            for command in commands {
                let keys = manager.displayString(for: AutomationService.commandPrefix + command.id.uuidString)
                rows.append(Row(heading: nil, title: command.name, keys: keys.isEmpty ? "palette only" : keys))
            }
        }
        return rows
    }

    private func build() {
        guard let window else { return }
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        column.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 24, right: 24)
        column.translatesAutoresizingMaskIntoConstraints = false
        for row in rows() {
            if let heading = row.heading {
                let label = NSTextField(labelWithString: heading.uppercased())
                label.font = .systemFont(ofSize: 11, weight: .semibold)
                label.textColor = .secondaryLabelColor
                if let last = column.arrangedSubviews.last { column.setCustomSpacing(16, after: last) }
                column.addArrangedSubview(label)
                continue
            }
            let title = NSTextField(labelWithString: row.title)
            title.font = .systemFont(ofSize: 13)
            title.setContentHuggingPriority(.init(1), for: .horizontal)
            let keys = NSTextField(labelWithString: row.keys)
            keys.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            keys.textColor = .secondaryLabelColor
            keys.alignment = .right
            let line = NSStackView(views: [title, keys])
            line.orientation = .horizontal
            line.spacing = 12
            line.translatesAutoresizingMaskIntoConstraints = false
            column.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -48).isActive = true
        }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(column)
        scroll.documentView = document
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: document.topAnchor),
            column.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        window.contentView = scroll
    }
}
