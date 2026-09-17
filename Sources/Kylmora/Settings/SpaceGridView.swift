import AppKit

/// What a card says about a space beyond its name.
///
/// Two different things share the left edge of a card and must not be confused
/// with each other: the round dot is the space's *own colour*, which is
/// identity -- it is the colour the window wears while you are in that space --
/// and these are *state*. So state is drawn differently on purpose: a squared
/// chip with a letter in it, in a fixed colour that means the same thing on
/// every card, rather than another coloured circle that would read as a second
/// identity.
///
/// A letter and not a symbol, because "A" and "P" survive being drawn at eleven
/// points where a glyph turns to mush -- and because the key under the grid can
/// then show the very same chip beside the word it stands for.
enum SpaceBadge: CaseIterable {
    /// The space in front right now. Not the same as the selected card: you
    /// can stand in Personal and edit Work, and the grid has to say which is
    /// which.
    case active
    /// An ephemeral space. Nothing it browses is written to disk.
    case isPrivate

    var letter: String {
        switch self {
        case .active: "A"
        case .isPrivate: "P"
        }
    }

    /// The word the key spells out beside the chip.
    var title: String {
        switch self {
        case .active: "Active"
        case .isPrivate: "Private"
        }
    }

    /// What it means, for the tooltip and for VoiceOver.
    var explanation: String {
        switch self {
        case .active: "The space in front right now"
        case .isPrivate: "Nothing this space browses is written to disk"
        }
    }

    /// Fixed, and deliberately not a space's own colour: a badge has to mean
    /// the same thing on a green space and a pink one. Green for the space you
    /// are standing in, purple for private -- the colour macOS itself uses for
    /// private browsing.
    var tint: NSColor {
        switch self {
        case .active: .systemGreen
        case .isPrivate: .systemPurple
        }
    }
}

/// One letter chip. Shared by the cards and by the key under them, so the two
/// cannot drift apart.
@MainActor
final class SpaceBadgeView: SettingsPlateView {
    nonisolated static let side: CGFloat = 16

    let badge: SpaceBadge

    init(_ badge: SpaceBadge) {
        self.badge = badge
        super.init(frame: .zero)
        cornerRadius = 5

        let letter = NSTextField(labelWithString: badge.letter)
        letter.font = .systemFont(ofSize: 10, weight: .bold)
        letter.alignment = .center
        letter.setAccessibilityElement(false)
        letter.translatesAutoresizingMaskIntoConstraints = false
        addSubview(letter)

        // A tinted plate with the letter in the tint at full strength: a solid
        // fill at this size turns the letter into a smear, and an outline alone
        // disappears against the card.
        fill = badge.tint.withAlphaComponent(0.20)
        letter.textColor = badge.tint

        toolTip = "\(badge.title): \(badge.explanation)"
        setAccessibilityLabel(badge.title)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
            letter.centerXAnchor.constraint(equalTo: centerXAnchor),
            letter.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("SpaceBadgeView is created in code only")
    }
}

/// The key under the grid: each chip beside the word it stands for.
///
/// A letter in a box is only legible if something says what the letter is. It
/// is built from `SpaceBadge.allCases`, so a badge added later appears in the
/// key without anyone remembering to add it.
@MainActor
final class SpaceBadgeKeyView: NSStackView {
    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 14
        translatesAutoresizingMaskIntoConstraints = false

        for badge in SpaceBadge.allCases {
            let word = NSTextField(labelWithString: badge.title)
            word.font = Style.Fonts.note
            word.textColor = Style.Colors.tertiaryText
            word.setAccessibilityElement(false)
            let pair = NSStackView(views: [SpaceBadgeView(badge), word])
            pair.orientation = .horizontal
            pair.alignment = .centerY
            pair.spacing = 5
            pair.setAccessibilityLabel("\(badge.title): \(badge.explanation)")
            addArrangedSubview(pair)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("SpaceBadgeKeyView is created in code only")
    }
}

/// How many spaces fit across, how wide each card is, and how tall the result
/// is.
///
/// Separated from the view, like `TileGrid`, so the wrapping rule is something
/// a test can state rather than something only a screenshot can confirm.
enum SpaceGrid {
    struct Plan: Equatable {
        var columns: Int
        var cellWidth: CGFloat
        var rows: Int
        var height: CGFloat
    }

    /// A card's height: a 12-point dot and a line of row text, with air.
    static let cellHeight: CGFloat = 34
    static let spacing: CGFloat = 8

