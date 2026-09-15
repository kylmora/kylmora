import AppKit

/// One row in the archive: the page's icon and name, then where and when it
/// went.
///
/// Two lines rather than one. A tab you have not seen for a week is a tab you
/// will not recognise from its title alone -- the address is half of what makes
/// it identifiable, and the date is what makes the list make sense as a list.
///
/// Styled as a row of the sidebar, because that is where it lives: the same
/// favicon slot, the same pill on hover, and a remove button that appears while
/// the pointer is over it.
@MainActor
final class ArchivedRowView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("ArchivedRow")
    /// Two lines of text, taller than a tab row: the second line is what makes
    /// one archived tab distinguishable from another.
    static let rowHeight: CGFloat = 44

    /// Picked: the row was clicked. One click is the whole gesture -- it puts
    /// the tab back and goes to it -- the same reading the New Tab row uses.
    var onPick: (() -> Void)?

    /// The remove button. Nil, or a row nobody has hovered, hides it.
    var onRemove: (() -> Void)? {
        didSet { updateRemoveButton() }
    }

    /// Leading inset. Every archived row is top-level, but the leading edge is
    /// measured the same way a tab row measures it so the two lists line up.
    var indentation: CGFloat = Style.Metrics.sidebarInset {
        didSet { leadingConstraint?.constant = contentInset + indentation }
    }

    /// Exposed so the caller can drive it from an archived record without this
    /// view ever seeing one.
    let favicon = FaviconImageView()

    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private lazy var removeButton = IconButton(
        symbolName: "xmark",
        label: "Remove from Archive",
        side: 18,
        onClick: { [weak self] in self?.onRemove?() }
    )
    private var leadingConstraint: NSLayoutConstraint?
    private var trackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            needsDisplay = true
            updateRemoveButton()
        }
    }

    /// "3 days ago", the way the rest of macOS says it. Worth the width here --
    /// unlike the sidebar badge, this list has room and no other clock.
    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    /// Half the difference the tab rows keep between their row and their pill,
    /// so a pill in this list starts where a pill in that one does.
    private var pillInset: CGFloat {
        (Style.Metrics.rowHeight - Style.Metrics.rowPillHeight) / 2
    }

    /// Where the favicon starts: the pill's own margin plus the padding inside
    /// it, matching a tab row's.
    private var contentInset: CGFloat {
        pillInset + Style.Metrics.rowContentInset
    }

    init() {
        super.init(frame: .zero)

        titleLabel.font = Style.Fonts.body
        titleLabel.textColor = Style.Colors.primaryText
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.usesSingleLineMode = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        detailLabel.font = Style.Fonts.badge
        detailLabel.textColor = Style.Colors.secondaryText
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.cell?.usesSingleLineMode = true
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        removeButton.isHidden = true

        addSubview(favicon)
        addSubview(titleLabel)
        addSubview(detailLabel)
        addSubview(removeButton)
        textField = titleLabel
        imageView = favicon

        let leading = favicon.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: contentInset + indentation
        )
        leadingConstraint = leading

        NSLayoutConstraint.activate([
            leading,
            favicon.centerYAnchor.constraint(equalTo: centerYAnchor),

            titleLabel.leadingAnchor.constraint(
                equalTo: favicon.trailingAnchor,
                constant: Style.Metrics.rowContentSpacing
            ),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: removeButton.leadingAnchor,
                constant: -Style.Metrics.rowContentSpacing
            ),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            detailLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: removeButton.leadingAnchor,
                constant: -Style.Metrics.rowContentSpacing
            ),

            removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -contentInset),
            removeButton.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("ArchivedRowView is created in code only")
    }

    func configure(title: String, url: URL, spaceName: String?, archivedAt: Date) {
        titleLabel.stringValue = title
        let when = Self.relative.localizedString(for: archivedAt, relativeTo: .now)
        // The host, not the whole address: the detail line is there to tell two
        // similar titles apart, and a query string does not help with that.
        detailLabel.stringValue = [spaceName, url.host() ?? url.absoluteString, "archived \(when)"]
            .compactMap { $0 }
            .joined(separator: " \u{00b7} ")
        toolTip = url.absoluteString

        // No web view to ask, so discovery falls back to the `/favicon.ico`
        // convention. Never private: a private space keeps no archive, so
        // nothing in this list was ever private.
        favicon.show(for: url, in: nil, isPrivate: false)

        setAccessibilityRole(.row)
        setAccessibilityLabel("\(title), \(detailLabel.stringValue)")
    }

    /// The pill drawn behind a hovered row. Exposed so the shape can be checked
    /// without rendering the view.
    ///
    /// Taller than a tab row's pill: the row carries two lines, and a pill that
    /// only covered the first would read as a progress bar under the title.
    var pillRect: NSRect {
        var pill = bounds.insetBy(dx: pillInset, dy: 3)
        pill.origin.x += indentation
        pill.size.width -= indentation
        return pill
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isHovered, onPick != nil else { return }
        Style.Colors.rowHoverFill.setFill()
        NSBezierPath(
            roundedRect: pillRect,
            xRadius: Style.Metrics.rowCornerRadius,
            yRadius: Style.Metrics.rowCornerRadius
        ).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingArea = installHoverTracking(replacing: trackingArea)
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    /// A press anywhere but the remove button puts the tab back. The button
    /// takes its own clicks, because hit testing hands it the event first.
    override func mouseDown(with event: NSEvent) {
        onPick?()
    }

    override func accessibilityPerformPress() -> Bool {
        onPick?()
        return true
    }

    /// A recycled row must not inherit the previous record's hover state, the
    /// handler that would have put a different tab back, or its icon.
    override func prepareForReuse() {
        super.prepareForReuse()
        onPick = nil
        onRemove = nil
        isHovered = false
        toolTip = nil
        favicon.image = nil
    }

    private func updateRemoveButton() {
        removeButton.isHidden = !(isHovered && onRemove != nil)
    }
}
