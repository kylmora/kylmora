import AppKit

/// Sizes for the Little Arc window.
///
/// A little window, not a small browser window: wide enough for a two-column
/// page and a comfortable measure of text, and deliberately smaller than the
/// main window so it reads as somewhere temporary rather than a second place
/// to live.
enum LittleArcMetrics {
    static let size = CGSize(width: 720, height: 520)
    /// The floor a resize may reach. Below this sites start serving their
    /// phone layout and the window stops being worth having.
    static let minimumSize = CGSize(width: 360, height: 260)
    /// Kept clear on every side, so the window never sits flush against a
    /// screen edge and never under the menu bar or the Dock.
    static let screenMargin: CGFloat = 24
    /// How far above centre the window sits, as a fraction of its own height.
    ///
    /// Exactly centred reads as slightly low -- the eye lands near the top of
    /// a window first -- and the point of a Little Arc is to appear where the
    /// look already is.
    static let verticalBias: CGFloat = 0.06
}

/// Where a Little Arc window opens.
///
/// Pure, so the placement rules can be argued in a test rather than by
/// resizing every screen the app might run on.
enum LittleArcPlacement {
    /// Centred on the screen the link was clicked on, nudged up, and clamped
    /// so the whole window is on that screen with its margin intact.
    static func frame(in visibleFrame: NSRect) -> NSRect {
        let margin = LittleArcMetrics.screenMargin
        // Never larger than the screen it has to fit on: a small display, a
        // huge Dock or a full-screen window on one half leaves less room than
        // the default size, and overflowing would put the window's own
        // controls off the edge where they cannot be reached.
        let width = min(LittleArcMetrics.size.width, max(1, visibleFrame.width - margin * 2))
        let height = min(LittleArcMetrics.size.height, max(1, visibleFrame.height - margin * 2))

        let centreX = visibleFrame.midX - width / 2
        let centreY = visibleFrame.midY - height / 2 + height * LittleArcMetrics.verticalBias

        // Clamped after rounding, and against the *visible* frame, because a
        // secondary display to the left of the main one has a negative origin
        // and a margin measured from zero would shove the window onto the
        // wrong screen entirely.
        let leastX = visibleFrame.minX + margin
        let leastY = visibleFrame.minY + margin
        let mostX = max(leastX, visibleFrame.maxX - width - margin)
        let mostY = max(leastY, visibleFrame.maxY - height - margin)

        return NSRect(
            x: min(max(centreX.rounded(), leastX), mostX),
            y: min(max(centreY.rounded(), leastY), mostY),
            width: width.rounded(.down),
            height: height.rounded(.down)
        )
    }
}

/// Which surface a link from another app lands on.
enum LittleArcRouting {
    enum Destination: Equatable, Sendable {
        /// A tab in a space, as every browser does.
        case tab
        /// A small window where the link was clicked.
        case littleArc
        /// A look at the page over the one being read.
        case glance
    }

    /// Shift is the escape hatch, held as the link arrives: it asks for a tab
    /// whatever the preference says. Every path that opens somebody else's link
    /// honours it, so the key means the same thing everywhere.
    static func destination(for presentation: ExternalLinkPresentation, shiftHeld: Bool) -> Destination {
        guard !shiftHeld else { return .tab }

        switch presentation {
        case .tab: return .tab
        case .littleArc: return .littleArc
        case .glance: return .glance
        }
    }
}