    /// Below this a card cannot hold a dot and enough of a name to tell two
    /// spaces apart, so the grid wraps to another row instead of shrinking
    /// further.
    static let minimumCellWidth: CGFloat = 150

    /// And above this a card stops growing, because there is nothing left to
    /// show: a name cannot be longer than `Space.maximumNameLength`, so once a
    /// card can hold the longest legal name, a wider one is just a wider card.
    ///
    /// Measured rather than guessed -- the widest string the limit permits, in
    /// the font the cards actually use, plus the dot, the gap and the padding
    /// either side. "M" because it is the widest character in the face; a name
    /// of twenty-four Ms is not a name anyone will type, but it is the one this
    /// has to survive.
    static var maximumCellWidth: CGFloat {
        let widest = String(repeating: "M", count: Space.maximumNameLength)
        let text = NSAttributedString(
            string: widest, attributes: [.font: Style.Fonts.settingsRow]
        ).size().width
        // Plus room for both chips, so the longest legal name still fits on a
        // card that is also saying the space is active and private.
        let badges = CGFloat(SpaceBadge.allCases.count) * (SpaceBadgeView.side + badgeGap)
        return ceil(text) + dotSide + dotGap + badges + padding * 2
    }

    /// Between a chip and whatever is before it.
    static let badgeGap: CGFloat = 5

    static let dotSide: CGFloat = 12
    static let dotGap: CGFloat = 8
    static let padding: CGFloat = 10

    static func plan(itemCount: Int, availableWidth: CGFloat) -> Plan {
        let count = max(itemCount, 1)
        guard availableWidth > 0 else {
            return Plan(
                columns: 1, cellWidth: minimumCellWidth, rows: count,
                height: CGFloat(count) * cellHeight + CGFloat(count - 1) * spacing
            )
        }

        let fitting = Int((availableWidth + spacing) / (minimumCellWidth + spacing))
        // Never more columns than there are spaces, or one space stretches the
        // whole width of the card and reads as a banner rather than a card.
        let columns = max(1, min(count, fitting))
        let even = (availableWidth - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let width = min(even, maximumCellWidth)
        let rows = Int(ceil(Double(count) / Double(columns)))
        let height = CGFloat(rows) * cellHeight + CGFloat(rows - 1) * spacing
        return Plan(columns: columns, cellWidth: width, rows: rows, height: height)
    }
}

/// The spaces on the Spaces pane, as a wrapping grid of cards.
///
/// It was a one-column table: twelve spaces became twelve rows down a card that
/// is six hundred points wide, with five hundred of them empty beside every
/// name, and the list ran out of room and started scrolling at ten. Spaces are
/// short-named things you pick from, which is a grid -- the same shape, and the
/// same wrapping rule, as the pinned tiles in the sidebar.
@MainActor
final class SpaceGridView: NSView {
    /// Which space was clicked. The pane decides what selecting means.
    var onSelect: ((Space) -> Void)?

    private var cells: [SpaceCardView] = []
    private(set) var spaces: [Space] = []

    /// Rows are numbered from the top, so the grid has to be too -- otherwise
    /// the first row is drawn at the bottom and the spaces read backwards.
    override var isFlipped: Bool { true }

