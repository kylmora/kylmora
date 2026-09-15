import AppKit
import Combine

/// Full-window or content-overlay Safari-style Tab Overview grid controller.
///
/// Presents an interactive visual grid of all open tabs in the active space or across
/// all spaces, with live thumbnail snapshots, real-time search/filtering, keyboard navigation,
/// and tab management (select, close, new tab).
@MainActor
final class TabOverviewGridViewController: NSViewController {
    let session: BrowserSession

    var isOpen: Bool { view.superview != nil && view.alphaValue > 0.01 }
    var onDismissHandler: (() -> Void)?

    private let backgroundView = NSVisualEffectView()
    let headerView = TabOverviewHeaderView()
    private let scrollView = NSScrollView()
    private let documentView = FlippedGridView()
    private let emptyView = TabOverviewEmptyView()

    private var scope: TabOverviewScope = .currentSpace
    private var searchQuery: String = ""
    private var cards: [TabCardView] = []
    private var currentTabs: [(tab: Tab, space: Space)] = []
    private var selectedIndex: Int?
    private var cancellables: Set<AnyCancellable> = []
    private weak var previousFirstResponder: NSResponder?

    init(session: BrowserSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("TabOverviewGridViewController is created in code only")
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.translatesAutoresizingMaskIntoConstraints = false

        // Blur backdrop
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.material = .underWindowBackground
        backgroundView.blendingMode = .withinWindow
        backgroundView.state = .active
        view.addSubview(backgroundView)

        // Header view
        view.addSubview(headerView)

        // Scroll view for card grid
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = documentView
        view.addSubview(scrollView)

        // Empty state view
        view.addSubview(emptyView)
        emptyView.isHidden = true

        NSLayoutConstraint.activate([
            backgroundView.topAnchor.constraint(equalTo: view.topAnchor),
            backgroundView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            headerView.topAnchor.constraint(equalTo: view.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            emptyView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        wireHeader()
        wireEmptyView()
        documentView.onLayout = { [weak self] in
            self?.relayoutGrid()
        }
    }

    private func wireHeader() {
        headerView.onScopeChanged = { [weak self] newScope in
            self?.scope = newScope
            self?.reloadGrid()
        }

        headerView.onSearchChanged = { [weak self] text in
            self?.searchQuery = text
            self?.reloadGrid()
        }

        headerView.onNewTab = { [weak self] in
            self?.createNewTabAndDismiss()
        }

        headerView.onDismiss = { [weak self] in
            self?.dismissOverview()
        }
    }

    private func wireEmptyView() {
        emptyView.onAction = { [weak self] in
            guard let self else { return }
            if !self.searchQuery.isEmpty {
                self.headerView.searchField.stringValue = ""
                self.searchQuery = ""
                self.reloadGrid()
            } else {
                self.createNewTabAndDismiss()
            }
        }
    }

    // MARK: - Presentation & Dismissal

    func present(in hostView: NSView) {
        previousFirstResponder = hostView.window?.firstResponder

        if view.superview != hostView {
            view.removeFromSuperview()
            hostView.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: hostView.topAnchor),
                view.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
                view.bottomAnchor.constraint(equalTo: hostView.bottomAnchor)
            ])
        }

        view.alphaValue = 0
        reloadGrid()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.view.animator().alphaValue = 1.0
        }

        // Focus search field
        DispatchQueue.main.async { [weak self] in
            self?.headerView.focusSearchField()
        }

