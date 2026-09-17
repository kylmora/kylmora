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
            dots.centerYAnchor.constraint(equalTo: centerYAnchor),
            // ...but never over a button. With a dozen spaces the strip was
            // wider than the gap between the two slots and drew straight
            // through the Archive button, the last dot sitting on top of it.
            // Held off both, so the strip gives up width instead; what it does
            // with less is `PageDotStrip`'s business.
            clearOfButtons(
                dots.leadingAnchor.constraint(
                    greaterThanOrEqualTo: leadingSlot.trailingAnchor,
                    constant: Style.Metrics.iconButtonSpacing
                )
            ),
            clearOfButtons(
                dots.trailingAnchor.constraint(
                    lessThanOrEqualTo: trailingSlot.leadingAnchor,
                    constant: -Style.Metrics.iconButtonSpacing
                )
            )
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("SidebarFooterView is created in code only")
    }

    /// Holds the dots off a button, but not at any price.
    ///
    /// Required, these two set a floor under the whole sidebar: a split view
    /// item takes its minimum thickness from what its view says it needs, so
    /// with eleven spaces the sidebar would not drag narrower than about 220
    /// points -- the two buttons, the gaps and every dot at full width. The
    /// sidebar used to go down to 105 and people had it there.
    ///
    /// Below required, they shape the strip whenever there is room and give way
    /// when there is not, which is exactly when the fade in `PageDotStrip` is
    /// there to take over.
    private func clearOfButtons(_ constraint: NSLayoutConstraint) -> NSLayoutConstraint {
        constraint.priority = .defaultHigh
        return constraint
    }

    func setLeadingActions(_ actions: [TopBarAction]) { fill(leadingSlot, with: actions) }
    func setTrailingActions(_ actions: [TopBarAction]) { fill(trailingSlot, with: actions) }

    /// The button for one of the actions, to hang a popover on. Nil until the
    /// actions have been set, which is why a caller anchors through a closure
    /// rather than holding the view.
    func actionButton(labelled label: String) -> NSView? {
        for slot in [leadingSlot, trailingSlot] {
            if let button = slot.arrangedSubviews.first(where: { $0.accessibilityLabel() == label }) {
                return button
            }
        }
        return nil
    }

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

/// Where the dots sit when there are more of them than there is room for.
///
/// Separated from the view so the rule is a test rather than something only a
/// screenshot can confirm -- and the rule matters: with twelve spaces the strip
/// was wider than the gap between the two buttons, so it drew straight through
/// the Archive button and the last dot sat on top of it.
enum PageDotStrip {
    struct Layout: Equatable {
        /// How far the row of dots is slid left, in points.
        var offset: CGFloat
        /// The width the dots would take if nothing were in their way.
        var fullWidth: CGFloat
        /// Whether anything is cut off at the leading edge.
        var cutAtStart: Bool
        /// ...and at the trailing edge.
        var cutAtEnd: Bool
    }

    /// How far in from a cut edge a dot goes from invisible to solid.
    ///
    /// Two dot pitches. One is a hard edge -- a dot is either there or it is
    /// not -- and three fades so many dots that the row stops reading as a
    /// count of anything. At two, a dot leaves over the span of its neighbours,
    /// which is what makes the row look like it continues past the edge rather
    /// than like it was chopped.
    static var fadeLength: CGFloat { Style.Metrics.pageDotSpacing * 2 }

    static func fullWidth(count: Int) -> CGFloat {
        guard count > 1 else { return 0 }
        return CGFloat(count - 1) * Style.Metrics.pageDotSpacing + Style.Metrics.pageDotDiameter
    }

    /// The centre of one dot, measured in the strip's own coordinates before
    /// any sliding.
    static func centre(of index: Int) -> CGFloat {
        CGFloat(index) * Style.Metrics.pageDotSpacing + Style.Metrics.pageDotDiameter / 2
    }