    func show(_ spaces: [Space], selected: Space?, active: Space?) {
        // Rebuilt only when the spaces themselves change. A selection moving
        // from one card to another is a repaint, not a rebuild, so clicking
        // around the grid does not throw away and remake every card.
        if self.spaces.map(\.id) != spaces.map(\.id) {
            for cell in cells { cell.removeFromSuperview() }
            cells = spaces.map { space in
                let cell = SpaceCardView(space: space) { [weak self] in
                    self?.onSelect?(space)
                }
                addSubview(cell)
                return cell
            }
            self.spaces = spaces
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
        for (cell, space) in zip(cells, spaces) {
            cell.show(space, isSelected: space === selected, isActive: space === active)
        }
    }

    override func layout() {
        super.layout()
        let plan = SpaceGrid.plan(itemCount: cells.count, availableWidth: bounds.width)
        // The number of rows is only knowable once the width is, and the width
        // is only known here. See `PinnedTilesView`, which wraps the same way.
        if abs(plan.height - bounds.height) > 0.5 {
            invalidateIntrinsicContentSize()
        }
        for (index, cell) in cells.enumerated() {
            let column = index % plan.columns
            let row = index / plan.columns
            cell.frame = NSRect(
                x: CGFloat(column) * (plan.cellWidth + SpaceGrid.spacing),
                y: CGFloat(row) * (SpaceGrid.cellHeight + SpaceGrid.spacing),
                width: plan.cellWidth,
                height: SpaceGrid.cellHeight
            )
        }
    }

    override var intrinsicContentSize: NSSize {
        let plan = SpaceGrid.plan(itemCount: cells.count, availableWidth: bounds.width)
        return NSSize(width: NSView.noIntrinsicMetric, height: plan.height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        // A narrower grid may need another row, and the height it reports has
        // to change with it or whatever is below it overlaps.
        if widthChanged { invalidateIntrinsicContentSize() }
    }
}

/// One space, as a card: its colour, its name, and whether it is private.
@MainActor
final class SpaceCardView: NSView {
    private let dot = NSImageView()
    private let label = NSTextField(labelWithString: "")
    /// One view per badge, built once and shown or hidden: a card that gains a
    /// chip must not have to rebuild its stack to get one.
    private let badges: [(badge: SpaceBadge, view: SpaceBadgeView)] =
        SpaceBadge.allCases.map { ($0, SpaceBadgeView($0)) }
    private let onClick: () -> Void
    private var highlight: RowHighlight?
    private var trackingArea: NSTrackingArea?
    private var isSelected = false
    private var isHovered = false {
        didSet { if isHovered != oldValue { updateHighlight() } }
    }

    init(space: Space, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
        if let layer { highlight = RowHighlight(in: layer, depth: .raised) }

        dot.setAccessibilityElement(false)
        dot.translatesAutoresizingMaskIntoConstraints = false

        label.font = Style.Fonts.settingsRow
        label.textColor = Style.Colors.primaryText
        // The name is cut with an ellipsis rather than pushing the badge off
        // the card. It cannot be longer than `Space.maximumNameLength`, and the
        // grid's cells are wide enough for that -- but a card in the last
        // column of a narrow window can still be narrower than its content.
        label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityElement(false)
        label.setContentCompressionResistancePriority(.init(249), for: .horizontal)

        for (badge, view) in badges {
            view.isHidden = true
            _ = badge
        }

        let stack = NSStackView(views: [dot, label] + badges.map(\.view))
        stack.orientation = .horizontal
        stack.spacing = SpaceGrid.badgeGap
        // The name is the thing the dot belongs to; the chips are a group at
        // the end. Only the gap after the dot is the dot's own.
        stack.setCustomSpacing(SpaceGrid.dotGap, after: dot)
        stack.setCustomSpacing(SpaceGrid.dotGap, after: label)
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: SpaceGrid.dotSide),
            dot.heightAnchor.constraint(equalToConstant: SpaceGrid.dotSide),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SpaceGrid.padding),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -SpaceGrid.padding),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        show(space, isSelected: false, isActive: false)
    }

    required init?(coder: NSCoder) {
        fatalError("SpaceCardView is created in code only")
    }

    func show(_ space: Space, isSelected: Bool, isActive: Bool) {
        dot.image = space.dotImage(side: SpaceGrid.dotSide)
        label.stringValue = space.name
        var shown: [SpaceBadge] = []
        for (badge, view) in badges {
            let applies = switch badge {
            case .active: isActive
            case .isPrivate: space.isPrivate
            }
            view.isHidden = !applies
            if applies { shown.append(badge) }
        }
        // Spelled out for VoiceOver, which cannot see that a letter in a box is
        // a badge: "Work, active, private".
        setAccessibilityLabel(
            ([space.name] + shown.map { $0.title.lowercased() }).joined(separator: ", ")
        )
        setAccessibilityRole(.button)
        if self.isSelected != isSelected {
            self.isSelected = isSelected
            updateHighlight()
        }
    }

    override func layout() {
        super.layout()
        highlight?.layout(
            bounds, in: bounds.height, flipped: isFlipped,
            radius: Style.SettingsUI.spineRowRadius, scale: highlightScale
        )
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        highlight?.refresh(appearance: effectiveAppearance)
    }

    private func updateHighlight() {
        let state: RowHighlight.State
        if isSelected {
            state = .selected
        } else if isHovered {
            state = .hover
        } else {
            state = .rest
        }
        highlight?.apply(state, appearance: effectiveAppearance)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingArea = installHoverTracking(replacing: trackingArea)
        isHovered = isPointerInside
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    /// The squeeze under the click, the same one every other card gives.
    private lazy var press = SpringPress(view: self)

    override func mouseDown(with event: NSEvent) {
        guard acceptsSpringPress else { return }
        press.down()
    }

    override func mouseUp(with event: NSEvent) {
        press.up()
        // Only when the mouse came up on the card it went down on, which is
        // what a click means everywhere else.
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick()
        }
    }
}
