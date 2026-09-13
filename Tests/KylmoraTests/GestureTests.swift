import Foundation
import Testing
@testable import Kylmora

// The gesture layer is three value types and one AppKit shim. Only the value
// types appear here: the shim's whole job is to turn `NSEvent` into them, and a
// test that synthesised events would be testing AppKit.

@Suite("Space switch navigation")
struct SwitchNavigationTests {

    @Test("Wrapping goes round in both directions")
    func wraps() {
        #expect(SwitchNavigation.destination(from: 2, offset: 1, count: 3) == 0)
        #expect(SwitchNavigation.destination(from: 0, offset: -1, count: 3) == 2)
    }

    @Test("A large offset wraps rather than running off the end")
    func wrapsRepeatedly() {
        #expect(SwitchNavigation.destination(from: 0, offset: 7, count: 3) == 1)
        #expect(SwitchNavigation.destination(from: 0, offset: -7, count: 3) == 2)
    }

    @Test("Clamping stops at the ends and reports that nothing moved")
    func clamps() {
        #expect(SwitchNavigation.destination(from: 2, offset: 1, count: 3, wraps: false) == nil)
        #expect(SwitchNavigation.destination(from: 0, offset: -1, count: 3, wraps: false) == nil)
        #expect(SwitchNavigation.destination(from: 0, offset: 1, count: 3, wraps: false) == 1)
    }

    @Test("A single space has nowhere to go, wrapping or not")
    func singleSpace() {
        #expect(SwitchNavigation.destination(from: 0, offset: 1, count: 1) == nil)
        #expect(SwitchNavigation.destination(from: 0, offset: -1, count: 1, wraps: false) == nil)
    }

    @Test("An index outside the list is refused rather than wrapped into range")
    func rejectsBadIndex() {
        #expect(SwitchNavigation.destination(from: 5, offset: 1, count: 3) == nil)
        #expect(SwitchNavigation.destination(from: -1, offset: 1, count: 3) == nil)
    }

    @Test("The strip takes the shorter way round")
    func shortestDistance() {
        // Five spaces, first to last: one step left, not four right.
        #expect(SwitchNavigation.shortestDistance(from: 0, to: 4, count: 5) == -1)
        #expect(SwitchNavigation.shortestDistance(from: 4, to: 0, count: 5) == 1)
        #expect(SwitchNavigation.shortestDistance(from: 0, to: 2, count: 5) == 2)
        #expect(SwitchNavigation.shortestDistance(from: 1, to: 1, count: 5) == 0)
    }
}

@Suite("Scroll to switch spaces")
struct SidebarScrollTrackerTests {

    private func event(
        x: CGFloat = 0,
        y: CGFloat = 0,
        precise: Bool = false,
        modifiers: Set<SidebarScrollModifier> = [],
        at time: TimeInterval
    ) -> SidebarScrollEvent {
        SidebarScrollEvent(
            deltaX: x,
            deltaY: y,
            hasPreciseDeltas: precise,
            modifiers: modifiers,
            timestamp: time
        )
    }

    @Test("A trackpad scroll is left alone so it can scroll the tab list")
    func ignoresPreciseDeltas() {
        var tracker = SidebarScrollTracker()
        #expect(tracker.offset(for: event(x: -40, precise: true, at: 1)) == nil)
    }

    @Test("A horizontal wheel scroll switches with no modifier held")
    func horizontalNeedsNoModifier() {
        var tracker = SidebarScrollTracker()
        #expect(tracker.offset(for: event(x: -3, at: 1)) == 1)
    }

    @Test("A vertical wheel scroll switches only with the modifier held")
    func verticalNeedsModifier() {
        var tracker = SidebarScrollTracker()
        #expect(tracker.offset(for: event(y: -3, at: 1)) == nil)
        #expect(tracker.offset(for: event(y: -3, modifiers: [.control], at: 2)) == 1)
    }

    @Test("A delta below the threshold is not a click")
    func threshold() {
        var tracker = SidebarScrollTracker()
        #expect(tracker.offset(for: event(x: -0.4, at: 1)) == nil)
    }

