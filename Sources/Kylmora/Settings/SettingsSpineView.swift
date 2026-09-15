import AppKit

/// The list of panes down the left of the Settings window.
///
/// A coloured mark and a name per row, in a column a hundred points narrower
/// than the system's own source list. Two earlier versions of this were thrown
/// away: a 236-point rail of plain rows, which was the same list every Mac app
/// has, and a 66-point column of glyph tiles with no names at all, which looked
/// better and was worse -- a colour you have not learned yet is not a label,
/// and the only way to learn it was to click all thirteen.
///
/// So both: the mark is what you reach for once you know the pane, the name is
/// what tells you the first time.
@MainActor
final class SettingsSpineView: NSView {
    /// A pane was chosen.
    var onSelect: ((SettingsWindowController.Pane) -> Void)?
    /// What was typed in the search field.
    var onSearch: ((String) -> Void)?

    private let scroll = NSScrollView()
    private let stack = TopDownStackView()
    private var rows: [SettingsWindowController.Pane: RowView] = [:]
    private var headings: [SettingsWindowController.PaneGroup: NSView] = [:]
    private let search = NSSearchField()
    private let empty = NSTextField(labelWithString: "No settings match")

    /// The window's own light, dark or automatic was chosen.
    var onAppearance: ((AppearancePreference) -> Void)?
    /// Automatic, Light, Dark for this window, at the foot of the list.
    ///
    /// The browser's windows take their appearance from the space in front;
    /// this window belongs to no space, so it chooses for itself, and the
    /// choice lives where the window is rather than three panes away.
    private let appearanceControl = NSSegmentedControl(
        labels: AppearancePreference.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil
    )
    private let appearanceSegments: SettingsSegments
    private let appearanceCaption = NSTextField(labelWithString: "")

    /// The pane's hue, worn by the chosen appearance pill.
    var accent: NSColor? {
        didSet { appearanceSegments.tint = accent }
    }

    override init(frame frameRect: NSRect) {
        appearanceSegments = SettingsSegments(segmented: appearanceControl)
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        // The moments an exit is never delivered: the window stops being key,
        // or the app goes behind another one.
        for name: NSNotification.Name in [
            NSWindow.didResignKeyNotification,
            NSWindow.didBecomeKeyNotification,
            NSApplication.didResignActiveNotification,
            NSApplication.didBecomeActiveNotification
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(refreshHover), name: name, object: nil
            )
        }

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

        search.placeholderString = "Search settings"
        search.font = Style.Fonts.settingsRow
        search.target = self
        search.action = #selector(searchChanged)
        search.sendsSearchStringImmediately = true
        search.sendsWholeSearchString = false
        search.translatesAutoresizingMaskIntoConstraints = false
        addSubview(search)

        empty.font = Style.Fonts.settingsNote
        empty.textColor = Style.Colors.tertiaryText
        empty.isHidden = true
        empty.translatesAutoresizingMaskIntoConstraints = false
        addSubview(empty)

        appearanceControl.target = self
        appearanceControl.action = #selector(appearanceChanged)
        appearanceControl.setAccessibilityLabel("Settings window appearance")
        appearanceSegments.translatesAutoresizingMaskIntoConstraints = false
        addSubview(appearanceSegments)
        appearanceCaption.attributedStringValue = NSAttributedString(
            string: "APPEARANCE",
            attributes: [
                .font: Style.Fonts.settingsGroup,
                .foregroundColor: Style.Colors.tertiaryText,
                .kern: 1.0
            ]
        )
        appearanceCaption.translatesAutoresizingMaskIntoConstraints = false
        appearanceCaption.setAccessibilityElement(false)
        addSubview(appearanceCaption)

        let inset = Style.SettingsUI.railInset

