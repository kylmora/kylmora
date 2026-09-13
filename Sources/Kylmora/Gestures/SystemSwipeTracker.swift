import Foundation

/// The decision half of `NSEvent.trackSwipeEvent`: how far the gesture got, and
/// whether that was far enough.
///
/// **Why the system tracker is not optional.** With "Swipe between pages" on --
/// the default -- macOS reserves a horizontal two-finger gesture. The
/// application is handed the event whose phase is `.began` and then nothing at
/// all until `.ended`; the movement in between is delivered only through
/// `trackSwipeEvent`'s callback. Measured, not assumed: with the tracker
/// claimed the log shows a stream of `.changed` events, and with it removed the
/// same gesture produces `phase=32`, `phase=1`, and silence.
///
/// **Why the threshold is not 0.5.** `amount` is normalised against a full-page
/// swipe, which is scaled to the window rather than to the view the gesture
/// happens in. A deliberate swipe right across a 161-point sidebar measured
/// 0.242. At the conventional half-a-swipe threshold the gesture claimed every
/// swipe and committed none of them, which is exactly what "the swipe does
/// nothing" looked like.
struct SystemSwipeTracker: Sendable {

    struct Configuration: Sendable, Equatable {
        /// Fraction of a full-page swipe that commits.
        ///
        /// 0.12 is about 55 points of travel in a sidebar, which is the same
        /// distance `ScrollSwipeRecogniser` asks for. The two paths should not
        /// need different amounts of effort from the user.
        var completionThreshold: CGFloat = 0.12
        /// Where the rubber band's force runs out, as a multiple of the strip's
        /// width. Only an end of the row is banded: the content is pulled
        /// against nothing, and follows the fingers with a force that falls
        /// off as it travels, so it cannot be dragged arbitrarily far.
        var rubberBandExtent: CGFloat = 2.5
        /// How much sidebar the content covers per unit of gesture amount.
        ///
        /// The amount is normalised against a full-page swipe, which is scaled
        /// to the window and is several times the sidebar's width, so using it
        /// directly moves the content by a few points and looks broken. Four
        /// makes a swipe right across the sidebar move the content one sidebar,
        /// which is the fingers and the content travelling together.
        var travelScale: CGFloat = 4
        var invertsDirection = false
        /// Off. The footer's dots are a row with two ends, and a swipe that
        /// jumps from the last of them back to the first contradicts what the
        /// dots are showing. Swiping past an end springs back instead, which is
        /// how the end of a row is meant to feel.
        var wraps = false

        init() {}
    }

    var configuration: Configuration

    private(set) var isTracking = false
    /// The furthest the gesture got, in either direction.
    ///
    /// The peak matters, not the final amount: letting go after pulling most of
    /// the way across and drifting back a little is a committed swipe, and
    /// judging it on the last sample punishes the release.
    private(set) var peak: CGFloat = 0
    /// Live offset of the sidebar's content, in points. Negative follows a
    /// swipe towards the leading edge.
    private(set) var translation: CGFloat = 0
    private var stripWidth: CGFloat = 0
    private var canGoForward = false
    private var canGoBackward = false

    /// How far along the strip is towards the neighbouring stop, 0 to 1.
    ///
    /// Against an end of the row there is no neighbour and this stays at 0:
    /// there is nothing for the colour to fade towards.
    var crossfade: CGFloat {
        guard stripWidth > 0, hasNeighbour(forTranslation: translation) else { return 0 }
        return min(1, abs(translation) / stripWidth)
    }

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Claims the gesture, or refuses it.
    ///
    /// - Parameters:
    ///   - switchableCount: fewer than two stops and there is nowhere to go.
    ///   - activeIndex: which stop the strip is on, so the tracker knows which
    ///     way has a neighbour to pull into view and which way is an end.
    ///   - isSwitchInFlight: a switch is already animating. Starting a second
    ///     swipe on top of it leaves two animations fighting, and the loser
    ///     snaps.
    mutating func begin(
        switchableCount: Int,
        activeIndex: Int,
        isSwitchInFlight: Bool,
        stripWidth: CGFloat
    ) -> Bool {
        // Already tracking means a second `trackSwipeEvent` would be claimed on
        // top of the first. They share this one tracker, so whichever ends
        // first turns tracking off and the other's end is then ignored -- and
        // the sidebar is left parked wherever that abandoned drag had pushed it.
        guard !isTracking, !isSwitchInFlight, switchableCount > 1, stripWidth > 0 else { return false }
        isTracking = true
        peak = 0
        translation = 0
        self.stripWidth = stripWidth
        canGoForward = SwitchNavigation.destination(
            from: activeIndex, offset: 1, count: switchableCount, wraps: configuration.wraps
        ) != nil
        canGoBackward = SwitchNavigation.destination(
            from: activeIndex, offset: -1, count: switchableCount, wraps: configuration.wraps
        ) != nil
        return true
    }

    /// Feeds the cumulative amount as AppKit reports it: 0 at the start, ±1 at
    /// a full swipe.
    mutating func update(amount: CGFloat) {
        guard isTracking else { return }
        if abs(amount) > abs(peak) { peak = amount }

        // The amount is normalised to a full-page swipe, which is far wider
        // than the sidebar, so it is scaled back up against the strip --
        // otherwise the content barely moves at all.
        let raw = amount * stripWidth * configuration.travelScale

        if hasNeighbour(forTranslation: raw) {
            // The strip goes with the fingers, one for one, and stops when
            // the neighbour is fully in: there is nothing past it to show.
            translation = max(-stripWidth, min(stripWidth, raw))
        } else {
            // An end of the row. The content still answers the fingers, so
            // the swipe is seen, but it is pulling against a band.
            let extent = stripWidth * configuration.rubberBandExtent
            let force = extent > 0 ? max(0, 1 - abs(raw) / extent) : 0
            translation = raw * (0.35 + 0.65 * force)
        }
    }

    /// Ends the gesture and says which way to move, or nil for a swipe that did
    /// not travel far enough.
    mutating func end() -> Int? {
        defer { cancel() }
        guard isTracking, abs(peak) >= configuration.completionThreshold else { return nil }
        // A negative amount is the fingers moving left, which is forward.
        let offset = peak < 0 ? 1 : -1
        return configuration.invertsDirection ? -offset : offset
    }

    /// Abandons the gesture without switching.
    ///
    /// A context menu or any other popup opening mid-swipe lands here: the
    /// pointer is captured by something else, no more updates are coming, and
    /// committing on the last amount seen would switch because the user
    /// right-clicked.
    mutating func cancel() {
        isTracking = false
        peak = 0
        translation = 0
        stripWidth = 0
        canGoForward = false
        canGoBackward = false
    }

    /// Whether a drag in this direction has a stop to pull into view. Content
    /// moving towards the leading edge is the forward direction.
    private func hasNeighbour(forTranslation translation: CGFloat) -> Bool {
        if translation < 0 { return configuration.invertsDirection ? canGoBackward : canGoForward }
        if translation > 0 { return configuration.invertsDirection ? canGoForward : canGoBackward }
        return false
    }
}
