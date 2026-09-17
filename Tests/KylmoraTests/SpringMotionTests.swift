import AppKit
import QuartzCore
import Testing
@testable import Kylmora

// The press spring is plain AppKit with no session behind it, so it is
// exercised with views and values rather than with a running browser. Nothing
// here asserts on how the motion *looks* -- that is not a thing a test can see
// -- only on the two things that can go wrong invisibly: the scale a control is
// squeezed to, and whether it is ever left squeezed.

@Suite("Press spring measurements")
@MainActor
struct PressScaleTests {

    @Test("A small control squeezes by the floor, not by the travel")
    func smallControlsUseTheFloor() {
        // The travel alone would take a 29-point button to 0.79.
        let button = CGSize(width: Style.Metrics.iconButtonSide, height: Style.Metrics.iconButtonSide)
        #expect(Style.Motion.pressScale(for: button) == Style.Motion.pressScaleFloor)
    }

    @Test("A wide row squeezes by the travel, not by the floor")
    func wideRowsUseTheTravel() {
        let row = CGSize(width: Style.Metrics.sidebarWidth, height: Style.Metrics.rowHeight)
        let scale = Style.Motion.pressScale(for: row)
        #expect(scale > Style.Motion.pressScaleFloor)
        // The long edge gives up exactly the stated travel.
        let lost = Style.Metrics.sidebarWidth * (1 - scale)
        #expect(abs(lost - Style.Motion.pressTravel) < 0.001)
    }

    @Test("Nothing is ever squeezed past the floor or grown by a press")
    func scaleStaysInRange() {
        for side in stride(from: CGFloat(1), through: 2000, by: 7) {
            let scale = Style.Motion.pressScale(for: CGSize(width: side, height: side))
            #expect(scale >= Style.Motion.pressScaleFloor)
            #expect(scale <= 1)
        }
    }

    @Test("A zero-sized control does not divide by its own width")
    func zeroSizeIsSafe() {
        let scale = Style.Motion.pressScale(for: .zero)
        #expect(scale == Style.Motion.pressScaleFloor)
        #expect(scale.isFinite)
    }

    @Test("A bigger control is squeezed proportionally less")
    func largerMeansGentler() {
        let small = Style.Motion.pressScale(for: CGSize(width: 100, height: 20))
        let large = Style.Motion.pressScale(for: CGSize(width: 400, height: 20))
        #expect(large > small)
    }
}

@Suite("Press spring state")
@MainActor
struct SpringPressTests {

