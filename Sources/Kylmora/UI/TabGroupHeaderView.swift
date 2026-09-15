import AppKit

/// The header of a collapsible tab group: emoji, name, disclosure chevron.
///
/// The whole row is the hit target rather than just the chevron. A group header
/// has no other job -- there is nothing else a click on it could mean -- and a
/// 34-point row is a far easier target than an 11-point glyph.
@MainActor
final class TabGroupHeaderView: NSView {
    /// Called with the state the group is moving *to*.
    var onToggle: ((Bool) -> Void)?
    /// The cross at the trailing edge, shown while the header is hovered. Nil
    /// hides it.
    var onRemove: (() -> Void)? {
        didSet { updateHoverButtons() }
    }
    /// Opens the group's appearance editor. The three-dot at the trailing edge,
    /// shown while the header is hovered. Nil hides it.
    var onCustomize: (() -> Void)? {
        didSet { updateHoverButtons() }
    }

    private let emojiLabel = NSTextField(labelWithString: "")
    private lazy var removeButton = IconButton(symbolName: "xmark", label: "Remove Folder") { [weak self] in
        self?.onRemove?()
    }
    private lazy var customizeButton = IconButton(symbolName: "ellipsis", label: "Customize Folder") { [weak self] in
        self?.onCustomize?()
    }
    /// Shown in place of the cross on a locked folder. Not a button: there is
    /// nothing to click, and the point of it is to explain the cross's absence
    /// to someone who went looking for it.
    private let lockGlyph = NSImageView()
    private var isLocked = false
    private let titleLabel = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private var trackingArea: NSTrackingArea?

    /// The same margin a tab row leaves above and below its pill, so a hovered
    /// header and a hovered row under it are the same shape.
    private var pillInset: CGFloat {
        (Style.Metrics.rowHeight - Style.Metrics.rowPillHeight) / 2
    }
    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            needsDisplay = true
            updateHoverButtons()
        }
    }

    private(set) var isExpanded = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        emojiLabel.font = Style.Fonts.groupEmoji
        emojiLabel.setAccessibilityElement(false)
        emojiLabel.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = Style.Fonts.emphasis
        titleLabel.textColor = Style.Colors.primaryText
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.usesSingleLineMode = true
        titleLabel.setAccessibilityElement(false)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        chevron.imageScaling = .scaleProportionallyDown
        chevron.contentTintColor = Style.Colors.secondaryText
        chevron.setAccessibilityElement(false)
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [emojiLabel, titleLabel, chevron])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Style.Metrics.groupHeaderHeight),
            // Lines the emoji up with the favicons of the tabs underneath:
            // both start at the pill's margin plus the padding inside it, so a
            // folder's children read as one indent step in from their header.
            stack.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: pillInset + Style.Metrics.rowContentInset
            ),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: Style.Metrics.smallGlyphSide),
            chevron.heightAnchor.constraint(equalToConstant: Style.Metrics.smallGlyphSide)
        ])

        // Not required. The header is pinned to both edges of its row so the
        // hover plate spans the sidebar, and at a narrow width the emoji and
        // the chevron together can be wider than the room left for them. As a
        // required constraint that is a conflict, and the one Auto Layout broke
        // to resolve it was the height -- which took the whole header off the
        // screen. Letting this one break instead just lets the name overhang.
        let fit = stack.trailingAnchor.constraint(
            lessThanOrEqualTo: trailingAnchor,
            constant: -(pillInset + Style.Metrics.rowContentInset)
        )
        fit.priority = .defaultHigh
        fit.isActive = true

        removeButton.isHidden = true
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(removeButton)
        customizeButton.isHidden = true
        customizeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(customizeButton)
        lockGlyph.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "locked")
        lockGlyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        lockGlyph.contentTintColor = Style.Colors.tertiaryText
        lockGlyph.isHidden = true
        lockGlyph.setAccessibilityElement(false)
        lockGlyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(lockGlyph)
        NSLayoutConstraint.activate([
            removeButton.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -(pillInset + Style.Metrics.rowContentInset)
            ),
            removeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            // The three-dot sits just inside the cross, so the two hover
            // controls read as one cluster at the trailing edge.
            customizeButton.trailingAnchor.constraint(equalTo: removeButton.leadingAnchor, constant: -2),
            customizeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Exactly where the cross would have been, so the padlock reads as
            // its replacement rather than as one more thing on the row.
            lockGlyph.centerXAnchor.constraint(equalTo: removeButton.centerXAnchor),
            lockGlyph.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        setAccessibilityRole(.disclosureTriangle)
        applyExpansion()
    }

    required init?(coder: NSCoder) {
        fatalError("TabGroupHeaderView is created in code only")
    }

    /// - Parameter emoji: omitted when the group has none; the name then starts
    ///   where the emoji would have been, rather than after a blank gap.
    func show(emoji: String?, name: String, isExpanded: Bool, isLocked: Bool = false) {
        emojiLabel.stringValue = emoji ?? ""
        emojiLabel.isHidden = (emoji ?? "").isEmpty
        titleLabel.stringValue = name
        self.isExpanded = isExpanded
        self.isLocked = isLocked
        updateHoverButtons()
        applyExpansion()
    }

    private func updateHoverButtons() {
        // A locked folder never offers the cross, hovered or not. Everything
        // else on the header still works: the lock is on deleting the folder,
        // not on renaming, recolouring or folding it.
        removeButton.isHidden = !(isHovered && onRemove != nil && !isLocked)
        customizeButton.isHidden = !(isHovered && onCustomize != nil)
        lockGlyph.isHidden = !isLocked
    }

    /// Flips the group and tells the caller. Used by the click handler and by
    /// the accessibility press, so both paths behave identically.
    func toggle() {
        isExpanded.toggle()
        applyExpansion()
        onToggle?(isExpanded)
    }

    private func applyExpansion() {
        // `chevron.down` points at the content it is revealing; `chevron.right`
        // points at where the content would appear. The symbol changes rather
        // than rotating so the glyph stays optically correct at 11 points.
        let symbol = isExpanded ? "chevron.down" : "chevron.right"
        chevron.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        setAccessibilityValue(isExpanded)
        let name = titleLabel.stringValue
        setAccessibilityLabel(name.isEmpty ? "Tab group" : name)
        setAccessibilityLabel(isLocked ? "\(name.isEmpty ? "Tab group" : name), locked" : (name.isEmpty ? "Tab group" : name))
        toolTip = isExpanded ? "Collapse \(name)" : "Expand \(name)"
    }

    // No hover fill on a group header: you already know which group you are in,
    // so highlighting its title reads as a broken selection rather than an
    // affordance. Hover still reveals the remove and customise buttons.

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

    /// A press on a header is either a click, which toggles the group, or the
    /// start of a drag, which reorders it. Row dragging belongs to the enclosing
    /// table view, but only if the press reaches it -- so watch the mouse: a
    /// release without movement toggles here, while movement hands the original
    /// press up the responder chain to the table, which then runs the drag.
    override func mouseDown(with event: NSEvent) {
        let start = event.locationInWindow
        let threshold: CGFloat = 4
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp {
                toggle()
                return
            }
            let moved = hypot(
                next.locationInWindow.x - start.x,
                next.locationInWindow.y - start.y
            )
            if moved > threshold {
                super.mouseDown(with: event)
                return
            }
        }
    }

    override func accessibilityPerformPress() -> Bool {
        toggle()
        return true
    }
}
