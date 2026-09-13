import AppKit

/// What the gesture controller needs from the browser, and what it tells it.
@MainActor
protocol SidebarSwipeDelegate: AnyObject {
    var switchableCount: Int { get }
    var activeSwitchableIndex: Int { get }
    /// A switch is already animating.
    var isSwitchInFlight: Bool { get }
    /// The area a gesture has to start inside, in window coordinates. Nil
    /// while there is nowhere to gesture.
    var swipeRegion: NSRect? { get }

    /// Live feedback during a swipe: how far the strip has been dragged and how
    /// far the incoming space's background has faded in.
    ///
    /// Optional in practice -- a delegate that does nothing here gets a swipe
    /// that commits without following the fingers, which is worse but not
    /// broken.
    func swipeDidDrag(by translation: CGFloat, crossfade: CGFloat)
    /// The swipe was abandoned. Put the strip back.
    func swipeDidCancel()
    /// Switch by this many spaces.
    func swipe(switchBy offset: Int, wraps: Bool)
}

/// Swipe and scroll to switch spaces.
///
/// **Why a local event monitor and not a gesture recogniser.**
///
/// `NSPanGestureRecognizer` attached to the sidebar would fight the table view
/// and WebKit for the same events, and would still have to decide for itself
/// what counts as far enough. The monitor sees the raw scroll stream before
/// anything consumes it, which is what lets a horizontal swipe be told apart
/// from a vertical scroll without taking the vertical one away.
///
/// `NSEvent.trackSwipeEvent` is claimed on the gesture's first event; the
/// reason it has to be is on `SystemSwipeTracker`.
///
/// The monitor is **local**: it sees only this application's events and needs
/// no entitlement. A global monitor would need Accessibility permission, which
/// this design avoids requiring.
///
/// The scroll half deliberately does not go through `trackSwipeEvent` at all: a
/// notched wheel produces no gesture phases, so there is nothing to track.
@MainActor
final class SidebarSwipeController {

    weak var delegate: (any SidebarSwipeDelegate)?

    private var scroll: SidebarScrollTracker
    private var swipe: SystemSwipeTracker
    /// The fallback for when the system tracker cannot be claimed, which is
    /// when the user has turned "Swipe between pages" off. The movement then
    /// arrives as ordinary scroll events and this reads them.
    private var recogniser: ScrollSwipeRecogniser
    private var monitor: Any?

    init(
        scroll: SidebarScrollTracker = SidebarScrollTracker(),
        swipe: SystemSwipeTracker = SystemSwipeTracker(),
        recogniser: ScrollSwipeRecogniser = ScrollSwipeRecogniser()
    ) {
        self.scroll = scroll
        self.swipe = swipe
        self.recogniser = recogniser
    }

    /// Starts watching for gestures. Idempotent.
    func install() {
        guard monitor == nil else { return }
        // The event is deliberately not carried out of `assumeIsolated`:
        // `NSEvent` is not `Sendable`, and the isolation check is generic over
        // a `Sendable` result. A `Bool` crosses and the event stays put.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return handled ? nil : event
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        cancelSwipe()
    }

    /// A popup opened, or the window stopped being key.
    ///
    /// A swipe is aborted the moment any popup appears, and rightly so: the
    /// pointer has been taken away, no further updates will arrive, and
    /// committing on the last amount seen switches spaces because the user
    /// opened a context menu.
    func cancelSwipe() {
        guard swipe.isTracking else { return }
        swipe.cancel()
        recogniser.end()
        delegate?.swipeDidCancel()
    }

    /// Set `KYLMORA_GESTURE_LOG=1` to have every scroll event over the sidebar and
    /// every decision printed. A swipe cannot be reproduced from a script, so
    /// when one does not fire the only way to find out which guard refused it
    /// is to have the app say so.
    private static let isLogging = ProcessInfo.processInfo.environment["KYLMORA_GESTURE_LOG"] == "1"

    private static func log(_ message: @autoclosure () -> String) {
        guard isLogging else { return }
        NSLog("kylmora.gesture: %@", message())
    }

    /// Handled here, or left for whoever else wants it.
    private func handle(_ event: NSEvent) -> Bool {
        guard let delegate, let region = delegate.swipeRegion, event.window != nil else {
            Self.log("no delegate, no window, or no sidebar region")
            return false
        }
        guard region.contains(event.locationInWindow) else {
            Self.log("outside the sidebar: \(event.locationInWindow) not in \(region)")
            return false
        }
        Self.log("phase=\(event.phase.rawValue) dx=\(event.scrollingDeltaX) dy=\(event.scrollingDeltaY) precise=\(event.hasPreciseScrollingDeltas) stops=\(delegate.switchableCount) swipeTracking=\(NSEvent.isSwipeTrackingFromScrollEventsEnabled)")

        if handleGesturePhase(event, delegate: delegate) { return true }
        return handleScroll(event, delegate: delegate)
    }

