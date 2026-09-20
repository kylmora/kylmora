import AppKit
import Foundation

/// The Task Manager: what the browser is costing, at whichever depth you ask.
///
/// Built out of the Settings window's vocabulary -- a washed canvas, a rail of
/// places down the left, cards floating on the right -- because the system box
/// with a table and three push buttons in it that used to be here was the task
/// manager every app has, and none of it was Kylmora.
///
/// Three scopes, one set of charts. The rail chooses the whole browser or one
/// space; clicking a page in the table or a bar in the chart goes one level
/// deeper into that page. Every scope answers the same four questions in the
/// same order -- what is it costing now, where does that go, which of the
/// things inside it is the heavy one, and what are the details -- so reading
/// the window is a skill you learn once.
@MainActor
final class TaskManagerViewController: NSViewController {
    /// Where these charts are being shown.
    ///
    /// The window has a rail of its own down the left. The Settings pane is
    /// already inside a window with a rail, so it swaps that for a pop-up in
    /// the header: two lists of places side by side, one inside the other,
    /// would be the same navigation drawn twice.
    enum Presentation {
        case window
        case embedded
    }

    private let session: BrowserSession
    private let presentation: Presentation

    // MARK: Chrome
    private let canvas = SettingsCanvasView()
    private let rail = ActivityRailView()
    /// The rail's stand-in when there is no room for a rail: a row of chips
    /// that scrolls sideways.
    private let scopeBar = ActivityScopeBar()
    private let backButton = NSButton(title: "", target: nil, action: nil)
    private let titleLabel = NSTextField(labelWithString: "Whole Browser")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let page = FlippedView()
    private let column = NSStackView()

    // MARK: Cards
    private let cpuCard = ActivityMetricCard(caption: "Processor", tint: .systemBlue, floorCeiling: 100)
    private let memoryCard = ActivityMetricCard(caption: "Memory", tint: .systemPurple, floorCeiling: 500)
    private let gpuCard = ActivityMetricCard(caption: "Graphics", tint: .systemTeal, floorCeiling: 100)
    private let compositionCard = ActivityCardView(caption: "Where the memory goes")
    private let composition = ActivityCompositionView()
    private let rankCard = ActivityCardView(caption: "Heaviest")
    private let ranks = ActivityBarListView()
    private let detailsCard = ActivityCardView(caption: "Details")
    private let stats = ActivityStatGridView()
    private let pagesCard = ActivityCardView(caption: "Pages")
    private let searchField = SettingsSearchField(skin: .control, placeholder: "Filter pages")
    private let tableView = NSTableView()
    private let tableScroll = FittingScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No pages here")

