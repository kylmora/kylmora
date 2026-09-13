import AppKit

/// Everything a tab row draws, as plain values.
///
/// Deliberately not a `Tab`: the row is then testable without a session, and a
/// row can be built for something that is not a tab at all. The one exception
/// is the favicon, which stays a `FaviconImageView` because that view already
/// owns the whole fetch-and-reuse dance and re-deriving it here would be worse
/// than the coupling.
struct TabRowContent {
    var title: String
    /// Shown in the tooltip and read by VoiceOver. `nil` for a row that has no
    /// address, such as a brand-new empty tab.
    var address: String?
    var isLoading: Bool = false
    /// Holding no web view: released after being loaded, or never loaded at
    /// all. Dimmed rather than hidden, because the memory really is not being
    /// held and pretending otherwise would be a lie about state. It also earns
    /// a moon on the trailing edge, because dimming alone is a difference
    /// nobody can name -- "is that row greyer than the others?" is not a thing
    /// a user should have to ask.
    var isAsleep: Bool = false
    var isFailed: Bool = false
    /// How long since the tab was last on screen, already formatted -- `10m`,
    /// `2h`. `nil` when the setting hides it, or the tab is too recent to say
    /// anything interesting.
    var idleText: String?
    /// The same fact for VoiceOver, which would read `10m` as two letters.
    var idleSpoken: String?
    /// Never suspended, by the user's instruction. Drawn as a filled pin so the
    /// lock is visible from the sidebar and not only from the menu that set it.
    var keepsAwake: Bool = false
    /// Never archived, by the user's instruction.
    var keepsInSidebar: Bool = false

    init(
        title: String,
        address: String? = nil,
        isLoading: Bool = false,
        isAsleep: Bool = false,
        isFailed: Bool = false,
        idleText: String? = nil,
        idleSpoken: String? = nil,
        keepsAwake: Bool = false,
        keepsInSidebar: Bool = false
    ) {
        self.title = title
        self.address = address
        self.isLoading = isLoading
        self.isAsleep = isAsleep
        self.isFailed = isFailed
        self.idleText = idleText
        self.idleSpoken = idleSpoken
        self.keepsAwake = keepsAwake
        self.keepsInSidebar = keepsInSidebar
    }
}

