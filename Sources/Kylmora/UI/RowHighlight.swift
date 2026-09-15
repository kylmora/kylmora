import AppKit
import QuartzCore

/// The plate drawn behind a row, a tile or a button when it is hovered or
/// selected, and the animation between those states.
///
/// Every list in this app -- sidebar tabs, the archive, downloads, the folder
/// popover, the command bar -- draws the same shape for the same three states,
/// and before this each of them drew it by hand in `draw(_:)`. That had two
/// costs. The small one was the repetition. The large one was that a fill
/// painted in `draw(_:)` cannot animate, cannot carry a shadow that falls
/// outside the view's bounds, and cannot have a hairline that stays one device
/// pixel wide at any scale -- so hover and selection blinked on and off, and a
/// selected row had a flat fill and nothing else to lift it off the surface.
///
/// A `CALayer` does all three. The state change animates because the layer is a
/// manually added sublayer rather than a view's backing layer, so Core
/// Animation's implicit animations still apply to it and a `CATransaction` sets
/// their duration and curve. Reduce Motion is honoured by using a zero duration,
/// so the state still changes, it simply does not travel.
///
/// The owner supplies the shape (`layout`) and the state (`apply`); everything
/// about how the three states look lives here, once.
@MainActor
final class RowHighlight {
    enum State {
        /// Nothing drawn at all.
        case rest
        /// The pointer is on it.
        case hover
        /// It is the current row, tab or tile.
        case selected
    }

    /// How a selected plate is drawn. Rows want the full treatment; a small
    /// control that is merely switched on wants the fill alone, because a
    /// shadow under a 29-point button reads as a smudge.
    enum Depth {
        /// Fill only.
        case flat
        /// Fill, hairline, and a soft shadow: for a row-sized plate that has to
        /// read as lifted off the material behind it.
        case raised
    }

    private(set) var state: State = .rest

    private let fill = CALayer()
    private let depth: Depth
    private var radius: CGFloat = Style.Metrics.rowCornerRadius

    /// - Parameter host: the layer this draws into. The caller is responsible
    ///   for making its view layer-backed first; a `nil` layer is a programming
    ///   error rather than a state to degrade into, so it is not accepted.
    init(in host: CALayer, depth: Depth = .raised) {
        self.depth = depth
        fill.cornerCurve = .continuous
        fill.masksToBounds = false
        fill.opacity = 0
        // The frame is set from `layout` on every pass, and a plate that eased
        // into its new position on a window resize would smear behind the rows.
        fill.actions = [
            "bounds": NSNull(), "position": NSNull(),
            "cornerRadius": NSNull(), "shadowPath": NSNull()
        ]
        // Below whatever the view puts in its own layer, so the plate is a
        // background rather than a veil over the title.
        host.insertSublayer(fill, at: 0)
    }

    /// Positions the plate. Call from the owner's `layout()`.
    ///
    /// - Parameters:
    ///   - rect: the plate's shape, in the owner's coordinates.
    ///   - flipped: whether the owner's y axis runs downwards, which a layer's
    ///     never does. A flipped view hands `rect` in flipped coordinates, so
    ///     they are turned back here rather than at every call site.
    ///   - height: the owner's own height, needed to do that flip.
    func layout(_ rect: NSRect, in height: CGFloat, flipped: Bool, radius: CGFloat, scale: CGFloat) {
        var frame = rect
        if flipped { frame.origin.y = height - rect.maxY }
        self.radius = radius
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = frame
        fill.cornerRadius = radius
        fill.contentsScale = scale
        fill.shadowPath = CGPath(
            roundedRect: CGRect(origin: .zero, size: frame.size),
            cornerWidth: radius, cornerHeight: radius, transform: nil
        )
        CATransaction.commit()
    }

    /// Moves to a state, animating unless told not to.
    ///
    /// - Parameter animated: `false` for a recycled table cell being configured
    ///   for a different row, which must arrive already looking right rather
    ///   than fading from whatever the last occupant of the cell looked like.
    func apply(_ next: State, appearance: NSAppearance, animated: Bool = true) {
        let previous = state
        state = next
        // A selection is slower than a hover, and a change involving one moves
        // at the selection's pace in both directions.
        let base = (previous == .selected || next == .selected)
            ? Style.Motion.selection
            : Style.Motion.hover
        let duration = animated ? Style.Motion.duration(base) : 0

        // Resolved here rather than stored: a `CGColor` is one appearance's
        // answer, and the window can change appearance under a live layer.
        var background: CGColor?
        var border: CGColor?
        var shadow: CGColor?
        appearance.performAsCurrentDrawingAppearance {
            switch next {
            case .rest:
                break
            case .hover:
                background = Style.Colors.rowHoverFill.cgColor
            case .selected:
                background = Style.Colors.rowSelectedFill.cgColor
                if depth == .raised {
                    border = Style.Colors.rowSelectedStroke.cgColor
                    shadow = Style.Colors.rowSelectedShadow.cgColor
                }
            }
        }

        CATransaction.begin()
        // An un-animated apply is authoritative: it has to overrule whatever
        // was still travelling, or a recycled table cell finishes the previous
        // occupant's fade after being told to arrive already correct.
        if duration == 0 { fill.removeAllAnimations() }
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(Style.Motion.curve)
        CATransaction.setDisableActions(duration == 0)
        // The colours are set even on the way to `.rest`, so the plate fades
        // out in the colour it was rather than snapping to the next state's
        // colour and then fading.
        if let background { fill.backgroundColor = background }
        fill.borderColor = border
        fill.borderWidth = border == nil ? 0 : Style.Metrics.hairline
        fill.shadowColor = shadow
        fill.shadowOpacity = shadow == nil ? 0 : 1
        fill.shadowRadius = Style.Metrics.rowShadowRadius
        // Positive y is up in a layer, so a shadow below the plate is negative.
        fill.shadowOffset = CGSize(width: 0, height: -Style.Metrics.rowShadowOffset)
        fill.opacity = next == .rest ? 0 : 1
        CATransaction.commit()
    }

    /// Re-resolves the current state's colours, for a window that has just
    /// changed between light and dark.
    func refresh(appearance: NSAppearance) {
        let current = state
        state = .rest
        apply(current, appearance: appearance, animated: false)
    }
}

extension NSView {
    /// The plate's backing scale, from the screen it is on. One until the view
    /// is in a window, which is the right answer for a view that is not yet on
    /// screen and will be asked again when it is.
    var highlightScale: CGFloat { window?.backingScaleFactor ?? 2 }
}