    /// A view with a real size, because the squeeze is derived from one.
    private func host() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 32))
        view.wantsLayer = true
        return view
    }

    @Test("A press is held until it is released")
    func holdsUntilReleased() {
        let view = host()
        let press = SpringPress(view: view)
        #expect(!press.isPressed)
        press.down()
        #expect(press.isPressed)
        press.up()
        #expect(!press.isPressed)
    }

    @Test("A second press does not restart the squeeze, and a stray release does nothing")
    func edgesAreIdempotent() {
        let view = host()
        let press = SpringPress(view: view)
        press.up()
        #expect(!press.isPressed)
        press.down()
        press.down()
        #expect(press.isPressed)
        press.up()
        press.up()
        #expect(!press.isPressed)
    }

    @Test("A cancelled press is released without claiming a click happened")
    func cancelReleases() {
        let view = host()
        let press = SpringPress(view: view)
        press.down()
        press.cancel()
        #expect(!press.isPressed)
    }

    @Test("A held press really does scale the layer down")
    func pressScalesTheLayer() throws {
        // Pinned rather than skipped: a CI runner reports Reduce Motion as
        // on, and the squeeze is precisely what this test is for.
        Style.Motion.reduceMotionOverride = false
        defer { Style.Motion.reduceMotionOverride = nil }
        let view = host()
        let press = SpringPress(view: view)
        press.down()
        let scaled = try #require(view.layer).transform
        #expect(scaled.m11 < 1)
        #expect(abs(scaled.m11 - Style.Motion.pressScale(for: view.bounds.size)) < 0.001)
        // Squeezed equally on both axes: a press is a scale, not a stretch.
        #expect(abs(scaled.m11 - scaled.m22) < 0.0001)
    }

    @Test("A release puts the layer back exactly, not nearly")
    func releaseRestoresIdentity() throws {
        // Pinned rather than skipped: a CI runner reports Reduce Motion as
        // on, and the squeeze is precisely what this test is for.
        Style.Motion.reduceMotionOverride = false
        defer { Style.Motion.reduceMotionOverride = nil }
        let view = host()
        let press = SpringPress(view: view)
        press.down()
        press.up()
        let transform = try #require(view.layer).transform
        #expect(CATransform3DIsIdentity(transform))
    }

    @Test("A recycled cell is handed over unsqueezed, however it was left")
    func resetClearsAHeldPress() throws {
        let view = host()
        let press = SpringPress(view: view)
        press.down()
        press.reset()
        #expect(!press.isPressed)
        #expect(CATransform3DIsIdentity(try #require(view.layer).transform))
        #expect(view.layer?.animation(forKey: "kylmora.springPress") == nil)
    }

    @Test("Reset is safe on a press that never happened")
    func resetIsSafeWhenIdle() {
        let view = host()
        let press = SpringPress(view: view)
        press.reset()
        #expect(!press.isPressed)
    }

    @Test("The squeeze is centred, so a pressed control does not drift")
    func squeezeIsCentred() throws {
        // Pinned rather than skipped: a CI runner reports Reduce Motion as
        // on, and the squeeze is precisely what this test is for.
        Style.Motion.reduceMotionOverride = false
        defer { Style.Motion.reduceMotionOverride = nil }
        let view = host()
        let press = SpringPress(view: view)
        press.down()
        let transform = try #require(view.layer).transform
        // The centre of the bounds must map to itself: a transform that moved
        // it would read as the control sliding rather than being pressed.
        let centre = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let anchor = view.layer?.anchorPoint ?? CGPoint(x: 0.5, y: 0.5)
        let origin = CGPoint(
            x: anchor.x * view.bounds.width,
            y: anchor.y * view.bounds.height
        )
        // A layer's transform is applied about its anchor point.
        let dx = centre.x - origin.x
        let dy = centre.y - origin.y
        let mappedX = origin.x + transform.m11 * dx + transform.m41
        let mappedY = origin.y + transform.m22 * dy + transform.m42
        #expect(abs(mappedX - centre.x) < 0.001)
        #expect(abs(mappedY - centre.y) < 0.001)
    }
}

@Suite("Presence spring")
@MainActor
struct SpringPresenceTests {

    @Test("An arrival ends fully visible and at its own size")
    func arrivalSettlesAtRest() throws {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        SpringPresence.appear(view, rising: 12)
        #expect(CATransform3DIsIdentity(try #require(view.layer).transform))
    }

    @Test("A departure hands the view back so the caller can remove it")
    func departureCallsBack() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        view.wantsLayer = true
        // Under Reduce Motion this is called straight through rather than
        // after an animation, which is exactly the behaviour being checked:
        // the callback is the caller's only chance to tear the view down, so
        // it must run either way.
        var removed = false
        SpringPresence.disappear(view, falling: 12) { removed = true }
        if Style.Motion.isReduced { #expect(removed) }
    }
}

@Suite("Motion honours Reduce Motion")
@MainActor
struct ReduceMotionTests {

    @Test("Every spring duration is a duration, and departures are the quickest")
    func durationsAreOrdered() {
        #expect(Style.Motion.pressDown > 0)
        #expect(Style.Motion.pressSettle > Style.Motion.pressDown)
        #expect(Style.Motion.entrySettle > Style.Motion.pressSettle)
        // Leaving is quicker than arriving, and quicker than a press rebound.
        #expect(Style.Motion.exit < Style.Motion.pressSettle)
    }

    @Test("Arrivals bounce less than presses, and both actually bounce")
    func bouncesAreOrdered() {
        #expect(Style.Motion.pressBounce > 0)
        #expect(Style.Motion.entryBounce > 0)
        #expect(Style.Motion.entryBounce < Style.Motion.pressBounce)
        // Core Animation takes a bounce below 1; at 1 the spring never damps.
        #expect(Style.Motion.pressBounce < 1)
    }

    /// Asserted both ways round rather than skipped, because the machine the
    /// tests run on decides which way it is and neither answer is a reason to
    /// leave the rule unchecked: under Reduce Motion every spring collapses to
    /// nothing, and otherwise every spring is left exactly as written.
    @Test("Reduce Motion takes every spring duration to nothing, and leaves them alone otherwise")
    func reducedDurationsCollapse() {
        for base in [Style.Motion.pressDown, Style.Motion.pressSettle,
                     Style.Motion.entrySettle, Style.Motion.exit] {
            #expect(Style.Motion.duration(base) == (Style.Motion.isReduced ? 0 : base))
        }
    }
}
