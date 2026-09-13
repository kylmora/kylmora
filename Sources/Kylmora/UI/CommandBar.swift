import AppKit

/// Sizes for the command bar. These are proportions chosen to make the panel
/// read as a launcher, not pixel measurements: the reference screenshots show
/// the browser at rest, with the command bar closed.
///
/// They live here rather than in `Style` only until the integrator folds
/// them in.
enum CommandBarMetrics {
    /// Wide enough for a long URL and its title, narrow enough that the panel
    /// still reads as a floating object rather than a sheet.
    static let panelWidth: CGFloat = 640
    /// Never let the panel touch the window edge, however narrow the window.
    static let minimumSideGap: CGFloat = 48
    /// Distance from the top of the page area. Roughly the top sixth: high
    /// enough to feel like an overlay, low enough that the eye finds it.
    static let topInset: CGFloat = 96
    /// Breathing room kept below the panel when the results list is at its
    /// tallest, so a full list never runs into the bottom of the window.
    static let bottomGap: CGFloat = 24

    static let cornerRadius: CGFloat = 14
    static let shadowRadius: CGFloat = 30
    static let shadowOpacity: Float = 0.28
    static let shadowOffset = CGSize(width: 0, height: -8)

    /// The query row: one line of 19pt text with generous padding on all sides.
    static let fieldHeight: CGFloat = 56
    static let fieldInset: CGFloat = 20
    static let queryFontSize: CGFloat = 19

    static let rowHeight: CGFloat = 40
    static let rowInset: CGFloat = 14
    static let rowCornerRadius: CGFloat = 8
    static let rowIconSide: CGFloat = 16
    static let rowSpacing: CGFloat = 2
    static let rowLabelSpacing: CGFloat = 8
    static let subtitleFontSize: CGFloat = 11
    /// Padding around the whole result list, inside the panel.
    static let listInset: CGFloat = 6
    static let dividerHeight: CGFloat = 1

    /// Long enough that holding a key down does not queue a query per
    /// keystroke, short enough to still feel like search-as-you-type. Same
    /// reasoning, and the same figure, as `FindController.typingDelay`.
    static let typingDelay = Duration.milliseconds(90)
}

/// The command bar: a floating launcher over the page, opened with Cmd-L.
///
/// It exists because the sidebar has no address bar, and removing Kylmora's
/// without a replacement would leave no way to type an address. So this is not
/// decoration -- it is the omnibox, moved out of the chrome and into a surface
/// that is only present while it is being used.
///
/// Two things follow from that and shape the whole component. It is *modal
/// while open*: it covers the page, swallows the click that dismisses it, and
/// takes the keyboard. And it is *transient*: it stores nothing between
/// openings, hands first responder back to whatever had it, and collapses to a
/// single row the moment it has nothing to show.
///
/// Like the rest of `UI/` it never sees the session. It is given an
/// async provider that returns rows and a handler that performs one; ranking
/// lives in `CommandRanker`, which is pure and tested.
@MainActor
final class CommandBar: NSView, NSTextFieldDelegate {
    /// Supplies rows for a query. Async because history is a database read;
    /// the bar debounces, cancels superseded queries and discards answers that
    /// arrive after the text has moved on.
    /// The engine a bare query searches with: the private one in a private
    /// space. Nil falls back to the ordinary engine.
    var searchEngineProvider: (() -> SearchEngine)?

    var resultsProvider: (@MainActor (String) async -> [CommandResult])?

    /// Performs a chosen row, or the address the user typed. The bar resolves
    /// text into a `URL` itself so that the caller has one case to handle
    /// rather than two, but it never navigates: it has no session to navigate.
    var onRun: ((CommandAction) -> Void)?

    private let shadowHost = NSView()
    private let panel = NSVisualEffectView()
    private let fieldRow = NSView()
    private let field = NSTextField()
    private let divider = NSBox()
    private let rowsStack = NSStackView()
    private let resultsContainer = NSStackView()

    private var queryTask: Task<Void, Never>?
    /// Whatever held focus when the bar opened -- in practice the page. Weak
    /// because a tab can close while the bar is open, and the bar has no
    /// business keeping that view alive.
    private weak var previousResponder: NSResponder?

    /// Everything the ranker returned, in order.
    private(set) var results: [CommandResult] = []
    /// The rows actually built, which is `results` clipped to what fits the
    /// window. See `maximumVisibleRows(inHeight:)`.
    private(set) var visibleResults: [CommandResult] = []
    /// nil means the query line itself is selected: Return navigates to what
    /// was typed rather than to a row.
    private(set) var selectedIndex: Int?

