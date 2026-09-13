import Foundation

/// A two-finger horizontal swipe, recognised from the raw scroll deltas.
///
/// **Why this exists alongside `trackSwipeEvent`.** The system tracker has to be
/// claimed on the event whose phase is `.began`, and the decision to claim it
/// can only be made from that event's deltas -- otherwise a vertical scroll in
/// the tab list gets swallowed. But a trackpad's `.began` event frequently
/// carries a delta of zero on both axes: the gesture has started and nothing
/// has moved yet. The horizontal test then fails, the tracker is never claimed,
/// and the swipe does nothing at all.
///
/// This recogniser has no such deadline. It watches the whole gesture, adds the
/// deltas up, and commits once the movement is unambiguously horizontal and far
/// enough. It gives up the elegance of the system tracker -- no rubber-banding,
/// no following the fingers -- for the property that matters more: it fires.
///
/// It never swallows a scroll it has not committed to, so scrolling the tab
/// list is untouched. And it commits at most once per gesture, so a long swipe
/// moves one step rather than skidding through every profile.
struct ScrollSwipeRecogniser: Sendable {

    struct Configuration: Sendable, Equatable {
        /// How far the fingers must travel horizontally, in points, before the
        /// gesture counts. Below this a diagonal flick while scrolling the list
        /// would switch profiles.
        var commitDistance: CGFloat = 50
        /// How much more horizontal than vertical the travel must be. A swipe
        /// that is only slightly sideways belongs to the list.
        var dominance: CGFloat = 1.5
        /// Natural scrolling is the system's business, not ours: the deltas
        /// already arrive flipped, so this stays off unless a user wants the
        /// switch to run against their scroll direction.
        var invertsDirection = false
        /// Off, for the same reason as the system tracker: see its
        /// configuration.
        var wraps = false

        init() {}
    }

    var configuration: Configuration

    private var accumulatedX: CGFloat = 0
    private var accumulatedY: CGFloat = 0
    /// Set once the gesture has produced a switch, so the rest of the same
    /// swipe is ignored rather than switching again every few points.
    private(set) var hasCommitted = false
    /// Another mechanism claimed this gesture. `trackSwipeEvent` and this
    /// recogniser both firing would move two steps for one flick.
    private var isSuppressed = false

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// A new gesture started.
    mutating func begin(suppressed: Bool) {
        accumulatedX = 0
        accumulatedY = 0
        hasCommitted = false
        isSuppressed = suppressed
    }

    /// Feeds one `.changed` event. Returns the switch to make, once, or nil.
    mutating func update(deltaX: CGFloat, deltaY: CGFloat) -> Int? {
        guard !isSuppressed, !hasCommitted else { return nil }
        accumulatedX += deltaX
        accumulatedY += deltaY

        guard abs(accumulatedX) >= configuration.commitDistance,
              abs(accumulatedX) >= abs(accumulatedY) * configuration.dominance
        else { return nil }

        hasCommitted = true
        // Fingers moving left gives a negative delta and means "forward", the
        // same direction the system tracker reports for the same gesture.
        let offset = accumulatedX < 0 ? 1 : -1
        return configuration.invertsDirection ? -offset : offset
    }

    /// The gesture ended or was cancelled. Nothing carries into the next one.
    mutating func end() {
        accumulatedX = 0
        accumulatedY = 0
        hasCommitted = false
        isSuppressed = false
    }
}
