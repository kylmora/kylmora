import AppKit

/// Every number the overlay is drawn and animated with.
///
/// Collected here for the same reason `Style` exists, and kept pure so the
/// layout can be checked at window sizes nobody will think to drag to.
enum GlanceGeometry {
    /// The panel is 80 % of the content width. At that fraction the page
    /// behind stays visible down both sides, which is the whole point: a glance
    /// that covered everything would just be a tab.
    static let widthFraction: CGFloat = 0.8

    /// Kylmora insets the panel by the standard gutter rather than running it
    /// full height, because the shadow is drawn *outside* the card here rather
    /// than composited into a page that already has room for it, and a
    /// shadow clipped by the window edge reads as a rendering error.
    static let verticalInset = Style.Metrics.elementSeparation

    static let cornerRadius = Style.Metrics.contentCornerRadius

    /// The shadow: `rgba(0,0,0,0.24) 0 3px 8px`. CSS's second length is
    /// a downward offset and its third is the blur diameter; `NSShadow`'s
    /// `blurRadius` is that same diameter and its offset is in the view's
    /// flipped-or-not space, so on an unflipped AppKit layer the sign inverts.
    static let shadowOpacity: Float = 0.24
    static let shadowOffset = CGSize(width: 0, height: -3)
    static let shadowBlur: CGFloat = 8

    /// The rail: `top: 15px`, padding `12px`, gap `12px`, max-width `56px`,
    /// 32-point round buttons.
    static let railTopInset: CGFloat = 15
    static let railPadding: CGFloat = 12
    static let railSpacing: CGFloat = 12
    static let railButtonSide: CGFloat = 32
    static var railWidth: CGFloat { railButtonSide + railPadding * 2 }

    static let animationDuration: TimeInterval = 0.35

    /// The parent page shrinks and dims behind the panel. The two numbers work
    /// together, and are most of what makes the glance read as something laid
    /// *over* the page rather than part of it.
    static let ownerScale: CGFloat = 0.97
    static let backdropOpacity: Float = 0.3

    /// `easeOutBack` -- the overshoot on the way out. Control points outside
    /// `0...1` are legal for `CAMediaTimingFunction`, which is what makes a
    /// back-ease expressible without a keyframe animation.
    static let openCurve: (Float, Float, Float, Float) = (0.34, 1.56, 0.64, 1)
    /// `easeOutCubic` -- no overshoot on the way back in, so a dismissal reads
    /// as settling rather than as a second gesture.
    static let closeCurve: (Float, Float, Float, Float) = (0.33, 1, 0.68, 1)

    struct Layout: Equatable {
        var card: CGRect
        var rail: CGRect
        /// True when the margin beside the card is too narrow for the rail to
        /// sit outside it, so the buttons float over the page instead.
        var railOverlapsCard: Bool
    }

    /// Resting position: 80 % of the width, inset top and bottom, centred.
    static func cardFrame(in bounds: CGRect) -> CGRect {
        let width = (bounds.width * widthFraction).rounded()
        let height = max(bounds.height - verticalInset * 2, 0)
        return CGRect(
            x: bounds.minX + ((bounds.width - width) / 2).rounded(),
            y: bounds.minY + verticalInset,
            width: width,
            height: height
        )
    }

    static func layout(in bounds: CGRect) -> Layout {
        let card = cardFrame(in: bounds)
        let margin = card.minX - bounds.minX
        let fitsOutside = margin >= railWidth
        let railX = fitsOutside ? card.minX - railWidth : card.minX
        let rail = CGRect(
            x: railX,
            y: card.maxY - railTopInset - railHeight,
            width: railWidth,
            height: railHeight
        )
        return Layout(card: card, rail: rail, railOverlapsCard: !fitsOutside)
    }

    /// Two buttons -- close and expand -- plus the padding around them. A
    /// split-view button is not offered, since Kylmora has no split view to
    /// give it.
    static var railHeight: CGFloat {
        railPadding * 2 + railButtonSide * 2 + railSpacing
    }

    /// Where the fly-out starts.
    ///
    /// A caller with no element to point at -- a bookmark, a command-bar result
    /// -- gets a zero-size rectangle at the centre, which is deliberate and is
    /// not the same as "no animation": the panel still scales up from a
    /// point, so the gesture reads the same however it was started.
    static func originFrame(for origin: CGRect?, in bounds: CGRect) -> CGRect {
        guard let origin, origin.width > 0 || origin.height > 0 else {
            return CGRect(x: bounds.midX, y: bounds.midY, width: 0, height: 0)
        }
        // A link rectangle from the page can be enormous (a block-level anchor)
        // or off-screen after a scroll; clamping keeps the animation an arc
        // rather than a jump from somewhere the user was not looking.
        return origin.intersects(bounds) ? origin : CGRect(x: bounds.midX, y: bounds.midY, width: 0, height: 0)
    }

    /// Honours the system setting rather than a preference of our own: a user
    /// who has asked the whole machine to stop moving has already answered.
    @MainActor
    static var prefersReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}