    @Test("One flick of the wheel switches once, not three times")
    func cooldown() {
        var tracker = SidebarScrollTracker()
        #expect(tracker.offset(for: event(x: -3, at: 1.00)) == 1)
        #expect(tracker.offset(for: event(x: -3, at: 1.05)) == nil)
        #expect(tracker.offset(for: event(x: -3, at: 1.10)) == nil)
        #expect(tracker.offset(for: event(x: -3, at: 1.25)) == 1)
    }

    @Test("Natural scrolling reverses the direction and nothing else")
    func inverted() {
        var configuration = SidebarScrollTracker.Configuration()
        configuration.invertsDirection = true
        var tracker = SidebarScrollTracker(configuration: configuration)
        #expect(tracker.offset(for: event(x: -3, at: 1)) == -1)
    }

    @Test("An event that was refused does not start the cooldown")
    func refusedEventDoesNotArmCooldown() {
        var tracker = SidebarScrollTracker()
        #expect(tracker.offset(for: event(x: -40, precise: true, at: 1.00)) == nil)
        #expect(tracker.offset(for: event(x: -3, at: 1.01)) == 1)
    }
}

@Suite("Recognising a swipe from raw scroll deltas")
struct ScrollSwipeRecogniserTests {
    private func armed() -> ScrollSwipeRecogniser {
        var recogniser = ScrollSwipeRecogniser()
        recogniser.begin(suppressed: false)
        return recogniser
    }

    @Test("A gesture that starts with no movement is still recognised")
    func zeroDeltaStartStillWorks() {
        // This is the whole reason the recogniser exists: the phase-began event
        // on a trackpad carries no delta, so a test made at that moment cannot
        // tell a swipe from a scroll.
        var recogniser = armed()
        #expect(recogniser.update(deltaX: 0, deltaY: 0) == nil)
        for _ in 0..<10 {
            _ = recogniser.update(deltaX: -8, deltaY: 0)
        }
        #expect(recogniser.hasCommitted)
    }

    @Test("Fingers moving left go forward, moving right go back")
    func directionFollowsTheFingers() {
        var left = armed()
        #expect(left.update(deltaX: -60, deltaY: 0) == 1)

        var right = armed()
        #expect(right.update(deltaX: 60, deltaY: 0) == -1)
    }

    @Test("A vertical scroll is left alone, however long it runs")
    func verticalScrollIsNotASwipe() {
        var recogniser = armed()
        for _ in 0..<50 {
            #expect(recogniser.update(deltaX: 0, deltaY: -12) == nil)
        }
        #expect(!recogniser.hasCommitted)
    }

    @Test("A drifting scroll needs to be clearly sideways, not merely sideways")
    func diagonalScrollIsNotASwipe() {
        var recogniser = armed()
        // Travels far enough horizontally, but the finger went further down.
        for _ in 0..<10 {
            #expect(recogniser.update(deltaX: -8, deltaY: -10) == nil)
        }
        #expect(!recogniser.hasCommitted)
    }

    @Test("A short flick is not far enough to switch")
    func shortFlickIsIgnored() {
        var recogniser = armed()
        #expect(recogniser.update(deltaX: -20, deltaY: 0) == nil)
        #expect(!recogniser.hasCommitted)
    }

    @Test("One long swipe switches once, not once every fifty points")
    func commitsOnlyOnce() {
        var recogniser = armed()
        var switches = 0
        for _ in 0..<40 {
            if recogniser.update(deltaX: -20, deltaY: 0) != nil { switches += 1 }
        }
        #expect(switches == 1)
    }

    @Test("A suppressed gesture is left to whoever claimed it")
    func suppressedGestureNeverFires() {
        var recogniser = ScrollSwipeRecogniser()
        recogniser.begin(suppressed: true)
        for _ in 0..<40 {
            #expect(recogniser.update(deltaX: -20, deltaY: 0) == nil)
        }
        #expect(!recogniser.hasCommitted)
    }

    @Test("Ending leaves nothing for the next gesture to inherit")
    func endingResets() {
        var recogniser = armed()
        _ = recogniser.update(deltaX: -40, deltaY: 0)
        recogniser.end()

        recogniser.begin(suppressed: false)
        // The 40 points from last time must not count towards this swipe.
        #expect(recogniser.update(deltaX: -20, deltaY: 0) == nil)
    }
}

