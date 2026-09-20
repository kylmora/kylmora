import AppKit

/// The row of places across the top of the Task Manager's Settings pane: the
/// whole browser, then a chip per space wearing its own mark and what it is
/// costing, scrolling sideways when there are more than fit.
///
/// It replaced a pop-up button. A pop-up hides every choice but one behind a
/// click, which is exactly wrong here: the numbers on the chips are half the
/// answer, and somebody with eighteen spaces open wants to *see* which one is
/// the expensive one, not go looking for it a menu item at a time.
@MainActor
final class ActivityScopeBar: NSView {
    /// A place was chosen.
    var onSelect: ((ActivityScope) -> Void)?

    /// One chip's worth of description.
    struct Item {
        var scope: ActivityScope
        var title: String
        /// The number under the name -- a space's memory. Nil leaves the chip
        /// with its name alone, which is what the whole-browser chip wants
        /// while it is showing a total the line underneath already carries.
        var detail: String?
        /// The space's own mark, drawn as it is.
        var image: NSImage?
        /// ...or a symbol, for the chips that are not a space.
        var symbol: String?
        /// What the chip wears when it is the chosen one.
        var tint: NSColor
    }

    private let scroll = SidewaysScrollView()
    private let row = NSStackView()
    /// The two ways through the row that need no gesture at all. Shown only
    /// while there is something that way to reach: a control that is always
    /// there and sometimes does nothing is a control you stop trusting.
    private lazy var back = pager(symbol: "chevron.left", label: "Earlier spaces", by: -1)
    private lazy var forward = pager(symbol: "chevron.right", label: "Later spaces", by: 1)
    private var chips: [ActivityScope: ChipView] = [:]
    /// The chips as they are laid out, so a rebuild only happens when the set
    /// has actually changed -- rebuilding under the pointer every two seconds
    /// would throw away the hover and the scroll position with it.
    private var order: [ActivityScope] = []
    /// The chip the row has already been scrolled to. Kept so that the numbers
    /// refreshing twice a second does not keep dragging the row back to it:
    /// where you scrolled to is your business until the selection changes.
    private var revealed: ActivityScope?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        // Laid out by frame, not by constraints. An Auto Layout document view
        // gets its width pinned to the clip view's, which for a sideways
        // scroller is exactly the wrong answer: the row came out the width of
        // the window, the chips past the edge were clipped, and there was
        // nothing left over to scroll. `layout` sizes it to its chips instead.
        row.translatesAutoresizingMaskIntoConstraints = true
        // The chips keep their own width rather than being stretched or
        // squeezed to fit, because "fitting" is what this row deliberately
        // does not do.
        row.setHuggingPriority(.required, for: .horizontal)

