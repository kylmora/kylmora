import AppKit

/// The list down the left of the Task Manager: the whole browser, then a row
/// per space wearing that space's own icon and colour, with what it is costing
/// at the trailing edge.
///
/// The same rail the Settings window uses, built from the same row, because it
/// is the same idea: a short list of places, one of them chosen. What is new is
/// the number on each row -- a rail that says "Work 1.2 GB, Personal 240 MB"
/// has already answered the question most people open this window with, before
/// they have clicked anything.
@MainActor
final class ActivityRailView: NSView {
    /// A scope was chosen.
    var onSelect: ((ActivityScope) -> Void)?

    private let scroll = NSScrollView()
    private let stack = TopDownStackView()
    private let heading = NSTextField(labelWithString: "")
    private var overviewRow: SettingsRailRow?
    private var spaceRows: [UUID: SettingsRailRow] = [:]
    private var spaceOrder: [UUID] = []
    private var scope: ActivityScope = .everything

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        heading.attributedStringValue = NSAttributedString(
            string: "SPACES",
            attributes: [
                .font: Style.Fonts.settingsGroup,
                .foregroundColor: Style.Colors.tertiaryText,
                .kern: 1.0
            ]
        )
        heading.translatesAutoresizingMaskIntoConstraints = false
        heading.setAccessibilityElement(false)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Style.SettingsUI.spineTileGap
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 16, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = stack
        addSubview(scroll)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Style.SettingsUI.spineWidth),
            // Clear of the traffic lights: the window has no titlebar of its
            // own, so the rail starts below where one would have been.
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: Style.SettingsUI.titlebarHeight),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("ActivityRailView is created in code only")
    }

    /// Builds the rows. Called when the set of spaces changes, not on every
    /// sample: rebuilding a list under the pointer every two seconds would
    /// throw away the hover and the scroll position with it.
    func build(spaces: [Space], accent: NSColor) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        spaceRows = [:]
        spaceOrder = spaces.map(\.id)

        let overview = SettingsRailRow(
            title: "Whole Browser",
            symbolName: "rectangle.3.group.fill",
            accent: accent
        ) { [weak self] in
            self?.onSelect?(.everything)
        }
        overviewRow = overview
        add(overview)

        guard !spaces.isEmpty else { return }
        stack.setCustomSpacing(Style.SettingsUI.spineGroupGap, after: overview)
        let headingRow = NSView()
        headingRow.translatesAutoresizingMaskIntoConstraints = false
        headingRow.addSubview(heading)
        NSLayoutConstraint.activate([
            headingRow.heightAnchor.constraint(equalToConstant: 18),
            heading.leadingAnchor.constraint(
                equalTo: headingRow.leadingAnchor,
                constant: Style.SettingsUI.railInset + 8
            ),
            heading.centerYAnchor.constraint(equalTo: headingRow.centerYAnchor)
        ])
        add(headingRow)

        for space in spaces {
            let row = SettingsRailRow(
                title: space.name.isEmpty ? "Untitled Space" : space.name,
                mark: Self.mark(for: space),
                accent: space.color
            ) { [weak self] in
                self?.onSelect?(.space(space.id))
            }
            spaceRows[space.id] = row
            add(row)
        }
        apply()
    }

    /// What a space wears in the rail.
    ///
    /// A space that chose an icon wears it, at the size the rail draws marks --
    /// a space with a rocket in the sidebar has a rocket here. The two cases
    /// that need care are the ones where the icon carries the space's own
    /// colour: a symbol is tinted with it, and a space that chose nothing *is*
    /// a dot of it, and either drawn on a tile of that same colour is a tile
    /// with nothing visible on it.
    private static func mark(for space: Space) -> SettingsRailRow.Mark {
        switch space.icon {
        case .automatic:
            return .plain
        case .symbol(let name):
            // Drawn white by the row, rather than in the space's colour.
            return .symbol(name)
        case .emoji, .custom:
            return .picture(space.dotImage(side: 15))
        }
    }

    private func add(_ row: NSView) {
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    /// Whether the rows still match the session's spaces, so the controller
    /// knows when a rebuild is actually needed.
    func matches(spaces: [Space]) -> Bool {
        spaceOrder == spaces.map(\.id)
    }

    func show(scope: ActivityScope) {
        self.scope = scope
        apply()
    }

    /// The live number on each row.
    func show(memoryBySpace: [UUID: UInt64]) {
        for (id, row) in spaceRows {
            row.setDetail(memoryBySpace[id].map(UsageFormat.memory) ?? "—")
        }
    }

    private func apply() {
        overviewRow?.isChosen = scope == .everything
        for (id, row) in spaceRows {
            // A page's row lights its space as well: drilling into a tab has
            // not left the space you were in, and a rail with nothing chosen
            // would say it had.
            row.isChosen = scope == .space(id) || scope == .tab(id)
        }
    }

    /// An `NSScrollView`'s document view hangs from the bottom of the clip by
    /// default, so a plain stack of rows is cut off at the top the moment the
    /// list is taller than the window.
    private final class TopDownStackView: NSStackView {
        override var isFlipped: Bool { true }
    }

    /// Lights the space a tab belongs to, since a tab scope carries the tab's
    /// identifier rather than its space's.
    func show(scope: ActivityScope, tabHome: UUID?) {
        self.scope = scope
        apply()
        if case .tab = scope, let tabHome {
            spaceRows[tabHome]?.isChosen = true
        }
    }
}