        NSLayoutConstraint.activate([
            appearanceCaption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset + 8),
            appearanceCaption.bottomAnchor.constraint(equalTo: appearanceSegments.topAnchor, constant: -6),
            appearanceSegments.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            appearanceSegments.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset),
            appearanceSegments.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            scroll.bottomAnchor.constraint(equalTo: appearanceCaption.topAnchor, constant: -10),
            widthAnchor.constraint(equalToConstant: Style.SettingsUI.spineWidth),
            search.topAnchor.constraint(
                equalTo: topAnchor,
                constant: Style.SettingsUI.titlebarHeight
            ),
            search.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            search.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset - 1),
            empty.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 14),
            empty.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset + 8),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])

        build()
        setAccessibilityRole(.list)
        setAccessibilityLabel("Settings panes")
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsSpineView is created in code only")
    }

    private func build() {
        var lastGroup: SettingsWindowController.PaneGroup?
        for pane in SettingsWindowController.Pane.allCases {
            if pane.group != lastGroup {
                let heading = HeadingView(title: pane.group.title, isFirst: lastGroup == nil)
                headings[pane.group] = heading
                stack.addArrangedSubview(heading)
                heading.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                lastGroup = pane.group
            }
            let row = RowView(pane: pane) { [weak self] in self?.onSelect?(pane) }
            rows[pane] = row
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        if EnterprisePolicyManager.shared.isManaged {
            let footer = NSButton()
            footer.isBordered = false
            footer.image = NSImage(systemSymbolName: "building.2.crop.circle.fill", accessibilityDescription: "Managed")
            footer.imagePosition = .imageLeading
            footer.font = .systemFont(ofSize: 11, weight: .medium)
            footer.contentTintColor = .secondaryLabelColor
            footer.title = " Managed by \(EnterprisePolicyManager.shared.organizationName)"
            footer.target = self
            footer.action = #selector(openEnterprisePolicies)
            stack.addArrangedSubview(footer)
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            if let about = rows[.about] {
                stack.setCustomSpacing(16, after: about)
            }
        }
    }

    @objc private func openEnterprisePolicies() {
        guard let window else { return }
        let controller = EnterprisePoliciesViewController()
        let sheetWindow = NSWindow(contentViewController: controller)
        sheetWindow.styleMask = [.titled, .closable]
        sheetWindow.title = "Enterprise Policies"
        window.beginSheet(sheetWindow) { _ in }
    }

    @objc private func searchChanged() {
        onSearch?(search.stringValue)
    }

    @objc private func appearanceChanged() {
        let choices = AppearancePreference.allCases
        guard choices.indices.contains(appearanceControl.selectedSegment) else { return }
        onAppearance?(choices[appearanceControl.selectedSegment])
    }

    /// Shows which appearance the window is in. The window sets it when it
    /// opens, and again when the choice is made elsewhere.
    func showAppearance(_ preference: AppearancePreference) {
        appearanceControl.selectedSegment = AppearancePreference.allCases.firstIndex(of: preference) ?? 0
    }

    /// Which appearance the control shows, for a test.
    var shownAppearance: AppearancePreference {
        let index = appearanceControl.selectedSegment
        return AppearancePreference.allCases.indices.contains(index) ? AppearancePreference.allCases[index] : .system
    }

    /// Every row works out again whether the pointer is on it.
    ///
    /// Called when the window stops being the key one and when the app is no
    /// longer in front: those are the moments a row is left lit with nothing
    /// under it, because an exit is never delivered to a background app.
    @objc func refreshHover() {
        for row in rows.values { row.refreshHover() }
    }

    func select(_ pane: SettingsWindowController.Pane) {
        for (each, row) in rows { row.isChosen = each == pane }
    }

    /// The row for a pane, so a test can look at what the list drew.
    func row(for pane: SettingsWindowController.Pane) -> RowView? { rows[pane] }

    /// Whether the list is showing this pane as the chosen one.
    func isChosen(_ pane: SettingsWindowController.Pane) -> Bool {
        rows[pane]?.isChosen ?? false
    }

    /// Shows only these panes, and only the headings that still have one.
    func show(_ visible: [SettingsWindowController.Pane]) {
        let visible = Set(visible)
        for (pane, row) in rows { row.isHidden = !visible.contains(pane) }
        for (group, heading) in headings {
            heading.isHidden = !visible.contains { $0.group == group }
        }
        empty.isHidden = !visible.isEmpty
    }

    /// Puts the keyboard in the search field.
    func focusSearch() { window?.makeFirstResponder(search) }

    /// A stack that fills from the top.
    ///
    /// An `NSScrollView`'s document view is bottom-left by default, so a plain
    /// stack of rows hangs from the bottom of the clip and the first heading is
    /// cut off at the top the moment the list is taller than the window.
    private final class TopDownStackView: NSStackView {
        override var isFlipped: Bool { true }
    }

    // MARK: - A group heading

    private final class HeadingView: NSView {
        init(title: String, isFirst: Bool) {
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            let label = NSTextField(labelWithString: "")
            label.attributedStringValue = NSAttributedString(
                string: title.uppercased(),
                attributes: [
                    .font: Style.Fonts.settingsGroup,
                    .foregroundColor: Style.Colors.tertiaryText,
                    .kern: 0.6
                ]
            )
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(
                    equalTo: leadingAnchor,
                    constant: Style.SettingsUI.railInset + 8
                ),
                label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
                label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
                label.topAnchor.constraint(equalTo: topAnchor, constant: isFirst ? 2 : 14)
            ])
            setAccessibilityElement(false)
        }

        required init?(coder: NSCoder) {
            fatalError("HeadingView is created in code only")
        }
    }

    // MARK: - A pane row

    final class RowView: NSView {
        private let pane: SettingsWindowController.Pane
        private let mark = SettingsPlateView()
        private let icon = NSImageView()
        private let label = NSTextField(labelWithString: "")
        private let onClick: () -> Void
        private var trackingArea: NSTrackingArea?
        private let pill = CALayer()

        var isChosen = false {
            didSet {
                guard isChosen != oldValue else { return }
                apply()
            }
        }
        /// Whether the row is drawing itself as under the pointer.
        var isLit: Bool { isHovered }

        private var isHovered = false {
            didSet {
                guard isHovered != oldValue else { return }
                apply()
            }
        }

        init(pane: SettingsWindowController.Pane, onClick: @escaping () -> Void) {
            self.pane = pane
            self.onClick = onClick
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            wantsLayer = true
            layer?.addSublayer(pill)

            // The mark keeps its colour whether the row is chosen or not: it is
            // the thing you learn the pane by, so it must not change under you.
            mark.fill = pane.accent
            mark.cornerRadius = Style.SettingsUI.spineTileRadius
            addSubview(mark)

            icon.image = NSImage(systemSymbolName: pane.symbolName, accessibilityDescription: nil)
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            icon.contentTintColor = .white
            icon.imageScaling = .scaleProportionallyDown
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.setAccessibilityElement(false)
            addSubview(icon)

            label.stringValue = pane.title
            label.font = Style.Fonts.settingsRow
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setAccessibilityElement(false)
            addSubview(label)

            let inset = Style.SettingsUI.railInset
            let side = Style.SettingsUI.spineTileSide
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: Style.SettingsUI.spineRowHeight),
                mark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset + 7),
                mark.centerYAnchor.constraint(equalTo: centerYAnchor),
                mark.widthAnchor.constraint(equalToConstant: side),
                mark.heightAnchor.constraint(equalToConstant: side),
                icon.centerXAnchor.constraint(equalTo: mark.centerXAnchor),
                icon.centerYAnchor.constraint(equalTo: mark.centerYAnchor),
                label.leadingAnchor.constraint(
                    equalTo: mark.trailingAnchor,
                    constant: Style.SettingsUI.spineTileGapToLabel
                ),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10)
            ])

            setAccessibilityRole(.button)
            setAccessibilityLabel(pane.title)
            apply()
        }

        required init?(coder: NSCoder) {
            fatalError("RowView is created in code only")
        }

        override var wantsUpdateLayer: Bool { true }

        override func updateLayer() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pill.frame = bounds.insetBy(dx: Style.SettingsUI.railInset, dy: 0)
            pill.cornerCurve = .continuous
            pill.cornerRadius = Style.SettingsUI.spineRowRadius
            // In this row's own appearance. The hover colour's light value is
            // white at 0.55 against 0.07 in the dark, so this is the one place
            // where resolving against the wrong appearance would be loud.
            effectiveAppearance.performAsCurrentDrawingAppearance {
                pill.backgroundColor = isChosen
                    ? Style.Colors.settingsGlass.cgColor
                    : (isHovered ? Style.Colors.settingsSpineTile.withAlphaComponent(0.5).cgColor : nil)
            }
            CATransaction.commit()
        }

        /// Sized from `layout`, never by asking for a redraw from inside one:
        /// a view that dirties itself while drawing never stops drawing.
        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pill.frame = bounds.insetBy(dx: Style.SettingsUI.railInset, dy: 0)
            CATransaction.commit()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            apply()
        }

        private func apply() {
            label.textColor = isChosen ? Style.Colors.primaryText : Style.Colors.secondaryText
            label.font = isChosen
                ? .systemFont(ofSize: 13, weight: .semibold)
                : Style.Fonts.settingsRow
            mark.alphaValue = isChosen ? 1 : 0.85
            setAccessibilityValue(isChosen ? "selected" : "")
            needsDisplay = true
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self
            )
            addTrackingArea(area)
            trackingArea = area
            refreshHover()
        }

        /// Works out for itself whether the pointer is on this row.
        ///
        /// Enter and exit do not always come in pairs. `activeInActiveApp`
        /// means a row that the pointer leaves while the app is in the
        /// background never hears about it, and a row that moves out from under
        /// the pointer -- the list filtering as you type, or scrolling -- never
        /// hears about that either. Either way the row is left lit, and after a
        /// few app switches half the list looks selected. Asking where the
        /// pointer actually is cannot come adrift that way.
        func refreshHover() {
            guard let window, window.isKeyWindow, NSApp.isActive else {
                isHovered = false
                return
            }
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            isHovered = bounds.contains(point) && visibleRect.contains(point)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            refreshHover()
        }

        override func mouseEntered(with event: NSEvent) { isHovered = true }
        override func mouseExited(with event: NSEvent) { isHovered = false }
        override func mouseDown(with event: NSEvent) { onClick() }

        override func accessibilityPerformPress() -> Bool {
            onClick()
            return true
        }
    }
}