    var isOpen: Bool { !isHidden }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        buildPanel()
        applyShadowColor()
        setAccessibilityRole(.group)
        setAccessibilityLabel("Command Bar")
    }

    required init?(coder: NSCoder) {
        fatalError("CommandBar is created in code only")
    }

    // MARK: - Construction

    private func buildPanel() {
        shadowHost.wantsLayer = true
        shadowHost.layer?.cornerCurve = .continuous
        shadowHost.layer?.cornerRadius = CommandBarMetrics.cornerRadius
        shadowHost.layer?.shadowRadius = CommandBarMetrics.shadowRadius
        shadowHost.layer?.shadowOpacity = CommandBarMetrics.shadowOpacity
        shadowHost.layer?.shadowOffset = CommandBarMetrics.shadowOffset
        shadowHost.translatesAutoresizingMaskIntoConstraints = false

        // The material has to clip to the rounded corners, and a layer that
        // masks its bounds cannot also cast a shadow -- hence the extra host.
        panel.material = .hudWindow
        // Within-window, so the panel is vibrant over the *page* beneath it.
        // Behind-window would sample the desktop, which an opaque page hides.
        panel.blendingMode = .withinWindow
        panel.state = .active
        panel.maskImage = nil
        panel.wantsLayer = true
        panel.layer?.cornerCurve = .continuous
        panel.layer?.cornerRadius = CommandBarMetrics.cornerRadius
        panel.layer?.masksToBounds = true
        panel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(shadowHost)
        shadowHost.addSubview(panel)

        buildFieldRow()
        buildResultsContainer()

        let content = NSStackView(views: [fieldRow, resultsContainer])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 0
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(content)

        let preferredWidth = shadowHost.widthAnchor.constraint(
            equalToConstant: CommandBarMetrics.panelWidth
        )
        // Loses to the window, wins over everything else: a narrow window
        // shrinks the panel instead of pushing it off screen.
        preferredWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            shadowHost.centerXAnchor.constraint(equalTo: centerXAnchor),
            shadowHost.topAnchor.constraint(
                equalTo: topAnchor,
                constant: CommandBarMetrics.topInset
            ),
            preferredWidth,
            shadowHost.widthAnchor.constraint(
                lessThanOrEqualTo: widthAnchor,
                constant: -2 * CommandBarMetrics.minimumSideGap
            ),

            panel.topAnchor.constraint(equalTo: shadowHost.topAnchor),
            panel.leadingAnchor.constraint(equalTo: shadowHost.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: shadowHost.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: shadowHost.bottomAnchor),

            content.topAnchor.constraint(equalTo: panel.topAnchor),
            content.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: panel.bottomAnchor),

            // Both rows span the panel. Activated here because a constraint
            // between two views needs them to share an ancestor first.
            fieldRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            resultsContainer.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
    }

    private func buildFieldRow() {
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: CommandBarMetrics.queryFontSize)
        field.textColor = Style.Colors.primaryText
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        // No promise of anything Kylmora cannot do: this bar searches and
        // navigates, so that is what it offers.
        field.placeholderString = "Search or enter address"
        field.delegate = self
        field.setAccessibilityLabel("Search or enter address")
        field.translatesAutoresizingMaskIntoConstraints = false

        fieldRow.translatesAutoresizingMaskIntoConstraints = false
        fieldRow.addSubview(field)

        NSLayoutConstraint.activate([
            fieldRow.heightAnchor.constraint(equalToConstant: CommandBarMetrics.fieldHeight),
            field.leadingAnchor.constraint(
                equalTo: fieldRow.leadingAnchor,
                constant: CommandBarMetrics.fieldInset
            ),
            field.trailingAnchor.constraint(
                equalTo: fieldRow.trailingAnchor,
                constant: -CommandBarMetrics.fieldInset
            ),
            field.centerYAnchor.constraint(equalTo: fieldRow.centerYAnchor)
        ])
    }

    private func buildResultsContainer() {
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = CommandBarMetrics.rowSpacing
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        resultsContainer.orientation = .vertical
        resultsContainer.alignment = .leading
        resultsContainer.spacing = CommandBarMetrics.listInset
        resultsContainer.edgeInsets = NSEdgeInsets(
            top: 0,
            left: CommandBarMetrics.listInset,
            bottom: CommandBarMetrics.listInset,
            right: CommandBarMetrics.listInset
        )
        resultsContainer.setViews([divider, rowsStack], in: .top)
        resultsContainer.translatesAutoresizingMaskIntoConstraints = false
        // Hidden, and therefore collapsed by the enclosing stack: with nothing
        // to show, the panel is exactly one row tall.
        resultsContainer.isHidden = true

        let inset = -2 * CommandBarMetrics.listInset
        NSLayoutConstraint.activate([
            divider.heightAnchor.constraint(equalToConstant: CommandBarMetrics.dividerHeight),
            divider.widthAnchor.constraint(equalTo: resultsContainer.widthAnchor, constant: inset),
            rowsStack.widthAnchor.constraint(equalTo: resultsContainer.widthAnchor, constant: inset)
        ])
    }

    // MARK: - Installing

    /// Adds the bar over `host`, filling it. Called once; the bar stays hidden
    /// until it is opened.
    ///
    /// It fills the host rather than sitting at the top of it because the empty
    /// area *is* the dismiss target: a click anywhere outside the panel closes
    /// the bar, and a view cannot receive a click it does not cover.
    func install(in host: NSView) {
        host.addSubview(self)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: host.topAnchor),
            leadingAnchor.constraint(equalTo: host.leadingAnchor),
            trailingAnchor.constraint(equalTo: host.trailingAnchor),
            bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
    }

    // MARK: - Opening and closing

    /// Opens the bar with `text` selected, so the first keystroke replaces it.
    func open(text: String = "") {
        if !isOpen {
            previousResponder = window?.firstResponder
        }
        isHidden = false
        field.stringValue = text
        setResults([])
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        if !text.isEmpty { scheduleQuery(for: text) }
    }

    /// Hides the bar and gives focus back. Everything typed is discarded: the
    /// bar is a question, and a question that is dismissed has no answer worth
    /// keeping until next time.
    func close() {
        guard isOpen else { return }
        queryTask?.cancel()
        queryTask = nil
        isHidden = true
        field.stringValue = ""
        setResults([])
        restoreResponder()
    }

    /// Cmd-L: open the bar; close it if it is open and being typed into; and
    /// if it is open but the page has the keyboard, give it back to the bar
    /// with the text selected, which is what the shortcut means everywhere.
    func toggle() {
        guard isOpen else { open(); return }
        // Open, but the keyboard is elsewhere because a click moved it: Cmd-L
        // brings it back rather than closing a bar the user cannot type into.
        // Only with a real window to read focus from; otherwise close as usual.
        if window != nil, !fieldHasFocus { focusField(); return }
        close()
    }

    /// Whether keystrokes reach the bar: the field editor is the responder
    /// while the field is being edited, so the field itself never is.
    var fieldHasFocus: Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder === field { return true }
        return (responder as? NSTextView)?.delegate === field
    }

    private func focusField() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// Hands first responder back to whatever had it, which is the page.
    ///
    /// The fallback is the window itself rather than a guess at which view
    /// ought to have focus: an unfocused window is recoverable with one click,
    /// while focusing the wrong view sends the next keystroke somewhere the
    /// user cannot see.
    private func restoreResponder() {
        guard let window else { return }
        if let previous = previousResponder as? NSView,
           previous.window === window,
           !previous.isDescendant(of: self) {
            window.makeFirstResponder(previous)
        } else {
            window.makeFirstResponder(nil)
        }
        previousResponder = nil
    }

    // MARK: - Results

    /// Replaces the list, rebuilds the rows and drops any selection.
    ///
    /// The selection is not carried across: after a keystroke the row that was
    /// under the cursor may mean something else entirely, and a launcher that
    /// keeps a stale selection is one that opens the wrong page on Return.
    func setResults(_ newResults: [CommandResult]) {
        results = newResults
        selectedIndex = nil
        rebuildRows()
    }

    private func rebuildRows() {
        let fitting = Self.maximumVisibleRows(inHeight: bounds.height)
        visibleResults = Array(results.prefix(fitting))

        for view in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, result) in visibleResults.enumerated() {
            let row = CommandRowView()
            row.configure(result)
            row.onHover = { [weak self] in self?.select(index) }
            row.onClick = { [weak self] in self?.run(at: index) }
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }
        resultsContainer.isHidden = visibleResults.isEmpty
        applySelectionToRows()
    }

    /// How many rows fit between the panel's top inset and the bottom of the
    /// window. A launcher whose list runs off the screen is worse than a
    /// shorter list, and this is cheaper and steadier than a scroll view for a
    /// list that is capped at eight rows anyway.
    static func maximumVisibleRows(inHeight height: CGFloat) -> Int {
        let chrome = CommandBarMetrics.topInset
            + CommandBarMetrics.fieldHeight
            + CommandBarMetrics.dividerHeight
            + CommandBarMetrics.listInset * 2
            + CommandBarMetrics.bottomGap
        let available = height - chrome
        guard available > 0 else { return 0 }
        let pitch = CommandBarMetrics.rowHeight + CommandBarMetrics.rowSpacing
        return max(0, Int((available + CommandBarMetrics.rowSpacing) / pitch))
    }

    /// A resize can change how many rows fit, and the list has to follow it or
    /// a taller window keeps a truncated list forever.
    override func layout() {
        super.layout()
        let expected = min(Self.maximumVisibleRows(inHeight: bounds.height), results.count)
        if expected != visibleResults.count { rebuildRows() }
    }

    // MARK: - Selection

    /// Moves the selection by `delta`. Moving up off the first row returns to
    /// the query line itself (no selection), which is what makes "type an
    /// address, then think better of the suggestion" a single keystroke.
    func moveSelection(by delta: Int) {
        guard !visibleResults.isEmpty else { return }
        guard let current = selectedIndex else {
            select(delta > 0 ? 0 : visibleResults.count - 1)
            return
        }
        let next = current + delta
        if next < 0 {
            select(nil)
        } else {
            select(min(next, visibleResults.count - 1))
        }
    }

    func select(_ index: Int?) {
        guard let index else {
            selectedIndex = nil
            applySelectionToRows()
            return
        }
        guard visibleResults.indices.contains(index) else { return }
        selectedIndex = index
        applySelectionToRows()
    }

    private func applySelectionToRows() {
        for (index, view) in rowsStack.arrangedSubviews.enumerated() {
            (view as? CommandRowView)?.isSelected = index == selectedIndex
        }
    }

    // MARK: - Running

    private func run(at index: Int) {
        guard visibleResults.indices.contains(index) else { return }
        let action = visibleResults[index].action
        close()
        onRun?(action)
    }

    /// Return. A selected row wins; otherwise the typed text is resolved the
    /// same way the omnibox resolves it, so "kylmora" searches and "kylmora.dev"
    /// navigates without the two needing different keystrokes.
    func submit() {
        if let selectedIndex {
            run(at: selectedIndex)
            return
        }
        let text = field.stringValue
        let engine = searchEngineProvider?() ?? Settings.shared.searchEngine
        guard let url = URLResolver.resolve(text, using: engine, engines: Settings.shared.searchEngines) else { return }
        close()
        onRun?(.openURL(url))
    }

    // MARK: - Querying

    private func scheduleQuery(for text: String) {
        queryTask?.cancel()
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let resultsProvider else {
            setResults([])
            return
        }
        queryTask = Task { [weak self] in
            try? await Task.sleep(for: CommandBarMetrics.typingDelay)
            guard !Task.isCancelled, let self else { return }
            let found = await resultsProvider(query)
            // The text can have moved on while the database was read; showing
            // rows for a query that is no longer on screen is worse than none.
            guard !Task.isCancelled,
                  self.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == query
            else { return }
            self.setResults(found)
        }
    }

    // MARK: - Appearance

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyShadowColor()
    }

    /// A `CGColor` does not follow the appearance, so the one colour in this
    /// component that has to be a `CGColor` is re-resolved by hand -- the same
    /// exception `ContentContainerView` makes, for the same reason.
    private func applyShadowColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            shadowHost.layer?.shadowColor = NSColor.shadowColor.cgColor
        }
    }

    // MARK: - Events

    /// A click that lands on the bar and not on the panel is a click outside
    /// the panel, because the panel is the only thing on it.
    override func mouseDown(with event: NSEvent) {
        close()
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        scheduleQuery(for: field.stringValue)
    }

    /// The keyboard contract, in one place: arrows move the selection, Return
    /// runs it, Escape dismisses.
    ///
    /// Handled here rather than by making the bar first responder, so the field
    /// keeps focus throughout: the user is always typing, even while walking
    /// the list, and one more keystroke can narrow it again.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            submit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }
}
