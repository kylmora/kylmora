import Foundation

/// The modifier a vertical scroll must be held with to switch spaces.
///
/// Its own enumeration rather than `NSEvent.ModifierFlags` so the tracker below
/// stays free of AppKit and can be driven from a test with literals.
enum SidebarScrollModifier: Sendable, Equatable, CaseIterable {
    case control
    case option
    case shift
    case command
}

/// One scroll event, reduced to what the decision needs.
struct SidebarScrollEvent: Sendable, Equatable {
    /// Positive is a scroll towards the trailing edge.
    let deltaX: CGFloat
    let deltaY: CGFloat
    /// True for a trackpad or a Magic Mouse, false for a notched wheel.
    let hasPreciseDeltas: Bool
    let modifiers: Set<SidebarScrollModifier>
    /// `NSEvent.timestamp`: seconds since boot.
    let timestamp: TimeInterval

    init(
        deltaX: CGFloat = 0,
        deltaY: CGFloat = 0,
        hasPreciseDeltas: Bool = false,
        modifiers: Set<SidebarScrollModifier> = [],
        timestamp: TimeInterval
    ) {
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.hasPreciseDeltas = hasPreciseDeltas
        self.modifiers = modifiers
        self.timestamp = timestamp
    }
}

/// Scroll-wheel space switching.
///
/// Deliberately not a gesture recogniser. A scroll wheel produces discrete
/// clicks and the question is only "did this click count, and was the last one
/// long enough ago" -- a recogniser would add a state machine on top of a state
/// machine, and would still have to do the cooldown itself.
///
/// The rules it enforces, all of them load-bearing:
///
/// - **Precise deltas are ignored.** A two-finger trackpad scroll over the
///   sidebar has to scroll the tab list; if it switched spaces the list would
///   be unscrollable. This is a line-mode-only rule under its AppKit name.
/// - **A vertical scroll needs a modifier, a horizontal one does not.** A wheel
///   only has a vertical axis, so an unmodified wheel scroll over the sidebar
///   keeps meaning "scroll the sidebar".
/// - **200 ms between switches.** One flick of a wheel delivers several events,
///   and without the cooldown a single gesture jumps three spaces.
struct SidebarScrollTracker: Sendable {

    struct Configuration: Sendable, Equatable {
        /// Shortest gap between two switches.
        var cooldown: TimeInterval = 0.2
        /// Smallest delta that counts as a deliberate click.
        var threshold: CGFloat = 1
        /// What a vertical scroll must be held with.
        var verticalModifier: SidebarScrollModifier = .control
        /// Flips the direction, for people whose scrolling is already flipped.
        var invertsDirection = false
        /// Spaces wrap at the ends.
        var wraps = true

        init() {}
    }

    var configuration: Configuration
    private var lastSwitch: TimeInterval = -.greatestFiniteMagnitude

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// The offset this event should move the active space by, or nil if it
    /// should be left to whatever else wants it.
    ///
    /// Returning nil rather than 0 is the difference between "this event was
    /// not for me" and "this event was for me and meant nothing": the view
    /// passes the first on to the scroll view underneath and swallows the
    /// second.
    mutating func offset(for event: SidebarScrollEvent) -> Int? {
        guard !event.hasPreciseDeltas else { return nil }

        let delta: CGFloat
        if abs(event.deltaX) >= configuration.threshold {
            delta = event.deltaX
        } else if abs(event.deltaY) >= configuration.threshold,
                  event.modifiers.contains(configuration.verticalModifier) {
            delta = event.deltaY
        } else {
            return nil
        }

        guard event.timestamp - lastSwitch >= configuration.cooldown else { return nil }
        lastSwitch = event.timestamp

        // A scroll towards the trailing edge moves to the next space, the same
        // way a swipe in that direction does.
        let forward = delta < 0
        let offset = forward ? 1 : -1
        return configuration.invertsDirection ? -offset : offset
    }

    /// Forgets the cooldown, so the next event is honoured whenever it arrives.
    ///
    /// Used when the window loses key: the timestamps are monotonic across the
    /// whole session, and a user who comes back to the window twenty minutes
    /// later should not be waiting on a cooldown from before they left. (It is
    /// already expired in that case -- this exists for the opposite one, where
    /// a switch by some other means should not block the next scroll.)
    mutating func reset() {
        lastSwitch = -.greatestFiniteMagnitude
    }
}
