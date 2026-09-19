import AppKit

/// The top control bar of the Safari-style Tab Overview grid.
///
/// Houses space switching, instant search/filtering, tab count, New Tab button, and Done button.
@MainActor
final class TabOverviewHeaderView: NSView, NSSearchFieldDelegate {
    var onScopeChanged: ((TabOverviewScope) -> Void)?
    var onSearchChanged: ((String) -> Void)?
    var onNewTab: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let backgroundView = NSVisualEffectView()
    private let bottomDivider = NSBox()
    let scopeControl = NSSegmentedControl()
    let searchField = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private let newTabButton = NSButton()
    private let doneButton = NSButton()

    init() {
        super.init(frame: .zero)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("TabOverviewHeaderView is created in code only")
    }

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 52).isActive = true

        // Translucent Header Background
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.material = .headerView
        backgroundView.blendingMode = .withinWindow
        backgroundView.state = .active
        addSubview(backgroundView)

        // Bottom Divider
        bottomDivider.translatesAutoresizingMaskIntoConstraints = false
        bottomDivider.boxType = .separator
        addSubview(bottomDivider)

        // Scope Control
        scopeControl.translatesAutoresizingMaskIntoConstraints = false
        scopeControl.segmentCount = 2
        scopeControl.setLabel("Current Space", forSegment: 0)
        scopeControl.setLabel("All Spaces", forSegment: 1)
        scopeControl.selectedSegment = 0
        scopeControl.segmentStyle = .texturedRounded
        scopeControl.target = self
        scopeControl.action = #selector(didChangeScope(_:))
        addSubview(scopeControl)

        // Search Field
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search Open Tabs…"
        searchField.font = .systemFont(ofSize: 13)
        searchField.bezelStyle = .roundedBezel
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(didChangeSearchText(_:))
        addSubview(searchField)

        // Tab Count Label
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        addSubview(countLabel)

        // New Tab Button
        newTabButton.translatesAutoresizingMaskIntoConstraints = false
        newTabButton.bezelStyle = .rounded
        newTabButton.title = " New Tab"
        let plusConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
        newTabButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")?
            .withSymbolConfiguration(plusConfig)
        newTabButton.imagePosition = .imageLeading
        newTabButton.target = self
        newTabButton.action = #selector(didClickNewTab(_:))
        newTabButton.toolTip = "New Tab (⌘T)"
        addSubview(newTabButton)

        // Done Button
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        doneButton.bezelStyle = .rounded
        doneButton.title = "Done"
        doneButton.font = .systemFont(ofSize: 13, weight: .semibold)
        doneButton.target = self
        doneButton.action = #selector(didClickDone(_:))
        doneButton.keyEquivalent = "\r"
        doneButton.toolTip = "Close Tab Overview (Esc)"
        addSubview(doneButton)

        NSLayoutConstraint.activate([
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),

            bottomDivider.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomDivider.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomDivider.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomDivider.heightAnchor.constraint(equalToConstant: 1),

            scopeControl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            scopeControl.centerYAnchor.constraint(equalTo: centerYAnchor),

            searchField.centerXAnchor.constraint(equalTo: centerXAnchor),
            searchField.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            searchField.widthAnchor.constraint(lessThanOrEqualToConstant: 380),

            countLabel.trailingAnchor.constraint(equalTo: newTabButton.leadingAnchor, constant: -12),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            newTabButton.trailingAnchor.constraint(equalTo: doneButton.leadingAnchor, constant: -10),
            newTabButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            doneButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            doneButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            doneButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 64)
        ])
    }

    /// - Parameter spaceIcon: the mark on the space, or nil for one wearing
    ///   nothing. The segment carries it beside the name, so the overview says
    ///   which space it is showing the way every other list of spaces does.
    func update(
        scope: TabOverviewScope,
        spaceName: String,
        spaceIcon: NSImage? = nil,
        tabCount: Int,
        totalSpacesTabCount: Int
    ) {
        scopeControl.setLabel("\(spaceName) (\(tabCount))", forSegment: 0)
        scopeControl.setImage(spaceIcon, forSegment: 0)
        scopeControl.setImageScaling(.scaleProportionallyDown, forSegment: 0)
        scopeControl.setLabel("All Spaces (\(totalSpacesTabCount))", forSegment: 1)
        scopeControl.selectedSegment = scope.rawValue

        let count = (scope == .currentSpace) ? tabCount : totalSpacesTabCount
        countLabel.stringValue = "\(count) tab\(count == 1 ? "" : "s")"
    }

    func focusSearchField() {
        window?.makeFirstResponder(searchField)
    }

    @objc private func didChangeScope(_ sender: NSSegmentedControl) {
        guard let scope = TabOverviewScope(rawValue: sender.selectedSegment) else { return }
        onScopeChanged?(scope)
    }

    @objc private func didChangeSearchText(_ sender: NSSearchField) {
        onSearchChanged?(sender.stringValue)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField, field == searchField else { return }
        onSearchChanged?(field.stringValue)
    }

    @objc private func didClickNewTab(_ sender: Any?) {
        onNewTab?()
    }

    @objc private func didClickDone(_ sender: Any?) {
        onDismiss?()
    }
}