    // MARK: Actions
    private let suspendButton = NSButton(title: "Put to Sleep", target: nil, action: nil)
    private let reloadButton = NSButton(title: "Reload", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close Tab", target: nil, action: nil)
    private let focusButton = NSButton(title: "Go to Tab", target: nil, action: nil)

    // MARK: State
    private var scope: ActivityScope = .everything
    private var snapshot = ResourceSnapshot()
    /// The tabs of the scope the table is listing -- the whole browser, or one
    /// space. A page scope lists its siblings rather than itself alone: you
    /// drill into a page to look at it, not to lose the way back to the others.
    private var rows: [TabResourceUsage] = []
    private var sparklineCeiling: Double = 100
    private var refreshTimer: Timer?
    private var sortColumn = "memory"
    private var sortAscending = false
    private var query = ""

    init(session: BrowserSession, presentation: Presentation = .window) {
        self.session = session
        self.presentation = presentation
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("TaskManagerViewController is created in code only")
    }

    override func loadView() {
        switch presentation {
        case .window:
            view = canvas
            canvas.frame = NSRect(x: 0, y: 0, width: 980, height: 680)
            build()
            rail.build(spaces: session.spaces, accent: accent)
        case .embedded:
            let root = WindowAwareView()
            // Sampling costs something, so it happens while somebody is
            // looking. A pane inside another window does not reliably get the
            // appearance callbacks a window's own content view controller
            // does, so the timer follows the view being in a window at all.
            root.onWindowChange = { [weak self] window in
                guard let self else { return }
                if window == nil {
                    self.stopTimer()
                } else {
                    self.refreshMetrics()
                    self.startTimer()
                }
            }
            view = root
            buildEmbedded(in: root)
        }
        refreshMetrics()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        startTimer()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        stopTimer()
    }

    // MARK: - Building

    private func build() {
        rail.onSelect = { [weak self] scope in self?.choose(scope) }
        canvas.addSubview(rail)

        // A way back that names where it goes. "Back" on its own is a button
        // you have to remember the history of; "Work" is one you can read.
        backButton.isBordered = false
        backButton.font = Style.Fonts.settingsNote
        backButton.target = self
        backButton.action = #selector(goBack)
        backButton.isHidden = true
        backButton.translatesAutoresizingMaskIntoConstraints = false
        canvas.addSubview(backButton)

        titleLabel.font = Style.Fonts.settingsTitle
        titleLabel.textColor = Style.Colors.primaryText
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        canvas.addSubview(titleLabel)

        subtitleLabel.font = Style.Fonts.settingsNote
        subtitleLabel.textColor = Style.Colors.secondaryText
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        canvas.addSubview(subtitleLabel)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = page
        canvas.addSubview(scroll)

        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Style.SettingsUI.cardSpacing
        column.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(column)

        buildCards()

        let gutter = Style.SettingsUI.detailGutter
        NSLayoutConstraint.activate([
            rail.topAnchor.constraint(equalTo: canvas.topAnchor),
            rail.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
            rail.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),

            backButton.topAnchor.constraint(
                equalTo: canvas.topAnchor, constant: Style.SettingsUI.titlebarHeight - 4
            ),
            backButton.leadingAnchor.constraint(equalTo: rail.trailingAnchor, constant: gutter - 4),
            titleLabel.topAnchor.constraint(equalTo: backButton.bottomAnchor, constant: 2),
            titleLabel.leadingAnchor.constraint(equalTo: rail.trailingAnchor, constant: gutter),
            titleLabel.trailingAnchor.constraint(equalTo: canvas.trailingAnchor, constant: -gutter),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: rail.trailingAnchor),
            scroll.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),

            page.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            column.topAnchor.constraint(equalTo: page.topAnchor),
            column.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: gutter),
            column.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -gutter),
            column.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -gutter)
        ])
    }

    /// The same page, without a rail or a scroller of its own: the Settings
    /// window supplies both.
    private func buildEmbedded(in root: NSView) {
        scopeBar.onSelect = { [weak self] scope in self?.choose(scope) }

        subtitleLabel.font = Style.Fonts.settingsNote
        subtitleLabel.textColor = Style.Colors.secondaryText
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Style.SettingsUI.cardSpacing
        column.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(scopeBar)
        root.addSubview(subtitleLabel)
        root.addSubview(column)
        buildCards()

        NSLayoutConstraint.activate([
            scopeBar.topAnchor.constraint(equalTo: root.topAnchor),
            scopeBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scopeBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: scopeBar.bottomAnchor, constant: 6),
            // Two points in, so the *text* lines up with the plate above it and
            // the cards below: a label's frame sits two points outside the box
            // AppKit aligns it by, which is the difference between a line that
            // looks aligned and one that is.
            subtitleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 2),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor),
            column.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 14),
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
    }

    /// The chips the bar shows: the whole browser, every space, and -- only
    /// while you are looking at one -- the page you drilled into, so the row
    /// can show where you are rather than going blank.
    private func rebuildScopeOptions() {
        var items: [ActivityScopeBar.Item] = [
            ActivityScopeBar.Item(
                scope: .everything,
                title: "Whole Browser",
                detail: UsageFormat.memory(snapshot.totalMemoryBytes),
                symbol: "rectangle.3.group.fill",
                tint: session.activeSpace.color
            )
        ]
        let memory = memoryBySpace()
        for space in session.spaces {
            items.append(
                ActivityScopeBar.Item(
                    scope: .space(space.id),
                    title: space.name.isEmpty ? "Untitled Space" : space.name,
                    detail: memory[space.id].map(UsageFormat.memory) ?? "—",
                    // The space's own mark. The chip is a neutral plate rather
                    // than a tile of the space's colour, so even the plain
                    // coloured dot reads here.
                    image: space.dotImage(side: 14),
                    tint: space.color
                )
            )
        }
        if case .tab(let id) = scope, let usage = snapshot.tabs.first(where: { $0.tabId == id }) {
            items.append(
                ActivityScopeBar.Item(
                    scope: .tab(id),
                    title: usage.title,
                    detail: usage.formattedMemory,
                    symbol: usage.isSuspended ? "moon.zzz.fill" : "doc.fill",
                    tint: accent
                )
            )
        }
        scopeBar.show(items, selected: scope)
    }

    private func buildCards() {
        // The three headline cards, equal widths: they are read as a set, and
        // one that shrank because its number is shorter would suggest it
        // matters less.
        let metrics = NSStackView(views: [cpuCard, memoryCard, gpuCard])
        metrics.orientation = .horizontal
        metrics.distribution = .fillEqually
        metrics.spacing = 12
        metrics.translatesAutoresizingMaskIntoConstraints = false
        addToColumn(metrics)
        metrics.heightAnchor.constraint(equalToConstant: 168).isActive = true

        composition.translatesAutoresizingMaskIntoConstraints = false
        compositionCard.body.addArrangedSubview(composition)
        composition.widthAnchor.constraint(equalTo: compositionCard.body.widthAnchor).isActive = true
        addToColumn(compositionCard)

        ranks.onSelect = { [weak self] id in self?.chooseBar(id) }
        rankCard.body.addArrangedSubview(ranks)
        ranks.widthAnchor.constraint(equalTo: rankCard.body.widthAnchor).isActive = true
        addToColumn(rankCard)

        detailsCard.body.addArrangedSubview(stats)
        stats.widthAnchor.constraint(equalTo: detailsCard.body.widthAnchor).isActive = true
        addToColumn(detailsCard)

        buildTable()
        addToColumn(pagesCard)
    }

    private func addToColumn(_ view: NSView) {
        column.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }

    private func buildTable() {
        let columns: [(id: String, title: String, width: CGFloat)] = [
            ("site", "Page", 300),
            ("space", "Space", 110),
            ("memory", "Memory", 95),
            ("cpu", "CPU", 62),
            ("trend", "Last 2 min", 90),
            ("pid", "Process", 70)
        ]
        for spec in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
            column.title = spec.title
            column.width = spec.width
            // The page column is the one that gives. Without a floor under it
            // the table keeps its full width whatever it is put in, and inside
            // the Settings window -- which is narrower than the Task Manager's
            // own -- it simply hangs out past the edge of the pane.
            column.minWidth = spec.id == "site" ? 120 : spec.width * 0.6
            // The sparkline is a picture of the CPU column, so it sorts by the
            // same number rather than pretending to be a key of its own.
            column.sortDescriptorPrototype = NSSortDescriptor(
                key: spec.id == "trend" ? "cpu" : spec.id, ascending: true
            )
            tableView.addTableColumn(column)
        }
        tableView.headerView = SettingsTableHeader()
        tableView.rowHeight = 34
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.gridStyleMask = .solidHorizontalGridLineMask
        tableView.gridColor = Style.Colors.settingsHairline
        tableView.intercellSpacing = NSSize(width: 3, height: 1)
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(focusSelectedTab)

        tableScroll.documentView = tableView
        tableScroll.drawsBackground = false
        tableScroll.hasVerticalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.scrollerStyle = .overlay
        tableScroll.translatesAutoresizingMaskIntoConstraints = false

        searchField.onChange = { [weak self] text in
            self?.query = text
            self?.reloadTable()
        }

        emptyLabel.font = Style.Fonts.settingsNote
        emptyLabel.textColor = Style.Colors.tertiaryText
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true
        tableScroll.addSubview(emptyLabel)

        for button in [focusButton, suspendButton, reloadButton, closeButton] {
            button.target = self
            button.isEnabled = false
        }
        focusButton.action = #selector(focusSelectedTab)
        suspendButton.action = #selector(suspendSelectedTab)
        reloadButton.action = #selector(reloadSelectedTab)
        closeButton.action = #selector(closeSelectedTab)

        let actions = NSStackView(views: [
            SettingsControlPlate(focusButton, width: nil),
            SettingsControlPlate(suspendButton, width: nil),
            SettingsControlPlate(reloadButton, width: nil),
            SettingsControlPlate(closeButton, width: nil),
            NSView(),
            searchField
        ])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8
        actions.translatesAutoresizingMaskIntoConstraints = false

        pagesCard.body.addArrangedSubview(tableScroll)
        pagesCard.body.addArrangedSubview(actions)
        NSLayoutConstraint.activate([
            tableScroll.widthAnchor.constraint(equalTo: pagesCard.body.widthAnchor),
            // A window height's worth of table, and the page scrolls past it.
            // A table that grew with its contents put the actions under it off
            // the bottom of a busy browser's window.
            tableScroll.heightAnchor.constraint(equalToConstant: 260),
            actions.widthAnchor.constraint(equalTo: pagesCard.body.widthAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 190),
            emptyLabel.centerXAnchor.constraint(equalTo: tableScroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: tableScroll.centerYAnchor)
        ])
    }

    // MARK: - Scope

    /// The hue the whole window wears: the space you are looking at, or the
    /// space you are in when you are looking at everything. It washes the
    /// canvas, lights the rail and colours the bars, which is what makes this
    /// window belong to the browser it is measuring rather than to the system.
    private var accent: NSColor {
        switch scope {
        case .everything:
            return session.activeSpace.color
        case .space(let id):
            return session.spaces.first { $0.id == id }?.color ?? session.activeSpace.color
        case .tab(let id):
            let home = session.spaces.first { $0.tabs.contains { $0.id == id } }
            return home?.color ?? session.activeSpace.color
        }
    }

    /// What the window is showing, for anything outside it that needs to know
    /// -- which is, for now, the tests.
    var currentScope: ActivityScope { scope }

    /// Shows a scope from outside: a command, a test, or one day a click in the
    /// sidebar on the space you are already standing in.
    func show(scope: ActivityScope) {
        choose(scope)
    }

    private func choose(_ scope: ActivityScope) {
        self.scope = scope
        tableView.deselectAll(nil)
        refreshMetrics()
    }

    /// A bar in the ranked chart: a space when the whole browser is in front,
    /// a page otherwise.
    private func chooseBar(_ id: UUID) {
        if case .everything = scope, session.spaces.contains(where: { $0.id == id }) {
            choose(.space(id))
        } else {
            choose(.tab(id))
        }
    }

    @objc private func goBack() {
        switch scope {
        case .tab(let id):
            let home = session.spaces.first { $0.tabs.contains { $0.id == id } }
            choose(home.map { ActivityScope.space($0.id) } ?? .everything)
        case .space, .everything:
            choose(.everything)
        }
    }

    // MARK: - Refresh

    private func startTimer() {
        refreshTimer?.invalidate()
        // Two seconds. Faster and the CPU figure is mostly the noise of one
        // scheduling quantum; slower and a page that spikes while you are
        // watching it never shows up.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMetrics() }
        }
    }

    private func stopTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    @objc func refreshMetrics() {
        snapshot = TabResourceMonitor.shared.snapshot(in: session)

        // A scope can vanish under you: the space you were reading was closed,
        // the page you drilled into finished loading somewhere else. Falling
        // back up one level is the only thing that is never wrong.
        validateScope()

        switch presentation {
        case .window:
            if !rail.matches(spaces: session.spaces) {
                rail.build(spaces: session.spaces, accent: accent)
            }
            rail.show(scope: scope, tabHome: homeSpaceOfScopedTab)
            rail.show(memoryBySpace: memoryBySpace())
            canvas.accentHint = accent
        case .embedded:
            rebuildScopeOptions()
        }
        ranks.tint = accent

        updateHeader()
        updateMetricCards()
        updateComposition()
        updateRanks()
        updateStats()
        reloadTable()
    }

    private func validateScope() {
        switch scope {
        case .everything:
            break
        case .space(let id):
            if !session.spaces.contains(where: { $0.id == id }) { scope = .everything }
        case .tab(let id):
            if !snapshot.tabs.contains(where: { $0.tabId == id }) { scope = .everything }
        }
    }

    private var homeSpaceOfScopedTab: UUID? {
        guard case .tab(let id) = scope else { return nil }
        return snapshot.tabs.first { $0.tabId == id }?.spaceID
    }

    private func memoryBySpace() -> [UUID: UInt64] {
        var totals: [UUID: UInt64] = [:]
        for space in session.spaces {
            let mine = snapshot.tabs.filter { $0.spaceID == space.id }
            totals[space.id] = ActivityMath.rollup(of: mine).memoryBytes
        }
        return totals
    }

    /// The tabs the scope covers, and the rollup of them.
    private var scopedTabs: [TabResourceUsage] {
        ActivityMath.tabs(in: scope, from: snapshot.tabs)
    }

    private var rollup: ActivityRollup {
        ActivityMath.rollup(of: scopedTabs)
    }

    private func updateHeader() {
        defer {
            // The pane has no title of its own -- the Settings window has
            // already named it -- and no back button, because the pop-up is
            // the way back.
            if presentation == .embedded {
                backButton.isHidden = true
            }
        }
        switch scope {
        case .everything:
            backButton.isHidden = true
            titleLabel.stringValue = "Whole Browser"
            subtitleLabel.stringValue = [
                UsageFormat.count(session.spaces.count, "space"),
                UsageFormat.count(snapshot.tabs.count, "tab"),
                "\(UsageFormat.memory(snapshot.totalMemoryBytes)) in total",
                "Kylmora \(UsageFormat.memory(snapshot.browserMemoryBytes))"
            ].joined(separator: " • ")
        case .space(let id):
            let space = session.spaces.first { $0.id == id }
            backButton.isHidden = false
            backButton.attributedTitle = backTitle("Whole Browser")
            titleLabel.stringValue = space?.name.isEmpty == false ? space!.name : "Untitled Space"
            let totals = rollup
            subtitleLabel.stringValue = [
                UsageFormat.count(totals.tabCount, "tab"),
                "\(totals.activeTabCount) awake",
                UsageFormat.memory(totals.memoryBytes),
                UsageFormat.count(totals.processCount, "WebKit process", plural: "WebKit processes")
            ].joined(separator: " • ")
        case .tab(let id):
            let usage = snapshot.tabs.first { $0.tabId == id }
            let home = session.spaces.first { $0.id == usage?.spaceID }
            backButton.isHidden = false
            backButton.attributedTitle = backTitle(home?.name ?? "Whole Browser")
            titleLabel.stringValue = usage?.title ?? "Page"
            subtitleLabel.stringValue = [
                usage?.url?.absoluteString ?? "",
                usage?.isSuspended == true ? "asleep" : "awake",
                usage?.pid.map { "process \($0)" } ?? "no process"
            ].filter { !$0.isEmpty }.joined(separator: " • ")
        }
    }

    private func backTitle(_ destination: String) -> NSAttributedString {
        NSAttributedString(
            string: "‹ \(destination)",
            attributes: [
                .font: Style.Fonts.settingsNote,
                .foregroundColor: accent
            ]
        )
    }

    private func updateMetricCards() {
        let monitor = TabResourceMonitor.shared
        let totals = rollup

        switch scope {
        case .everything:
            cpuCard.show(
                value: UsageFormat.percentage(snapshot.totalCpuPercentage),
                detail: "Kylmora \(UsageFormat.percentage(snapshot.browserCpuPercentage))"
                    + " • pages \(UsageFormat.percentage(snapshot.webContentCpuPercentage))",
                history: monitor.totalCpuHistory,
                ceilingSuffix: "%"
            )
            memoryCard.show(
                value: UsageFormat.memory(snapshot.totalMemoryBytes),
                detail: "across \(UsageFormat.count(snapshot.tabs.count, "tab"))"
                    + " in \(UsageFormat.count(session.spaces.count, "space"))",
                history: monitor.totalMemoryHistory,
                ceilingSuffix: " MB"
            )
        case .space(let id):
            cpuCard.show(
                value: UsageFormat.percentage(totals.cpuPercentage),
                detail: "\(totals.activeTabCount) awake of \(UsageFormat.count(totals.tabCount, "tab"))",
                history: monitor.cpuHistory(forSpace: id),
                ceilingSuffix: "%"
            )
            memoryCard.show(
                value: UsageFormat.memory(totals.memoryBytes),
                detail: shareOfBrowser(totals.memoryBytes),
                history: monitor.memoryHistory(forSpace: id),
                ceilingSuffix: " MB"
            )
        case .tab(let id):
            let usage = snapshot.tabs.first { $0.tabId == id }
            cpuCard.show(
                value: usage?.formattedCPU ?? "—",
                detail: usage?.isSuspended == true
                    ? "asleep — this tab holds no process"
                    : "this page's share of the machine",
                history: monitor.cpuHistory(forTab: id),
                ceilingSuffix: "%"
            )
            memoryCard.show(
                value: usage?.formattedMemory ?? "—",
                detail: shareOfBrowser(usage?.memoryBytes ?? 0),
                history: monitor.memoryHistory(forTab: id),
                ceilingSuffix: " MB"
            )
        }

        // The GPU card shows Kylmora's own share of the GPU -- not the
        // machine's, which was the old reading and which told you nothing about
        // this browser. What it still cannot do is follow the scope: WebKit
        // runs one GPU process for every page in every space, and it publishes
        // no split. The caption says so rather than implying a number that does
        // not exist.
        let machine = snapshot.machineGpuUtilisation
            .map { "whole machine \(UsageFormat.percentage($0))" }
        let helper = snapshot.gpuProcessMemoryBytes > 0
            ? "GPU process \(UsageFormat.memory(snapshot.gpuProcessMemoryBytes))"
            : "GPU process not running"
        let scopeNote: String? = {
            switch scope {
            case .everything: return nil
            case .space, .tab: return "one GPU process serves every page, so this is not split"
            }
        }()
        if let own = snapshot.ownGpuPercentage {
            gpuCard.show(
                value: UsageFormat.percentage(own),
                detail: [scopeNote, machine, helper].compactMap { $0 }.joined(separator: " • "),
                history: monitor.gpuHistory,
                ceilingSuffix: "%"
            )
        } else {
            gpuCard.showUnavailable(
                detail: [
                    "this Mac publishes no per-process GPU time",
                    machine,
                    helper
                ].compactMap { $0 }.joined(separator: " • ")
            )
        }
    }

    private func shareOfBrowser(_ bytes: UInt64) -> String {
        let total = Double(snapshot.totalMemoryBytes)
        guard total > 0 else { return UsageFormat.memory(bytes) }
        return String(format: "%.0f%% of everything Kylmora is using", Double(bytes) / total * 100)
    }

    private func updateComposition() {
        switch scope {
        case .everything:
            compositionCard.setCaption("Where the memory goes")
            composition.show(ActivityMath.memorySlices(of: snapshot))
        case .space, .tab:
            compositionCard.setCaption("Share of the browser")
            let mine = rollup.memoryBytes
            let total = snapshot.totalMemoryBytes
            let rest = total > mine ? total - mine : 0
            composition.show([
                ActivityBar(
                    id: UUID(),
                    label: titleLabel.stringValue,
                    value: Double(mine),
                    caption: UsageFormat.memory(mine),
                    fraction: total > 0 ? Double(mine) / Double(total) : 0
                ),
                ActivityBar(
                    id: UUID(),
                    label: "Everything else",
                    value: Double(rest),
                    caption: UsageFormat.memory(rest),
                    fraction: total > 0 ? Double(rest) / Double(total) : 0
                )
            ])
        }
    }

    private func updateRanks() {
        switch scope {
        case .everything:
            rankCard.setCaption("Spaces by memory")
            ranks.show(ActivityMath.spaceBars(from: snapshot.tabs, spaces: session.spaces))
        case .space:
            rankCard.setCaption("Heaviest pages here")
            // Every page asleep is the good case, not an empty chart: a space
            // you have not touched all day should say so rather than look
            // broken.
            ranks.emptyMessage = rollup.tabCount > 0
                ? "Every page here is asleep, so none of them is costing anything"
                : "No pages here"
            ranks.show(ActivityMath.tabBars(from: scopedTabs))
        case .tab(let id):
            rankCard.setCaption("This page against the rest")
            let siblings = ActivityMath.tabs(
                in: homeSpaceOfScopedTab.map { ActivityScope.space($0) } ?? .everything,
                from: snapshot.tabs
            )
            ranks.show(ActivityMath.tabBars(from: siblings, highlighting: id))
        }
    }

    private func updateStats() {
        let monitor = TabResourceMonitor.shared
        let totals = rollup
        let memoryHistory: UsageHistory
        let cpuHistory: UsageHistory
        switch scope {
        case .everything:
            memoryHistory = monitor.totalMemoryHistory
            cpuHistory = monitor.totalCpuHistory
        case .space(let id):
            memoryHistory = monitor.memoryHistory(forSpace: id)
            cpuHistory = monitor.cpuHistory(forSpace: id)
        case .tab(let id):
            memoryHistory = monitor.memoryHistory(forTab: id)
            cpuHistory = monitor.cpuHistory(forTab: id)
        }

        var pairs: [(String, String)] = [
            ("Tabs", "\(totals.tabCount)"),
            ("Awake", "\(totals.activeTabCount)"),
            ("Asleep", "\(totals.suspendedTabCount)"),
            ("Playing audio", "\(totals.audibleTabCount)"),
            ("WebKit processes", "\(totals.processCount)"),
            ("Peak memory, 2 min", String(format: "%.0f MB", memoryHistory.peak)),
            ("Average CPU, 2 min", UsageFormat.percentage(cpuHistory.average)),
            ("Peak CPU, 2 min", UsageFormat.percentage(cpuHistory.peak))
        ]
        if case .everything = scope {
            pairs.append(("Spaces", "\(session.spaces.count)"))
            pairs.append(("Heaviest page", totals.heaviestTitle ?? "—"))
        }
        stats.show(pairs)
    }

    // MARK: - Table

    private func reloadTable() {
        let listed: [TabResourceUsage]
        switch scope {
        case .everything:
            listed = snapshot.tabs
        case .space:
            listed = scopedTabs
        case .tab:
            // The page's siblings, not the page alone: you drill into a page
            // to look at it, not to lose the way back to the others.
            listed = ActivityMath.tabs(
                in: homeSpaceOfScopedTab.map { ActivityScope.space($0) } ?? .everything,
                from: snapshot.tabs
            )
        }

        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        rows = needle.isEmpty ? listed : listed.filter {
            $0.title.lowercased().contains(needle)
                || $0.domain.lowercased().contains(needle)
                || $0.spaceName.lowercased().contains(needle)
        }
        sortRows()

        sparklineCeiling = UsageGraph.ceiling(
            forPeak: rows.map { TabResourceMonitor.shared.cpuHistory(forTab: $0.tabId).peak }.max() ?? 0,
            floor: 25
        )

        // The space column earns its width only when more than one space is on
        // screen; inside a space every row would say the same word.
        tableView.tableColumns.first { $0.identifier.rawValue == "space" }?.isHidden = {
            if case .everything = scope { return false }
            return true
        }()

        tableView.reloadData()
        emptyLabel.isHidden = !rows.isEmpty
        if case .tab(let id) = scope, let row = rows.firstIndex(where: { $0.tabId == id }) {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        }
        updateButtons()
    }

    private func sortRows() {
        rows.sort { a, b in
            let result: Bool
            switch sortColumn {
            case "memory": result = a.memoryBytes < b.memoryBytes
            case "cpu": result = a.cpuPercentage < b.cpuPercentage
            case "space": result = a.spaceName.localizedCaseInsensitiveCompare(b.spaceName) == .orderedAscending
            case "pid": result = (a.pid ?? 0) < (b.pid ?? 0)
            default: result = a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
            return sortAscending ? result : !result
        }
    }

    private var selectedUsage: TabResourceUsage? {
        let index = tableView.selectedRow
        guard index >= 0, index < rows.count else { return nil }
        return rows[index]
    }

    private func updateButtons() {
        let usage = selectedUsage
        focusButton.isEnabled = usage != nil
        reloadButton.isEnabled = usage != nil
        closeButton.isEnabled = usage != nil
        suspendButton.isEnabled = usage.map { !$0.isSuspended } ?? false
    }

    private func tab(for usage: TabResourceUsage?) -> Tab? {
        guard let usage else { return nil }
        return session.allTabs.first { $0.id == usage.tabId }
    }

    @objc private func suspendSelectedTab() {
        tab(for: selectedUsage)?.unload()
        refreshMetrics()
    }

    @objc private func reloadSelectedTab() {
        tab(for: selectedUsage)?.reload()
        refreshMetrics()
    }

    @objc private func closeSelectedTab() {
        guard let tab = tab(for: selectedUsage) else { return }
        _ = session.closeTab(tab)
        refreshMetrics()
    }

    @objc private func focusSelectedTab() {
        guard let usage = selectedUsage,
              let space = session.spaces.first(where: { $0.tabs.contains { $0.id == usage.tabId } }),
              let tab = session.allTabs.first(where: { $0.id == usage.tabId })
        else { return }
        session.selectSpace(space)
        session.selectTab(tab)
    }
}