        observeSessionChanges()
    }

    func dismissOverview() {
        guard isOpen else { return }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.view.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.view.removeFromSuperview()
                self.cancellables.removeAll()
                if let prev = self.previousFirstResponder {
                    self.view.window?.makeFirstResponder(prev)
                }
                self.onDismissHandler?()
            }
        })
    }

    private func observeSessionChanges() {
        cancellables.removeAll()
        session.changes
            .receive(on: RunLoop.main)
            .sink { [weak self] change in
                guard let self, self.isOpen else { return }
                switch change {
                case .tabs, .spaces, .activeTab, .tab:
                    self.reloadGrid(preserveSelection: true)
                default:
                    break
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Data Reload & Filtering

    func reloadGrid(preserveSelection: Bool = false) {
        let activeSpace = session.activeSpace
        let allSpaces = session.spaces
        let totalCount = allSpaces.reduce(0) { $0 + $1.tabs.count }

        headerView.update(
            scope: scope,
            spaceName: activeSpace.name,
            tabCount: activeSpace.tabs.count,
            totalSpacesTabCount: totalCount
        )

        // Determine tabs
        let rawTabs: [(tab: Tab, space: Space)]
        switch scope {
        case .currentSpace:
            rawTabs = activeSpace.tabs.map { ($0, activeSpace) }
        case .allSpaces:
            rawTabs = allSpaces.flatMap { space in space.tabs.map { ($0, space) } }
        }

        // Apply search query filter
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            currentTabs = rawTabs
        } else {
            currentTabs = rawTabs.filter { item in
                let title = item.tab.pageTitle ?? ""
                let host = item.tab.url.host ?? ""
                let urlStr = item.tab.url.absoluteString
                return title.localizedCaseInsensitiveContains(query)
                    || host.localizedCaseInsensitiveContains(query)
                    || urlStr.localizedCaseInsensitiveContains(query)
            }
        }

        // Update empty view
        if currentTabs.isEmpty {
            emptyView.isHidden = false
            scrollView.isHidden = true
            if !query.isEmpty {
                emptyView.configure(
                    iconName: "magnifyingglass",
                    title: "No Matching Tabs",
                    subtitle: "No tabs found matching \"\(query)\"",
                    buttonTitle: "Clear Search"
                )
            } else {
                emptyView.configure(
                    iconName: "square.grid.2x2",
                    title: "No Open Tabs",
                    subtitle: "There are no open tabs in this space",
                    buttonTitle: "Open New Tab"
                )
            }
        } else {
            emptyView.isHidden = true
            scrollView.isHidden = false
        }

        buildCards()
        relayoutGrid()

        // Selection highlight
        if !preserveSelection || selectedIndex == nil || selectedIndex! >= currentTabs.count {
            if let activeIndex = currentTabs.firstIndex(where: { $0.tab.id == activeSpace.activeTabID }) {
                selectCard(at: activeIndex)
            } else if !currentTabs.isEmpty {
                selectCard(at: 0)
            } else {
                selectedIndex = nil
            }
        } else if let sel = selectedIndex {
            selectCard(at: sel)
        }
    }

    private func buildCards() {
        for card in cards {
            card.removeFromSuperview()
        }
        cards.removeAll()

        let activeTabID = session.activeSpace.activeTabID
        let showSpaceBadge = (scope == .allSpaces)

        for item in currentTabs {
            let card = TabCardView(tab: item.tab, space: item.space, showSpaceBadge: showSpaceBadge)
            card.isActive = (item.tab.id == activeTabID)

            card.onSelect = { [weak self] tab, space in
                self?.activateTab(tab, in: space)
            }

            card.onClose = { [weak self] tab in
                self?.closeTab(tab)
            }

            documentView.addSubview(card)
            cards.append(card)
        }
    }

    // MARK: - Layout Calculation

    private func relayoutGrid() {
        let width = scrollView.contentView.bounds.width
        guard width > 100, !cards.isEmpty else { return }

        let horizontalPadding: CGFloat = 24
        let topPadding: CGFloat = 20
        let bottomPadding: CGFloat = 32
        let interCardSpacing: CGFloat = 18

        let availableWidth = max(100, width - 2 * horizontalPadding)

        // Calculate columns
        let columns: Int
        if availableWidth < 520 {
            columns = 2
        } else if availableWidth < 840 {
            columns = 3
        } else if availableWidth < 1200 {
            columns = 4
        } else {
            columns = 5
        }

        let totalSpacing = CGFloat(columns - 1) * interCardSpacing
        let cardWidth = floor((availableWidth - totalSpacing) / CGFloat(columns))
        let cardHeight = floor(cardWidth * 0.65 + 58)

        var currentX = horizontalPadding
        var currentY = topPadding

        for (index, card) in cards.enumerated() {
            let col = index % columns
            if col == 0 && index > 0 {
                currentX = horizontalPadding
                currentY += cardHeight + interCardSpacing
            } else if col > 0 {
                currentX += cardWidth + interCardSpacing
            }

            card.frame = NSRect(x: currentX, y: currentY, width: cardWidth, height: cardHeight)
        }

        let totalHeight = currentY + cardHeight + bottomPadding
        documentView.frame = NSRect(x: 0, y: 0, width: width, height: max(totalHeight, scrollView.contentView.bounds.height))
    }

    // MARK: - Selection & Navigation

    private func selectCard(at index: Int) {
        guard cards.indices.contains(index) else { return }

        if let prevIndex = selectedIndex, cards.indices.contains(prevIndex) {
            cards[prevIndex].isHighlighted = false
        }

        selectedIndex = index
        let card = cards[index]
        card.isHighlighted = true
        card.scrollToVisible(card.bounds)
    }

    func navigateSelection(direction: NavigationDirection) {
        guard !cards.isEmpty else { return }
        let current = selectedIndex ?? 0

        let width = scrollView.contentView.bounds.width
        let availableWidth = max(100, width - 48)
        let columns: Int
        if availableWidth < 520 { columns = 2 }
        else if availableWidth < 840 { columns = 3 }
        else if availableWidth < 1200 { columns = 4 }
        else { columns = 5 }

        let target: Int
        switch direction {
        case .left:
            target = max(0, current - 1)
        case .right:
            target = min(cards.count - 1, current + 1)
        case .up:
            target = max(0, current - columns)
        case .down:
            target = min(cards.count - 1, current + columns)
        }

        selectCard(at: target)
    }

    enum NavigationDirection {
        case left, right, up, down
    }

    // MARK: - Actions

    private func activateTab(_ tab: Tab, in space: Space?) {
        if let space, space.id != session.activeSpace.id {
            session.selectSpace(space)
        }
        session.selectTab(tab)
        dismissOverview()
    }

    private func closeTab(_ tab: Tab) {
        _ = session.closeTab(tab)
        reloadGrid(preserveSelection: true)
    }

    private func createNewTabAndDismiss() {
        session.newTab()
        dismissOverview()
    }

    // MARK: - Keyboard Handling

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape
            if !searchQuery.isEmpty {
                headerView.searchField.stringValue = ""
                searchQuery = ""
                reloadGrid()
            } else {
                dismissOverview()
            }

        case 36, 76: // Return / Enter
            if let selectedIndex, currentTabs.indices.contains(selectedIndex) {
                let item = currentTabs[selectedIndex]
                activateTab(item.tab, in: item.space)
            } else {
                dismissOverview()
            }

        case 123: // Left Arrow
            navigateSelection(direction: .left)

        case 124: // Right Arrow
            navigateSelection(direction: .right)

        case 126: // Up Arrow
            navigateSelection(direction: .up)

        case 125: // Down Arrow
            navigateSelection(direction: .down)

        case 13 where event.modifierFlags.contains(.command): // ⌘W
            if let selectedIndex, currentTabs.indices.contains(selectedIndex) {
                closeTab(currentTabs[selectedIndex].tab)
            }

        case 17 where event.modifierFlags.contains(.command): // ⌘T
            createNewTabAndDismiss()

        case 3 where event.modifierFlags.contains(.command): // ⌘F
            headerView.focusSearchField()

        default:
            super.keyDown(with: event)
        }
    }

    override func magnify(with event: NSEvent) {
        // Pinching outward zooms back into selected tab
        if event.magnification > 0.15 {
            if let selectedIndex, currentTabs.indices.contains(selectedIndex) {
                let item = currentTabs[selectedIndex]
                activateTab(item.tab, in: item.space)
            } else {
                dismissOverview()
            }
        } else {
            super.magnify(with: event)
        }
    }
}

// MARK: - Flipped Grid View

@MainActor
final class FlippedGridView: NSView {
    var onLayout: (() -> Void)?

    override var isFlipped: Bool { true }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        onLayout?()
    }
}

// MARK: - Empty State View

@MainActor
final class TabOverviewEmptyView: NSView {
    var onAction: (() -> Void)?

    private let stack = NSStackView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        addSubview(stack)

        iconView.contentTintColor = .tertiaryLabelColor
        stack.addArrangedSubview(iconView)

        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        stack.addArrangedSubview(titleLabel)

        subtitleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center
        stack.addArrangedSubview(subtitleLabel)

        actionButton.bezelStyle = .rounded
        actionButton.target = self
        actionButton.action = #selector(didClickAction(_:))
        stack.addArrangedSubview(actionButton)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("TabOverviewEmptyView is created in code only")
    }

    func configure(iconName: String, title: String, subtitle: String, buttonTitle: String) {
        let config = NSImage.SymbolConfiguration(pointSize: 42, weight: .light)
        iconView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        actionButton.title = buttonTitle
    }

    @objc private func didClickAction(_ sender: Any?) {
        onAction?()
    }
}
