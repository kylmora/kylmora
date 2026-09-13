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
    /// A suspended tab is dimmed rather than hidden: the memory really was
    /// released, and pretending otherwise would be a lie about state.
    var isSuspended: Bool = false
    var isFailed: Bool = false

    init(
        title: String,
        address: String? = nil,
        isLoading: Bool = false,
        isSuspended: Bool = false,
        isFailed: Bool = false
    ) {
        self.title = title
        self.address = address
        self.isLoading = isLoading
        self.isSuspended = isSuspended
        self.isFailed = isFailed
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

    /// Half the difference between the row and the pill, applied on every edge,
    /// so the pill is centred in the row whatever the two heights are.
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

        addSubview(favicon)
        addSubview(titleLabel)
        addSubview(spinner)
        addSubview(closeButton)
        textField = titleLabel

        let leading = favicon.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: contentInset + indentation
        )
        leadingConstraint = leading

        let spinnerTrailing = spinner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -contentInset)
        let closeTrailing = closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -contentInset)
        trailingConstraints = [spinnerTrailing, closeTrailing]

        NSLayoutConstraint.activate([
            leading,
            favicon.centerYAnchor.constraint(equalTo: centerYAnchor),

            titleLabel.leadingAnchor.constraint(
                equalTo: favicon.trailingAnchor,
                constant: Style.Metrics.rowContentSpacing
            ),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            // The title stops short of the trailing slot, so a long one is
            // truncated rather than run under the spinner or close button.
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: spinner.leadingAnchor,
                constant: -Style.Metrics.rowContentSpacing
            ),

            spinnerTrailing,
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 14),

            closeTrailing,
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("TabRowView is created in code only")
    }

    func configure(_ content: TabRowContent) {
        self.content = content
        titleLabel.stringValue = content.title
        titleLabel.textColor = content.isSuspended
            ? Style.Colors.secondaryText
            : Style.Colors.primaryText
        toolTip = content.address

        // VoiceOver reads the row, so state that is only shown visually --
        // dimming for suspended, a spinner for loading -- has to be spoken too.
        var described = content.title
        if content.isFailed {
            described += ", failed to load"
        } else if content.isSuspended {
            described += ", suspended"
        } else if content.isLoading {
            described += ", loading"
        }
        setAccessibilityRole(.row)
        setAccessibilityLabel(described)
        closeButton.setAccessibilityLabel("Close \(content.title)")
        updateTrailing()
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
    }

    /// The plate drawn behind a selected or hovered row.
    ///
    /// It starts at the row's own indent, not at the cell's edge. A full-width
    /// plate under an indented title is what made a folder's children read as
    /// loose rows: the only thing saying they were nested was the icon, and the
    /// selection undid even that. Exposed so the shape can be checked without
    /// rendering the view.
    var pillRect: NSRect {
        var pill = bounds.insetBy(dx: pillInset, dy: pillInset)
        pill.origin.x += indentation
        pill.size.width -= indentation
        if isInGroupPlate {
            // One indent level of trailing margin, matching the leading indent,
            // so the pill is inset from the plate by the same amount on both
            // sides rather than sitting flush against its right edge. This also
            // carries the pill's corners clear of the plate's rounded corners,
            // so the last row no longer bleeds into the bottom edge -- and the
            // pill stays centred in the row, so its content stays centred in it.
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
        // Set by `configure`, and the one thing there that is not derived
        // from `content` on the next configure if the new address is nil.
        toolTip = nil
    }
}