/// One row in the sidebar's tab list: favicon and title, with a spinner or a
/// close button on the trailing edge. A page thumbnail was also tried there
/// on the selected row; it was built and then removed at the user's request.
///
/// The row draws its own selection pill rather than using the table view's
/// highlight, because the pill is inset from the row on all four sides and
/// rounded; `NSTableView` cannot draw that. The consequence is that the table
/// must run with `selectionHighlightStyle = .none` and tell rows when they are
/// selected, which the integration note spells out.
@MainActor
final class TabRowView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("TabRow")

    /// Close button clicked. When `nil` the button never appears, which is what
    /// a row that is not a closable tab wants.
    var onClose: (() -> Void)?

    /// Exposed so the caller can drive it from a `Tab` without this view ever
    /// seeing one.
    let favicon = FaviconImageView()

    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            needsDisplay = true
            updateTrailing()
        }
    }

    /// Leading inset, on top of the pill's own. Rows inside a group are stepped
    /// in by `Style.Metrics.rowIndent`; loose rows pass 0.
    var indentation: CGFloat = Style.Metrics.rowIndent {
        didSet { leadingConstraint?.constant = contentInset + indentation }
    }

    /// A row inside a group's plate. Its pill -- and the close button and spinner
    /// inside it -- are inset from the plate's trailing edge by one indent level,
    /// mirroring the indent that already holds the content off the leading edge,
    /// so the whole row sits balanced inside the plate instead of running flush
    /// into its rounded right corner. Loose rows have no plate and keep the
    /// content out at the row edge.
    var isInGroupPlate = false {
        didSet {
            guard isInGroupPlate != oldValue else { return }
            let extra = isInGroupPlate ? Style.Metrics.rowIndent : 0
            for constraint in trailingConstraints { constraint.constant = -(contentInset + extra) }
            needsDisplay = true
        }
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    /// The band of the row the pill -- and everything in it -- occupies,
    /// pinned to the row's top edge.
    ///
    /// A row is normally exactly `rowHeight`, but the row that ends a folder's
    /// plate is taller, so that the plate has room under its last pill. Pinning
    /// the content here keeps the favicon, title and close button in the top
    /// `rowHeight` points of such a row instead of following its centre down
    /// into the padding; an ordinary row is unaffected.
    private let pillStrip = NSLayoutGuide()

    /// The trailing badge: the locks the user set, whether the tab is asleep,
    /// and how long it has been idle. A stack rather than four constraints
    /// because its contents come and go independently, and a stack with no
    /// visible arranged subview measures zero -- which is what lets the title
    /// run the full width of a row that has nothing to say.
    private let lockIcon = TabRowView.badgeIcon("lock.fill", label: "kept in sidebar")
    private let awakeIcon = TabRowView.badgeIcon("sun.max.fill", label: "kept awake")
    private let sleepIcon = TabRowView.badgeIcon("moon.zzz.fill", label: "sleeping")
    private let idleLabel = NSTextField(labelWithString: "")
    private lazy var badge: NSStackView = {
        let stack = NSStackView(views: [lockIcon, awakeIcon, sleepIcon, idleLabel])
        stack.orientation = .horizontal
        stack.spacing = 3
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        // The badge yields the row to the title before it truncates itself:
        // "10m" is worth less than another word of the page's name.
        stack.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        stack.setContentHuggingPriority(.required, for: .horizontal)
        return stack
    }()

    private static func badgeIcon(_ symbol: String, label: String) -> NSImageView {
        let view = NSImageView()
        view.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        view.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        view.contentTintColor = Style.Colors.tertiaryText
        view.isHidden = true
        view.setAccessibilityElement(false)
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }
    private lazy var closeButton = IconButton(
        symbolName: "xmark",
        label: "Close Tab",
        side: 18,
        onClick: { [weak self] in self?.onClose?() }
    )

    private var content = TabRowContent(title: "")
    private var leadingConstraint: NSLayoutConstraint?
    /// The spinner's and close button's trailing constraints, kept so a row on a
    /// group plate can pull them in to match the pill's trailing inset.
    private var trailingConstraints: [NSLayoutConstraint] = []
    private var trackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            needsDisplay = true
            updateTrailing()
        }
    }

    /// Half the difference between the row and the pill: the margin the pill
    /// keeps at the leading and trailing edges, and the one it keeps above and
    /// below itself in an ordinary row. A row taller than `rowHeight` -- the
    /// last one on a folder's plate -- keeps this margin at its top and puts
    /// every extra point underneath the pill, where the plate's bottom edge is.
    private var pillInset: CGFloat {
        (Style.Metrics.rowHeight - Style.Metrics.rowPillHeight) / 2
    }

    /// Where the favicon starts: the pill's own margin plus the padding inside
    /// it. Kept as one number so the close button on the trailing edge is inset
    /// by exactly as much as the icon on the leading one.
    private var contentInset: CGFloat {
        pillInset + Style.Metrics.rowContentInset
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        titleLabel.font = Style.Fonts.body
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.usesSingleLineMode = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setAccessibilityElement(false)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        closeButton.isHidden = true

        idleLabel.font = Style.Fonts.badge
        idleLabel.textColor = Style.Colors.tertiaryText
        idleLabel.setAccessibilityElement(false)
        idleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(favicon)
        addSubview(titleLabel)
        addSubview(badge)
        addSubview(spinner)
        addSubview(closeButton)
        textField = titleLabel

        addLayoutGuide(pillStrip)
        NSLayoutConstraint.activate([
            pillStrip.topAnchor.constraint(equalTo: topAnchor),
            pillStrip.leadingAnchor.constraint(equalTo: leadingAnchor),
            pillStrip.trailingAnchor.constraint(equalTo: trailingAnchor),
            pillStrip.heightAnchor.constraint(equalToConstant: Style.Metrics.rowHeight)
        ])

        let leading = favicon.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: contentInset + indentation
        )
        leadingConstraint = leading

        let spinnerTrailing = spinner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -contentInset)
        let closeTrailing = closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -contentInset)
        let badgeTrailing = badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -contentInset)
        trailingConstraints = [spinnerTrailing, closeTrailing, badgeTrailing]

        NSLayoutConstraint.activate([
            leading,
            favicon.centerYAnchor.constraint(equalTo: pillStrip.centerYAnchor),

            titleLabel.leadingAnchor.constraint(
                equalTo: favicon.trailingAnchor,
                constant: Style.Metrics.rowContentSpacing
            ),
            titleLabel.centerYAnchor.constraint(equalTo: pillStrip.centerYAnchor),
            // The title stops short of the trailing slot, so a long one is
            // truncated rather than run under the spinner or close button.
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: spinner.leadingAnchor,
                constant: -Style.Metrics.rowContentSpacing
            ),
            // And short of the badge, which is wider than the slot and shares
            // the same edge. An empty badge measures zero, so this constraint
            // costs a row with nothing to report exactly nothing.
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: badge.leadingAnchor,
                constant: -Style.Metrics.rowContentSpacing
            ),

            badgeTrailing,
            badge.centerYAnchor.constraint(equalTo: pillStrip.centerYAnchor),

            spinnerTrailing,
            spinner.centerYAnchor.constraint(equalTo: pillStrip.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 14),

            closeTrailing,
            closeButton.centerYAnchor.constraint(equalTo: pillStrip.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("TabRowView is created in code only")
    }

    func configure(_ content: TabRowContent) {
        self.content = content
        titleLabel.stringValue = content.title
        titleLabel.textColor = content.isAsleep
            ? Style.Colors.secondaryText
            : Style.Colors.primaryText
        toolTip = content.address

        // VoiceOver reads the row, so state that is only shown visually --
        // dimming for suspended, a spinner for loading -- has to be spoken too.
        var described = content.title
        if content.isFailed {
            described += ", failed to load"
        } else if content.isAsleep {
            described += ", sleeping"
        } else if content.isLoading {
            described += ", loading"
        }
        // The locks and the timer are spoken whatever the state above, because
        // each is a separate fact about the row and any of them can be the one
        // the listener is looking for.
        if content.keepsAwake { described += ", kept awake" }
        if content.keepsInSidebar { described += ", kept in sidebar" }
        if let spoken = content.idleSpoken { described += ", \(spoken)" }
        setAccessibilityRole(.row)
        setAccessibilityLabel(described)
        closeButton.setAccessibilityLabel("Close \(content.title)")
        updateTrailing()
    }

    /// Updates only the idle timer, for the sidebar's tick.
    ///
    /// Not `configure`: that re-runs the favicon lookup, and a badge that
    /// counts minutes would then re-fetch every icon in the sidebar for the
    /// rest of the session. Returns whether anything actually changed, so a
    /// tick over an unchanged sidebar costs one string comparison per row.
    @discardableResult
    func updateIdle(text: String?, spoken: String?) -> Bool {
        guard text != content.idleText else { return false }
        content.idleText = text
        content.idleSpoken = spoken
        updateTrailing()
        // The row's spoken label carries the timer, so it has to be rebuilt
        // with it rather than left describing a tab that went quiet an hour ago.
        configure(content)
        return true
    }

    /// The trailing edge has two candidates for one slot -- close button and
    /// spinner -- so the precedence lives in one place rather than in two
    /// `isHidden` assignments scattered through the class. The close button
    /// wins, because a row the pointer is over is a row the user is about to
    /// act on, and the selected row shows it too: the tab you are looking at
    /// is the one you most often want to close.
    private func updateTrailing() {
        let canClose = onClose != nil
        let showClose = (isHovered || isSelected) && canClose
        closeButton.isHidden = !showClose
        if content.isLoading && !showClose {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }

        // Third in line for the one trailing slot, and it yields to both of the
        // others: reaching for the close button should not have to aim past a
        // moon, and a row that is loading is not idle by definition.
        let showBadge = !showClose && !content.isLoading
        lockIcon.isHidden = !(showBadge && content.keepsInSidebar)
        awakeIcon.isHidden = !(showBadge && content.keepsAwake)
        sleepIcon.isHidden = !(showBadge && content.isAsleep)
        let idle = showBadge ? content.idleText : nil
        idleLabel.stringValue = idle ?? ""
        idleLabel.isHidden = idle == nil
    }

    /// The plate drawn behind a selected or hovered row.
    ///
    /// It starts at the row's own indent, not at the cell's edge. A full-width
    /// plate under an indented title is what made a folder's children read as
    /// loose rows: the only thing saying they were nested was the icon, and the
    /// selection undid even that. Exposed so the shape can be checked without
    /// rendering the view.
    var pillRect: NSRect {
        // The pill keeps its own height whatever the row's. A row taller than
        // `rowHeight` -- the last one on a folder's plate -- spends its extra
        // points below the pill, inside the plate, rather than stretching the
        // pill down to meet the plate's bottom edge and reading as part of the
        // card's outline. It is anchored to the row's top edge, which is the
        // same thing in an ordinary row and keeps the rhythm of the rows above
        // it in a taller one.
        var pill = NSRect(
            x: pillInset,
            y: isFlipped ? pillInset : bounds.height - pillInset - Style.Metrics.rowPillHeight,
            width: bounds.width - 2 * pillInset,
            height: Style.Metrics.rowPillHeight
        )
        pill.origin.x += indentation
        pill.size.width -= indentation
        if isInGroupPlate {
            // One indent level of trailing margin, matching the leading indent,
            // so the pill is inset from the plate by the same amount on both
            // sides rather than sitting flush against its right edge. The
            // plate's bottom edge is cleared by the row's own height instead:
            // the row that ends the plate carries `folderPlateBottomPadding`
            // below its pill.
            pill.size.width -= Style.Metrics.rowIndent
        }
        return pill
    }

    override func draw(_ dirtyRect: NSRect) {
        let fill: NSColor?
        if isSelected {
            fill = Style.Colors.rowSelectedFill
        } else if isHovered {
            fill = Style.Colors.rowHoverFill
        } else {
            fill = nil
        }
        guard let fill else { return }
        fill.setFill()
        NSBezierPath(
            roundedRect: pillRect,
            xRadius: Style.Metrics.rowCornerRadius,
            yRadius: Style.Metrics.rowCornerRadius
        ).fill()
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
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    /// A recycled row must not inherit the previous tab's hover state, and the
    /// close handler must be cleared before the next configure so a stale
    /// closure cannot close the wrong tab.
    override func prepareForReuse() {
        super.prepareForReuse()
        onClose = nil
        isHovered = false
        isSelected = false
        content = TabRowContent(title: "")
        for view in [lockIcon, awakeIcon, sleepIcon] { view.isHidden = true }
        idleLabel.stringValue = ""
        idleLabel.isHidden = true
        // Set by `configure`, and the one thing there that is not derived
        // from `content` on the next configure if the new address is nil.
        toolTip = nil
    }
}