@Suite("A swipe measured off a real trackpad")
struct RecordedSwipeTests {
    /// The `.changed` deltas from one deliberate left swipe across a 161-point
    /// sidebar, read out of `KYLMORA_GESTURE_LOG`. Kept verbatim: this is the
    /// gesture that used to do nothing, and the numbers are the evidence.
    private static let leftSwipe: [(CGFloat, CGFloat)] = [
        (-1, 0), (-9, -1), (-14, -1), (-18, -2), (-18, -2),
        (-14, -2), (-12, -2), (-10, -2), (-7, -1), (-7, -1)
    ]

    @Test("The recorded swipe switches, once")
    func recordedSwipeCommits() {
        var recogniser = ScrollSwipeRecogniser()
        recogniser.begin(suppressed: false)

        var offsets: [Int] = []
        for (deltaX, deltaY) in Self.leftSwipe {
            if let offset = recogniser.update(deltaX: deltaX, deltaY: deltaY) {
                offsets.append(offset)
            }
        }
        // Fingers left is forward, and 110 points of travel is one step, not
        // two.
        #expect(offsets == [1])
    }

    @Test("The same gesture reversed goes the other way")
    func recordedSwipeReversed() {
        var recogniser = ScrollSwipeRecogniser()
        recogniser.begin(suppressed: false)

        var offsets: [Int] = []
        for (deltaX, deltaY) in Self.leftSwipe {
            if let offset = recogniser.update(deltaX: -deltaX, deltaY: deltaY) {
                offsets.append(offset)
            }
        }
        #expect(offsets == [-1])
    }

    @Test("The momentum that follows a swipe does not switch again")
    func momentumDoesNotSwitchAgain() {
        var recogniser = ScrollSwipeRecogniser()
        recogniser.begin(suppressed: false)
        for (deltaX, deltaY) in Self.leftSwipe {
            _ = recogniser.update(deltaX: deltaX, deltaY: deltaY)
        }
        // The gesture ends and the trackpad keeps sending momentum deltas.
        recogniser.end()

        // Those arrive with no phase at all, so they never reach the
        // recogniser -- but if they did, a fresh accumulator must still need
        // the full travel before switching again.
        recogniser.begin(suppressed: false)
        #expect(recogniser.update(deltaX: -13, deltaY: 0) == nil)
    }
}

@Suite("The system swipe tracker")
struct SystemSwipeTrackerTests {
    @Test("A swipe is refused when there is nowhere to go")
    func refusedWithOneStop() {
        var tracker = SystemSwipeTracker()
        let started = tracker.begin(switchableCount: 1, activeIndex: 0, isSwitchInFlight: false, stripWidth: 160)
        #expect(!started)
        #expect(!tracker.isTracking)
    }

    @Test("A swipe is refused while a switch is still animating")
    func refusedMidSwitch() {
        var tracker = SystemSwipeTracker()
        let started = tracker.begin(switchableCount: 3, activeIndex: 0, isSwitchInFlight: true, stripWidth: 160)
        #expect(!started)
    }

    @Test("The measured swipe commits, where half a swipe would not have")
    func measuredSwipeCommits() {
        // 0.242 is what one deliberate swipe across a 161-point sidebar
        // actually reached, read out of KYLMORA_GESTURE_LOG. The old threshold of
        // 0.5 is unreachable there, which is why the gesture did nothing.
        var tracker = SystemSwipeTracker()
        let started = tracker.begin(switchableCount: 2, activeIndex: 0, isSwitchInFlight: false, stripWidth: 160)
        #expect(started)
        for amount in stride(from: -0.001, through: -0.242, by: -0.02) {
            tracker.update(amount: CGFloat(amount))
        }
        let outcome = tracker.end()
        #expect(outcome == 1)
    }

    @Test("Fingers right go back")
    func rightGoesBack() {
        var tracker = SystemSwipeTracker()
        _ = tracker.begin(switchableCount: 2, activeIndex: 0, isSwitchInFlight: false, stripWidth: 160)
        tracker.update(amount: 0.3)
        let outcome = tracker.end()
        #expect(outcome == -1)
    }

    @Test("A short flick does not commit")
    func shortFlickIsIgnored() {
        var tracker = SystemSwipeTracker()
        _ = tracker.begin(switchableCount: 2, activeIndex: 0, isSwitchInFlight: false, stripWidth: 160)
        tracker.update(amount: -0.05)
        let outcome = tracker.end()
        #expect(outcome == nil)
    }

