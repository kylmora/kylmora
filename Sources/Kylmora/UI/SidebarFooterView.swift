import AppKit

/// The strip at the foot of the sidebar: one leading button, page dots in the
/// centre, one trailing button.
///
/// The dots are a space indicator, not decoration. Kylmora switches spaces with
/// Cmd-Option-arrow and a switcher list; the dots give that the same
/// at-a-glance position a paged view has, and clicking one selects the space.
@MainActor
final class SidebarFooterView: NSView {
    /// Selecting a space by clicking its dot.
    var onSelectPage: ((Int) -> Void)?

    private let leadingSlot = NSStackView()
    private let trailingSlot = NSStackView()
    private let dots = PageDotsView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        for slot in [leadingSlot, trailingSlot] {
            slot.orientation = .horizontal
            slot.spacing = Style.Metrics.iconButtonSpacing
            slot.translatesAutoresizingMaskIntoConstraints = false
            addSubview(slot)
        }
        dots.onSelect = { [weak self] index in self?.onSelectPage?(index) }
        addSubview(dots)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Style.Metrics.footerHeight),
            leadingSlot.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: Style.Metrics.sidebarInset
            ),
            leadingSlot.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingSlot.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -Style.Metrics.sidebarInset
            ),
            trailingSlot.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Centred on the sidebar, not between the two slots: the dots stay
            // put when a button is added or removed on either side.
            dots.centerXAnchor.constraint(equalTo: centerXAnchor),
            dots.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("SidebarFooterView is created in code only")
    }

    func setLeadingActions(_ actions: [TopBarAction]) { fill(leadingSlot, with: actions) }
    func setTrailingActions(_ actions: [TopBarAction]) { fill(trailingSlot, with: actions) }

    /// A single space needs no indicator, so `count <= 1` hides the dots
    /// entirely rather than showing one lonely dot.
    func showPages(count: Int, selected: Int) {
        dots.show(count: count, selected: selected)
    }

    private func fill(_ stack: NSStackView, with actions: [TopBarAction]) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for action in actions {
            stack.addArrangedSubview(
                IconButton(symbolName: action.symbolName, label: action.label, onClick: action.handler)
            )
        }
    }
}

/// The dots themselves, drawn rather than built from subviews: at six points
/// across, a stack of custom views costs more than the two lines of drawing it
/// would replace.
///
/// The view is as tall as the buttons either side of it even though the dots
/// are six points across, because a six-point-tall click target is a target
/// nobody hits. The dots are drawn centred in whatever height it is given.
@MainActor
final class PageDotsView: NSView {
    var onSelect: ((Int) -> Void)?

    private var count = 0
    private var selected = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.group)
        setAccessibilityLabel("Spaces")
        setAccessibilityElement(true)
    }

    required init?(coder: NSCoder) {
        fatalError("PageDotsView is created in code only")
    }

    func show(count: Int, selected: Int) {
        self.count = count
        self.selected = selected
        isHidden = count <= 1
        setAccessibilityValue("\(min(selected + 1, max(count, 1))) of \(count)")
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        let height = Style.Metrics.iconButtonSide
        guard count > 1 else { return NSSize(width: 0, height: height) }
        let width = CGFloat(count - 1) * Style.Metrics.pageDotSpacing + Style.Metrics.pageDotDiameter
        return NSSize(width: width, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard count > 1 else { return }
        let diameter = Style.Metrics.pageDotDiameter
        for index in 0..<count {
            let origin = NSPoint(
                x: CGFloat(index) * Style.Metrics.pageDotSpacing,
                y: (bounds.height - diameter) / 2
            )
            let color = index == selected
                ? Style.Colors.pageDotActive
                : Style.Colors.pageDotInactive
            color.setFill()
            NSBezierPath(ovalIn: NSRect(origin: origin, size: NSSize(width: diameter, height: diameter))).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard count > 1 else { return }
        let x = convert(event.locationInWindow, from: nil).x
        // Clamped rather than range-checked: the last dot's own width carries
        // the view a little past the final pitch boundary, and a click on the
        // right-hand half of the last dot is unambiguously a click on it.
        let index = min(Int((x / Style.Metrics.pageDotSpacing).rounded(.down)), count - 1)
        guard index >= 0 else { return }
        onSelect?(index)
    }
}