/// A scroller that makes its table fit rather than letting it hang out.
///
/// An `NSTableView` is as wide as its columns add up to, whatever it is put
/// inside -- so the same table that fits the Task Manager's own window hung out
/// past the edge of the narrower Settings pane. `sizeToFit` hands the
/// difference back to the columns, down to the floors set on them, and doing it
/// in `layout` means it happens in the same pass that changed the width rather
/// than one frame later.
@MainActor
private final class FittingScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let table = documentView as? NSTableView else { return }
        let available = contentView.bounds.width
        guard available > 1, abs(table.bounds.width - available) > 1 else { return }
        table.sizeToFit()
    }
}

/// A flipped view that says when it enters or leaves a window, so an embedded
/// pane can stop sampling the moment nobody is looking at it.
@MainActor
private final class WindowAwareView: FlippedView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}

/// The page is read top-down, so the view the scroller holds is flipped.
@MainActor
private class FlippedView: NSView {
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) {
        fatalError("FlippedView is created in code only")
    }
}

// MARK: - Table data

extension TaskManagerViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SettingsTableRow()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count, let column = tableColumn else { return nil }
        let usage = rows[row]

        if column.identifier.rawValue == "trend" {
            let cell = NSTableCellView()
            let sparkline = SparklineView()
            cell.addSubview(sparkline)
            NSLayoutConstraint.activate([
                sparkline.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                sparkline.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                sparkline.topAnchor.constraint(equalTo: cell.topAnchor),
                sparkline.bottomAnchor.constraint(equalTo: cell.bottomAnchor)
            ])
            sparkline.show(
                TabResourceMonitor.shared.cpuHistory(forTab: usage.tabId),
                ceiling: sparklineCeiling,
                tint: usage.isCpuHog ? .systemRed : accent
            )
            return cell
        }

        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: "")
        label.font = Style.Fonts.settingsRow
        label.textColor = Style.Colors.primaryText
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        // The page column leads with a mark, so its label starts after one;
        // every other column's starts at the cell's edge. Two leading
        // constraints on one label is one constraint too many, and the one the
        // solver breaks is not the one you meant.
        if column.identifier.rawValue != "site" {
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4).isActive = true
        }

        switch column.identifier.rawValue {
        case "site":
            // A mark rather than an emoji prefix: asleep, noisy and greedy are
            // three states the eye should be able to tell apart down a column
            // without reading any of them.
            let mark = NSImageView()
            mark.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            mark.translatesAutoresizingMaskIntoConstraints = false
            mark.setAccessibilityElement(false)
            if usage.isMemoryHog {
                mark.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
                mark.contentTintColor = .systemOrange
            } else if usage.isSuspended {
                mark.image = NSImage(systemSymbolName: "moon.zzz.fill", accessibilityDescription: nil)
                mark.contentTintColor = Style.Colors.tertiaryText
            } else if usage.isPlayingAudio {
                mark.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil)
                mark.contentTintColor = accent
            }
            cell.addSubview(mark)
            NSLayoutConstraint.activate([
                mark.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                mark.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                mark.widthAnchor.constraint(equalToConstant: 14),
                label.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 6)
            ])
            label.stringValue = usage.title
            label.toolTip = usage.url?.absoluteString
            if usage.isSuspended { label.textColor = Style.Colors.secondaryText }
        case "space":
            label.stringValue = usage.spaceName
            label.textColor = Style.Colors.secondaryText
        case "memory":
            label.stringValue = usage.formattedMemory
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: usage.isMemoryHog ? .bold : .regular)
            if usage.isMemoryHog { label.textColor = .systemOrange }
        case "cpu":
            label.stringValue = usage.formattedCPU
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: usage.isCpuHog ? .bold : .regular)
            if usage.isCpuHog { label.textColor = .systemRed }
        case "pid":
            label.stringValue = usage.pid.map { String($0) } ?? "—"
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            label.textColor = Style.Colors.tertiaryText
        default:
            break
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
        // Selecting a page is how you drill into it: the cards, the ranked
        // chart and the details all follow the selection, which is the whole
        // reason the table and the charts are in one window.
        guard let usage = selectedUsage else { return }
        if case .tab(let id) = scope, id == usage.tabId { return }
        scope = .tab(usage.tabId)
        if presentation == .window {
            canvas.accentHint = accent
            rail.show(scope: scope, tabHome: usage.spaceID)
        } else {
            rebuildScopeOptions()
        }
        updateHeader()
        updateMetricCards()
        updateComposition()
        updateRanks()
        updateStats()
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else { return }
        sortColumn = key
        sortAscending = descriptor.ascending
        reloadTable()
    }
}