    // MARK: - Scroll

    private func handleScroll(_ event: NSEvent, delegate: any SidebarSwipeDelegate) -> Bool {
        let reduced = SidebarScrollEvent(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            hasPreciseDeltas: event.hasPreciseScrollingDeltas,
            modifiers: Self.modifiers(from: event.modifierFlags),
            timestamp: event.timestamp
        )
        guard let offset = scroll.offset(for: reduced) else { return false }
        delegate.swipe(switchBy: offset, wraps: scroll.configuration.wraps)
        return true
    }

    private static func modifiers(from flags: NSEvent.ModifierFlags) -> Set<SidebarScrollModifier> {
        var result: Set<SidebarScrollModifier> = []
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.command) { result.insert(.command) }
        return result
    }

    // MARK: - Swipe

    /// The trackpad path.
    ///
    /// The system tracker is claimed on `.began`, because once "Swipe between
    /// pages" is on that is the only way the movement reaches the application
    /// at all. The recogniser below it is for the setting being off, when the
    /// movement arrives here as ordinary `.changed` events instead.
    private func handleGesturePhase(
        _ event: NSEvent,
        delegate: any SidebarSwipeDelegate
    ) -> Bool {
        guard event.hasPreciseScrollingDeltas else { return false }

        switch event.phase {
        case .began:
            let claimed = claimSystemTracker(event, delegate: delegate)
            // The fallback only runs for a gesture the system tracker did not
            // take, or both would fire and one flick would move two steps.
            recogniser.begin(suppressed: claimed)
            // The began event carries no movement worth acting on, so it is
            // handed back either way.
            return false
        case .changed:
            guard delegate.switchableCount > 1, !delegate.isSwitchInFlight else {
                Self.log("nowhere to swipe to: \(delegate.switchableCount) stop(s)")
                return false
            }
            guard let offset = recogniser.update(
                deltaX: event.scrollingDeltaX,
                deltaY: event.scrollingDeltaY
            ) else { return false }
            Self.log("committing a swipe of \(offset)")
            delegate.swipe(switchBy: offset, wraps: recogniser.configuration.wraps)
            return true
        case .ended, .cancelled:
            recogniser.end()
            return false
        default:
            return false
        }
    }


    // MARK: - The system tracker

    /// Claims `trackSwipeEvent` for this gesture.
    ///
    /// The horizontal test has to be made on this one event, and a trackpad's
    /// `.began` carries barely any movement -- one to three points is typical.
    /// So the test is "not vertical" rather than "clearly horizontal": a real
    /// vertical scroll arrives with a dy of ten or more and no dx at all, which
    /// this still refuses, and refusing is safe because an unclaimed gesture
    /// falls through to the tab list exactly as before.
    private func claimSystemTracker(
        _ event: NSEvent,
        delegate: any SidebarSwipeDelegate
    ) -> Bool {
        guard NSEvent.isSwipeTrackingFromScrollEventsEnabled,
              abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY),
              swipe.begin(
                  switchableCount: delegate.switchableCount,
                  activeIndex: delegate.activeSwitchableIndex,
                  isSwitchInFlight: delegate.isSwitchInFlight,
                  stripWidth: delegate.swipeRegion?.width ?? 0
              )
        else {
            Self.log("system tracker not claimed")
            return false
        }
        Self.log("system tracker claimed")

        event.trackSwipeEvent(options: [], dampenAmountThresholdMin: -1, max: 1) { amount, phase, _, stop in
            MainActor.assumeIsolated { [weak self] in
                guard let self else {
                    stop.pointee = true
                    return
                }
                self.swipeDidUpdate(amount: amount, phase: phase, stop: stop)
            }
        }
        return true
    }

    private func swipeDidUpdate(
        amount: CGFloat,
        phase: NSEvent.Phase,
        stop: UnsafeMutablePointer<ObjCBool>
    ) {
        guard swipe.isTracking else {
            stop.pointee = true
            return
        }
        switch phase {
        case .changed:
            swipe.update(amount: amount)
            delegate?.swipeDidDrag(by: swipe.translation, crossfade: swipe.crossfade)
        case .ended:
            // Acted on at `ended` rather than at the end of the system's own
            // settling animation: the switch has to start while the gesture is
            // still settling, or it lands a visible beat after the fingers lift.
            swipe.update(amount: amount)
            let peak = swipe.peak
            if let offset = swipe.end() {
                Self.log("swipe committing \(offset), peak \(peak)")
                delegate?.swipe(switchBy: offset, wraps: swipe.configuration.wraps)
            } else {
                Self.log("swipe too short, peak \(peak)")
                delegate?.swipeDidCancel()
            }
        case .cancelled:
            swipe.cancel()
            delegate?.swipeDidCancel()
        default:
            break
        }
    }
}