    static func layout(count: Int, selected: Int, availableWidth: CGFloat) -> Layout {
        let full = fullWidth(count: count)
        guard full > availableWidth, availableWidth > 0 else {
            return Layout(offset: 0, fullWidth: full, cutAtStart: false, cutAtEnd: false)
        }
        // The space you are in stays in the middle of what is visible, so the
        // dot that means "you are here" is never the one that got cut off.
        let wanted = centre(of: selected) - availableWidth / 2
        let offset = min(max(wanted, 0), full - availableWidth)
        return Layout(
            offset: offset,
            fullWidth: full,
            cutAtStart: offset > 0.5,
            cutAtEnd: offset < full - availableWidth - 0.5
        )
    }

    /// How solid a dot is drawn, from 0 (gone) to 1.
    ///
    /// Only a cut edge fades. A row that fits is drawn exactly as it always
    /// was, and an edge where the dots genuinely stop is a real end, not a
    /// continuation, so fading it would be a lie about how many spaces there
    /// are.
    static func alpha(ofDotAt index: Int, in layout: Layout, availableWidth: CGFloat) -> CGFloat {
        let x = centre(of: index) - layout.offset
        var alpha: CGFloat = 1
        if layout.cutAtStart {
            alpha = min(alpha, max(0, x / fadeLength))
        }
        if layout.cutAtEnd {
            alpha = min(alpha, max(0, (availableWidth - x) / fadeLength))
        }
        return alpha
    }

    /// Which dot a click at `x` landed on, in view coordinates.
    static func index(at x: CGFloat, count: Int, in layout: Layout) -> Int? {
        guard count > 1 else { return nil }
        let inStrip = x + layout.offset
        let index = min(Int((inStrip / Style.Metrics.pageDotSpacing).rounded(.down)), count - 1)
        return index >= 0 ? index : nil
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
        // The strip gives way before the buttons either side of it do: it is an
        // indicator, and they are the only things down here you can press.
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
        // What the dots would like. What they get is whatever is left between
        // the buttons, and `draw` copes with the difference.
        NSSize(
            width: PageDotStrip.fullWidth(count: count),
            height: Style.Metrics.iconButtonSide
        )
    }

    /// Where the dots sit given the width the footer actually gave them.
    private var stripLayout: PageDotStrip.Layout {
        PageDotStrip.layout(count: count, selected: selected, availableWidth: bounds.width)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard count > 1, let context = NSGraphicsContext.current?.cgContext else { return }
        let diameter = Style.Metrics.pageDotDiameter
        let layout = stripLayout
        for index in 0..<count {
            let alpha = PageDotStrip.alpha(
                ofDotAt: index, in: layout, availableWidth: bounds.width
            )
            guard alpha > 0.01 else { continue }
            let origin = NSPoint(
                x: PageDotStrip.centre(of: index) - layout.offset - diameter / 2,
                y: (bounds.height - diameter) / 2
            )
            let color = index == selected
                ? Style.Colors.pageDotActive
                : Style.Colors.pageDotInactive
            // The context's alpha rather than the colour's: these are dynamic
            // colours with alphas of their own, and multiplying is what makes a
            // faded inactive dot stay fainter than a faded active one.
            context.saveGState()
            context.setAlpha(alpha)
            color.setFill()
            NSBezierPath(ovalIn: NSRect(origin: origin, size: NSSize(width: diameter, height: diameter))).fill()
            context.restoreGState()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard count > 1 else { return }
        let x = convert(event.locationInWindow, from: nil).x
        // Through the same layout the drawing used, so a click lands on the dot
        // that is under the pointer rather than on the one that would have been
        // there if nothing had slid.
        guard let index = PageDotStrip.index(at: x, count: count, in: stripLayout) else { return }
        if acceptsSpringPress { press.flick() }
        onSelect?(index)
    }

    /// The squeeze the dot strip gives under a click. See `SpringPress`.
    private lazy var press = SpringPress(view: self)
}