    @Test("Drifting back after a committed pull still counts as committed")
    func peakWins() {
        var tracker = SystemSwipeTracker()
        _ = tracker.begin(switchableCount: 2, activeIndex: 0, isSwitchInFlight: false, stripWidth: 160)
        tracker.update(amount: -0.3)
        tracker.update(amount: -0.05)
        let outcome = tracker.end()
        #expect(outcome == 1)
    }

    @Test("A popup mid-swipe abandons it rather than committing on what it saw")
    func cancelAbandons() {
        var tracker = SystemSwipeTracker()
        _ = tracker.begin(switchableCount: 2, activeIndex: 0, isSwitchInFlight: false, stripWidth: 160)
        tracker.update(amount: -0.9)
        tracker.cancel()
        #expect(!tracker.isTracking)
        let outcome = tracker.end()
        #expect(outcome == nil)
    }

    @Test("Ending leaves nothing behind for the next swipe to inherit")
    func endingResets() {
        var tracker = SystemSwipeTracker()
        _ = tracker.begin(switchableCount: 2, activeIndex: 0, isSwitchInFlight: false, stripWidth: 160)
        tracker.update(amount: -0.9)
        _ = tracker.end()

        _ = tracker.begin(switchableCount: 2, activeIndex: 0, isSwitchInFlight: false, stripWidth: 160)
        #expect(tracker.peak == 0)
        let outcome = tracker.end()
        #expect(outcome == nil)
    }
}

@Suite("The content follows the fingers")
struct SwipeTravelTests {
    private func tracking() -> SystemSwipeTracker {
        var tracker = SystemSwipeTracker()
        _ = tracker.begin(switchableCount: 2, activeIndex: 0, isSwitchInFlight: false, stripWidth: 160)
        return tracker
    }

    @Test("A swipe with no width to travel across is refused")
    func zeroWidthIsRefused() {
        var tracker = SystemSwipeTracker()
        let started = tracker.begin(switchableCount: 2, activeIndex: 0, isSwitchInFlight: false, stripWidth: 0)
        #expect(!started)
    }

    @Test("The content moves the way the fingers do")
    func translationFollowsDirection() {
        var left = tracking()
        left.update(amount: -0.1)
        #expect(left.translation < 0)

        var right = tracking()
        right.update(amount: 0.1)
        #expect(right.translation > 0)
    }

    @Test("By the time the swipe commits the content has visibly moved")
    func committingSwipeMovesContent() {
        var tracker = tracking()
        tracker.update(amount: -tracker.configuration.completionThreshold)
        // A few points of travel would read as nothing happening. Half the
        // sidebar is what makes the commit feel earned.
        #expect(abs(tracker.translation) > 60)
    }

    @Test("Towards a neighbour the content goes with the fingers, one for one")
    func followsFingersTowardsNeighbour() {
        var tracker = tracking()
        tracker.update(amount: -0.1)
        let short = tracker.translation
        tracker.update(amount: -0.2)
        // Twice the gesture is twice the travel: no band while there is a
        // space to pull in. The strip does not lag the fingers.
        #expect(abs(tracker.translation - short * 2) < 0.001)
    }

    @Test("The content stops once the neighbour is fully in")
    func stopsAtOneWidth() {
        var tracker = tracking()
        tracker.update(amount: -0.9)
        #expect(tracker.translation == -160)
    }

    @Test("At an end of the row the band holds the content back")
    func rubberBandHoldsBackAtTheEnd() {
        // Stop 0 of 2: nothing before it, so a drag backwards pulls against
        // the band rather than into a neighbour.
        var tracker = tracking()
        tracker.update(amount: 0.25)
        let half = tracker.translation
        tracker.update(amount: 0.5)
        let full = tracker.translation
        #expect(half > 0)
        // Twice the gesture is less than twice the travel.
        #expect(full < half * 2)
    }

    @Test("The colour only moves towards a space that exists")
    func crossfadeOnlyTowardsNeighbour() {
        var towards = tracking()
        towards.update(amount: -0.1)
        #expect(towards.crossfade > 0)

        var end = tracking()
        end.update(amount: 0.1)
        #expect(end.crossfade == 0)
    }