        scroll.documentView = row
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        // Overlay, so the scroller is a hint that appears while you are using
        // it rather than a permanent bar eating six points of a 40-point row.
        scroll.hasHorizontalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .none
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: Self.height)
        ])
        for arrow in [back, forward] { addSubview(arrow) }
        NSLayoutConstraint.activate([
            back.leadingAnchor.constraint(equalTo: leadingAnchor),
            back.centerYAnchor.constraint(equalTo: centerYAnchor),
            forward.trailingAnchor.constraint(equalTo: trailingAnchor),
            forward.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        // The arrows appear and disappear as the row moves, and the only thing
        // that knows it moved is the clip view. The chips are told at the same
        // time: scrolling is exactly when one slides out from under a pointer
        // that never moved, and so never gets an exit.
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateArrows()
                self?.refreshHover()
            }
        }

        // ...and the moments an exit is never delivered at all: the window
        // stops being the one in use, or the app goes behind another.
        for name: NSNotification.Name in [
            NSWindow.didResignKeyNotification,
            NSWindow.didBecomeKeyNotification,
            NSApplication.didResignActiveNotification,
            NSApplication.didBecomeActiveNotification
        ] {
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshHover() }
            }
        }

        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("What to measure")
    }

    /// One end's arrow: a plate with a chevron on it, over the row rather than
    /// beside it, so the chips keep the full width when there is nothing to
    /// page through.
    private func pager(symbol: String, label: String, by direction: CGFloat) -> NSView {
        let plate = SettingsPlateView()
        plate.cornerRadius = 9
        // A card rather than a control, and lifted: the arrow sits *over* the
        // chip at the edge, and a translucent plate on top of a chip reads as
        // part of it.
        plate.fill = Style.Colors.settingsCard
        plate.stroke = Style.Colors.settingsCardStroke
        plate.elevated = true
        let button = IconButton(symbolName: symbol, label: label, side: 24) { [weak self] in
            self?.page(by: direction)
        }
        plate.addSubview(button)
        NSLayoutConstraint.activate([
            plate.widthAnchor.constraint(equalToConstant: 26),
            plate.heightAnchor.constraint(equalToConstant: 30),
            button.centerXAnchor.constraint(equalTo: plate.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: plate.centerYAnchor)
        ])
        plate.isHidden = true
        return plate
    }

    /// Moves the row by most of a screenful, the way a paging control should:
    /// far enough to be worth the click, short enough to keep a chip or two
    /// from the last view as a landmark.
    private func page(by direction: CGFloat) {
        let clip = scroll.contentView
        let step = clip.bounds.width * 0.8 * direction
        let room = max(0, (scroll.documentView?.frame.width ?? 0) - clip.bounds.width)
        let x = min(max(clip.bounds.origin.x + step, 0), room)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Style.Motion.duration(Style.Motion.selection)
            context.timingFunction = Style.Motion.curve
            clip.animator().setBoundsOrigin(NSPoint(x: x, y: clip.bounds.origin.y))
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.scroll.reflectScrolledClipView(clip)
            self.updateArrows()
        }
    }

    /// Asks every chip where the pointer really is.
    private func refreshHover() {
        for chip in chips.values { chip.refreshHover() }
    }

    /// Which arrows have anywhere to go.
    private func updateArrows() {
        let clip = scroll.contentView
        let room = max(0, (scroll.documentView?.frame.width ?? 0) - clip.bounds.width)
        back.isHidden = clip.bounds.origin.x <= 0.5
        forward.isHidden = clip.bounds.origin.x >= room - 0.5
    }

    required init?(coder: NSCoder) {
        fatalError("ActivityScopeBar is created in code only")
    }

    /// Two lines of type and a mark beside them, with air around it.
    static let height: CGFloat = 42

    /// How wide the chips are altogether. Wider than the bar means there is
    /// something to scroll to.
    ///
    /// Added up from the chips rather than asked of the stack. The stack is
    /// laid out by frame, so its own fitting size is derived from the frame it
    /// was last given -- ask it how wide it wants to be and it answers with the
    /// width it already has, which is how a row that could not scroll kept
    /// insisting it was exactly the right size.
    var contentWidth: CGFloat {
        let chips = row.arrangedSubviews.filter { !$0.isHidden }
        guard !chips.isEmpty else { return 0 }
        let widths = chips.reduce(0) { $0 + $1.fittingSize.width }
        return widths + CGFloat(chips.count - 1) * row.spacing
    }

    override func layout() {
        super.layout()
        let clip = scroll.contentView
        // At least the clip's width, so a row of two chips still fills the
        // bar; wider than it whenever the chips need the room, which is what
        // gives the scroller something to do.
        let target = NSRect(
            x: 0,
            y: 0,
            width: max(contentWidth, clip.bounds.width),
            height: clip.bounds.height
        )
        guard row.frame != target else {
            updateArrows()
            return
        }
        row.frame = target
        // The clip view works out what can be scrolled from the document's
        // frame, and it only does that when it is told the frame moved.
        scroll.reflectScrolledClipView(clip)
        updateArrows()
    }

    func show(_ items: [Item], selected: ActivityScope) {
        let wanted = items.map(\.scope)
        if wanted != order {
            for view in row.arrangedSubviews {
                row.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            chips = [:]
            for item in items {
                let chip = ChipView(item: item) { [weak self] in self?.onSelect?(item.scope) }
                chips[item.scope] = chip
                row.addArrangedSubview(chip)
            }
            order = wanted
        }
        for item in items {
            chips[item.scope]?.update(item: item, isChosen: item.scope == selected)
        }
        // A chip that changed its number may have changed its width with it,
        // which moves the chips after it out from under the pointer.
        needsLayout = true
        refreshHover()
        // A newly chosen chip is brought into view -- a page you drilled into
        // is the last chip in the row, and a row scrolled away from it would be
        // showing where you are not. Only when it changes, though: doing it on
        // every sample undid every scroll within two seconds, which is what
        // made the row look like it could not scroll at all.
        if revealed != selected, let chosen = chips[selected] {
            revealed = selected
            layoutSubtreeIfNeeded()
            scroll.contentView.scrollToVisible(chosen.frame.insetBy(dx: -8, dy: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    /// A sideways scroller that takes an ordinary wheel.
    ///
    /// Most mice have no sideways wheel, and a trackpad swipe sideways is not
    /// what anybody tries first on a row of chips -- they scroll. The mapping
    /// has to live here rather than on the view around it: `NSScrollView`
    /// handles the wheel itself and does not pass it on, so an override on the
    /// bar was never reached, and the event died over the row instead of
    /// scrolling anything at all.
    ///
    /// When there is nothing left to scroll sideways the event is handed back
    /// up, so a wheel over the chips still scrolls the page they are on rather
    /// than stopping dead.
    @MainActor
    private final class SidewaysScrollView: NSScrollView {
        override func scrollWheel(with event: NSEvent) {
            let isVertical = abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX)
            guard isVertical else {
                super.scrollWheel(with: event)
                return
            }
            let clip = contentView
            let room = max(0, (documentView?.frame.width ?? 0) - clip.bounds.width)
            // Nothing to scroll sideways: the page may have the gesture, so a
            // wheel over a row that fits still scrolls what it is sitting on.
            guard room > 0 else {
                superview?.scrollWheel(with: event)
                return
            }
            // A trackpad reports points; a wheel reports lines, which are worth
            // about ten points each. Without that a mouse moved the row by
            // three points a notch and looked stuck.
            let delta = event.hasPreciseScrollingDeltas
                ? event.scrollingDeltaY
                : event.scrollingDeltaY * 10
            let wanted = clip.bounds.origin.x - delta
            let x = min(max(wanted, 0), room)
            // Kept, even at the end. Handing the gesture on once the row runs
            // out was worse than it sounds: a row starts at one end, so the
            // first direction anybody tries is the one with nowhere to go, and
            // the whole page jumped instead. A row that can scroll keeps the
            // gestures made over it.
            guard abs(x - clip.bounds.origin.x) > 0.01 else { return }
            clip.scroll(to: NSPoint(x: x, y: clip.bounds.origin.y))
            reflectScrolledClipView(clip)
        }
    }

    /// One place: a mark, a name, and what it costs.
    @MainActor
    private final class ChipView: SettingsPlateView {
        private let icon = NSImageView()
        private let titleLabel = NSTextField(labelWithString: "")
        private let detailLabel = NSTextField(labelWithString: "")
        private let onClick: () -> Void
        private var tint: NSColor = .controlAccentColor
        private var isChosen = false
        private var trackingArea: NSTrackingArea?
        private var isHovered = false {
            didSet {
                guard isHovered != oldValue else { return }
                applyColors()
            }
        }

        init(item: Item, onClick: @escaping () -> Void) {
            self.onClick = onClick
            super.init(frame: .zero)
            cornerRadius = 9

            icon.imageScaling = .scaleProportionallyDown
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.setAccessibilityElement(false)
            addSubview(icon)

            titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
            titleLabel.lineBreakMode = .byTruncatingTail
            titleLabel.setAccessibilityElement(false)

            detailLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
            detailLabel.textColor = Style.Colors.tertiaryText
            detailLabel.lineBreakMode = .byTruncatingTail
            detailLabel.setAccessibilityElement(false)

            let text = NSStackView(views: [titleLabel, detailLabel])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 0
            text.translatesAutoresizingMaskIntoConstraints = false
            addSubview(text)

            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: 32),
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 15),
                icon.heightAnchor.constraint(equalToConstant: 15),
                text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
                text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                text.centerYAnchor.constraint(equalTo: centerYAnchor),
                // Wide enough to read a name, short enough that four chips fit
                // where one pop-up used to.
                widthAnchor.constraint(lessThanOrEqualToConstant: 200)
            ])
            setAccessibilityRole(.button)
            update(item: item, isChosen: false)
        }

        required init?(coder: NSCoder) {
            fatalError("ChipView is created in code only")
        }

        func update(item: Item, isChosen: Bool) {
            tint = item.tint
            self.isChosen = isChosen
            titleLabel.stringValue = item.title
            detailLabel.stringValue = item.detail ?? ""
            detailLabel.isHidden = item.detail == nil
            if let image = item.image {
                icon.image = image
                icon.contentTintColor = nil
            } else if let symbol = item.symbol {
                icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
                icon.contentTintColor = isChosen ? item.tint : Style.Colors.secondaryText
            }
            toolTip = item.detail.map { "\(item.title) — \($0)" } ?? item.title
            setAccessibilityLabel(toolTip)
            setAccessibilityValue(isChosen ? "selected" : "")
            applyColors()
        }

        private func applyColors() {
            // The chosen chip is the only one wearing colour, and it wears the
            // space's own: the same hue the sidebar, the wash and the bars use
            // for that space, so the chip is not a fourth thing to learn.
            let colour = legible(tint)
            // Three states that differ in kind, not in brightness. Chosen is
            // the only one wearing colour; hovered is the same plate a shade
            // deeper, the way every other row in the browser lights up; the
            // rest are a plain field. A white-on-grey hover, which is what this
            // had, read exactly as loud as the selection did -- so a row with a
            // pointer somewhere in it had two chips claiming to be the one.
            fill = isChosen
                ? colour.withAlphaComponent(0.24)
                : (isHovered ? Style.Colors.rowHoverFill : Style.Colors.settingsControl)
            stroke = isChosen ? colour.withAlphaComponent(0.6) : Style.Colors.settingsControlStroke
            titleLabel.textColor = Style.Colors.primaryText
            titleLabel.font = .systemFont(ofSize: 12, weight: isChosen ? .semibold : .medium)
            detailLabel.textColor = isChosen ? Style.Colors.secondaryText : Style.Colors.tertiaryText
        }

        /// The tint, or the pane's own hue where the tint would be invisible.
        ///
        /// A space may be white, and a white chip on a white pane is a chip
        /// that says nothing about being chosen. The dot still shows the
        /// space's real colour; this is only what the plate behind it wears.
        private func legible(_ colour: NSColor) -> NSColor {
            guard let rgb = colour.usingColorSpace(.sRGB) else { return colour }
            let luminance = 0.2126 * rgb.redComponent
                + 0.7152 * rgb.greenComponent
                + 0.0722 * rgb.blueComponent
            let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let vanishes = isDark ? luminance < 0.22 : luminance > 0.76
            guard vanishes else { return colour }
            return settingsAccent ?? .controlAccentColor
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            applyColors()
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingArea = installHoverTracking(replacing: trackingArea)
            refreshHover()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            refreshHover()
        }

        /// Works out for itself whether the pointer is on this chip.
        ///
        /// An exit is not guaranteed, and this row is the worst case for it:
        /// the chips slide out from under a pointer that never moves whenever
        /// the row is scrolled, and their numbers are rewritten every two
        /// seconds. Without asking, half a row ends up painted as hovered --
        /// which, next to a chip that is genuinely chosen, made it impossible
        /// to tell which one you were actually looking at.
        func refreshHover() {
            isHovered = isPointerInside
        }

        override func mouseEntered(with event: NSEvent) { isHovered = true }
        override func mouseExited(with event: NSEvent) { isHovered = false }

        override func mouseDown(with event: NSEvent) {
            if acceptsSpringPress { press.flick() }
            onClick()
        }

        override func accessibilityPerformPress() -> Bool {
            onClick()
            return true
        }

        /// The squeeze the chip gives under a click. See `SpringPress`.
        private lazy var press = SpringPress(view: self)
    }
}