    @Test("The colour is fully the neighbour's once the neighbour is fully in")
    func crossfadeSaturates() {
        var tracker = tracking()
        tracker.update(amount: -0.01)
        #expect(tracker.crossfade < 1)
        tracker.update(amount: -0.9)
        #expect(tracker.crossfade == 1)
    }

    @Test("Nothing is left parked off to one side after a swipe ends")
    func endingResetsTravel() {
        var tracker = tracking()
        tracker.update(amount: -0.4)
        _ = tracker.end()
        #expect(tracker.translation == 0)
        #expect(tracker.crossfade == 0)
    }
}

@Suite("The swipe stops at the ends of the row")
struct SwipeEndsTests {
    @Test("Neither swipe path wraps")
    func neitherPathWraps() {
        // The footer's dots are a row with two ends. A swipe that jumps from
        // the last dot back to the first contradicts what the dots show, and
        // that is what "the first and last one move the wrong way" was.
        #expect(!SystemSwipeTracker().configuration.wraps)
        #expect(!ScrollSwipeRecogniser().configuration.wraps)
    }

    @Test("Swiping past either end goes nowhere")
    func pastTheEndsGoesNowhere() {
        #expect(SwitchNavigation.destination(from: 0, offset: -1, count: 2, wraps: false) == nil)
        #expect(SwitchNavigation.destination(from: 1, offset: 1, count: 2, wraps: false) == nil)
    }

    @Test("Swiping within the row still moves one step")
    func withinTheRowStillMoves() {
        #expect(SwitchNavigation.destination(from: 0, offset: 1, count: 2, wraps: false) == 1)
        #expect(SwitchNavigation.destination(from: 1, offset: -1, count: 2, wraps: false) == 0)
    }
}

@Suite("A swipe cannot be claimed twice")
struct DoubleClaimTests {
    @Test("A second claim while one is tracking is refused")
    func secondClaimRefused() {
        var tracker = SystemSwipeTracker()
        let first = tracker.begin(switchableCount: 2, activeIndex: 0, isSwitchInFlight: false, stripWidth: 160)
        #expect(first)

        // Two system trackers sharing one of these is how the sidebar ended up
        // parked off the screen: whichever ended first turned tracking off, and
        // the other's end was then ignored, so nothing ever put it back.
        let second = tracker.begin(switchableCount: 2, activeIndex: 0, isSwitchInFlight: false, stripWidth: 160)
        #expect(!second)
    }

    @Test("Once the first one ends, the next swipe is claimed normally")
    func claimableAgainAfterEnding() {
        var tracker = SystemSwipeTracker()
        _ = tracker.begin(switchableCount: 2, activeIndex: 0, isSwitchInFlight: false, stripWidth: 160)
        _ = tracker.end()

        let again = tracker.begin(switchableCount: 2, activeIndex: 0, isSwitchInFlight: false, stripWidth: 160)
        #expect(again)
    }

    @Test("A cancelled swipe also frees the tracker")
    func claimableAgainAfterCancel() {
        var tracker = SystemSwipeTracker()
        _ = tracker.begin(switchableCount: 2, activeIndex: 0, isSwitchInFlight: false, stripWidth: 160)
        tracker.cancel()

        let again = tracker.begin(switchableCount: 2, activeIndex: 0, isSwitchInFlight: false, stripWidth: 160)
        #expect(again)
    }
}

@Suite("The release finishes what the drag started")
struct ReleaseDurationTests {
    @Test("A switch from rest takes the whole duration")
    @MainActor func fromRest() {
        let duration = SidebarViewController.releaseDuration(remaining: 160, width: 160)
        #expect(duration == SidebarViewController.switchDuration)
    }

    @Test("A release from part-way takes only that part")
    @MainActor func fromPartWay() {
        let duration = SidebarViewController.releaseDuration(remaining: 80, width: 160)
        #expect(abs(duration - SidebarViewController.switchDuration / 2) < 0.001)
    }

    @Test("A release from nearly there still moves rather than cuts")
    @MainActor func fromNearlyThere() {
        let duration = SidebarViewController.releaseDuration(remaining: 2, width: 160)
        #expect(duration == SidebarViewController.minimumSwitchDuration)
    }
}
