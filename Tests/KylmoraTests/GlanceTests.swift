import AppKit
import Foundation
import Testing
@testable import Kylmora

@Suite("Glance state machine")
struct GlanceMachineTests {
    private func request(_ address: String = "https://example.com/article") -> GlanceRequest {
        GlanceRequest(url: URL(string: address)!, origin: CGRect(x: 10, y: 10, width: 80, height: 20),
                      source: .link)
    }

    /// Walks a machine to the settled open state, which is the precondition for
    /// most of the rules below.
    private func opened() -> GlanceMachine {
        var machine = GlanceMachine()
        _ = machine.open(request())
        _ = machine.openingFinished()
        return machine
    }

    @Test("Opening loads the page and starts the fly-out")
    func openEmitsBothEffects() {
        var machine = GlanceMachine()
        let effects = machine.open(request())
        #expect(effects == [.loadPage(request()), .animateOpen(request())])
        #expect(machine.phase == .opening)
        #expect(machine.isOpen)
    }

    @Test("Glances do not nest: a second open while one is up does nothing")
    func noNesting() {
        var machine = opened()
        let effects = machine.open(request("https://example.com/other"))
        #expect(effects.isEmpty)
        #expect(machine.request?.url.path() == "/article")
    }

    @Test("A dismissal is refused while an animation owns the overlay")
    func dismissalRefusedMidAnimation() {
        var machine = GlanceMachine()
        _ = machine.open(request())
        #expect(machine.dismiss(.closeButton).isEmpty)
        #expect(machine.phase == .opening)
    }

    @Test("A tab closing is never refused, animation or not")
    func forcedDismissalIsNeverRefused() {
        for phase in [GlancePhase.opening, .open] {
            var machine = GlanceMachine()
            _ = machine.open(request())
            if phase == .open { _ = machine.openingFinished() }
            #expect(machine.dismiss(.ownerTabClosed) == [.disarmConfirmation, .teardown])
            #expect(machine.phase == .closed)
        }
    }

    @Test("Escape with something focused arms the guard instead of closing")
    func escapeGuardArms() {
        var machine = opened()
        let effects = machine.dismiss(.escapeKey(contentHasFocus: true))
        #expect(effects == [.armConfirmation(GlanceMachine.confirmationWindow)])
        #expect(machine.phase == .awaitingConfirmation)
    }

    @Test("A second Escape inside the window closes")
    func secondEscapeCloses() {
        var machine = opened()
        _ = machine.dismiss(.escapeKey(contentHasFocus: true))
        let effects = machine.dismiss(.escapeKey(contentHasFocus: true))
        #expect(effects == [.disarmConfirmation, .animateClose(animated: true)])
        #expect(machine.phase == .closing)
    }

    @Test("The close button also satisfies an armed guard")
    func closeButtonSatisfiesGuard() {
        var machine = opened()
        _ = machine.dismiss(.escapeKey(contentHasFocus: true))
        #expect(machine.dismiss(.closeButton) == [.disarmConfirmation, .animateClose(animated: true)])
    }

    @Test("Escape with nothing focused closes on the first press")
    func escapeWithoutFocusClosesImmediately() {
        var machine = opened()
        #expect(machine.dismiss(.escapeKey(contentHasFocus: false))
                == [.disarmConfirmation, .animateClose(animated: true)])
    }

    @Test("A lapsed confirmation goes back to plain open, and can arm again")
    func confirmationLapses() {
        var machine = opened()
        _ = machine.dismiss(.escapeKey(contentHasFocus: true))
        #expect(machine.confirmationLapsed() == [.disarmConfirmation])
        #expect(machine.phase == .open)
        #expect(machine.dismiss(.escapeKey(contentHasFocus: true))
                == [.armConfirmation(GlanceMachine.confirmationWindow)])
    }

    @Test("Moving the selection away closes without animating towards a page that has gone")
    func selectionChangeClosesUnanimated() {
        var machine = opened()
        #expect(machine.dismiss(.selectionChanged) == [.disarmConfirmation, .animateClose(animated: false)])
    }

    @Test("Closing tears the page down")
    func closingTearsDown() {
        var machine = opened()
        _ = machine.dismiss(.closeButton)
        #expect(machine.closingFinished() == [.teardown])
        #expect(machine.phase == .closed)
        #expect(machine.request == nil)
    }

    @Test("Promotion hands the page on and never tears it down")
    func promotionHandsOff() {
        var machine = opened()
        #expect(machine.promote() == [.disarmConfirmation, .animatePromotion])
        #expect(machine.phase == .promoting)

        let effects = machine.promotionFinished()
        #expect(effects == [.handOffWebView(request())])
        #expect(!effects.contains(.teardown))
        #expect(machine.phase == .closed)
    }

    @Test("Promotion is available from an armed guard, and disarms it")
    func promotionFromArmedGuard() {
        var machine = opened()
        _ = machine.dismiss(.escapeKey(contentHasFocus: true))
        #expect(machine.promote() == [.disarmConfirmation, .animatePromotion])
    }

    @Test("Promotion is refused mid-animation, so Cmd-O during the fly-out is ignored")
    func promotionRefusedMidAnimation() {
        var machine = GlanceMachine()
        _ = machine.open(request())
        #expect(machine.promote().isEmpty)
    }

    @Test("Finish events are idempotent: a repeated completion cannot reopen or re-tear-down")
    func finishEventsAreIdempotent() {
        var machine = opened()
        #expect(machine.openingFinished().isEmpty)
        _ = machine.dismiss(.closeButton)
        #expect(machine.closingFinished() == [.teardown])
        #expect(machine.closingFinished().isEmpty)
        #expect(machine.promotionFinished().isEmpty)
    }

    @Test("Nothing happens to a machine that is already closed")
    func closedMachineIgnoresEverything() {
        var machine = GlanceMachine()
        #expect(machine.dismiss(.ownerTabClosed).isEmpty)
        #expect(machine.promote().isEmpty)
        #expect(machine.confirmationLapsed().isEmpty)
    }
}

@Suite("Glance invocation rules")
struct GlanceInvocationTests {
    @Test("Exactly one modifier, and it is Option")
    func chordRequiresExactlyOneModifier() {
        #expect(GlanceInvocation.isGlanceChord(.option))
        #expect(!GlanceInvocation.isGlanceChord([]))
        #expect(!GlanceInvocation.isGlanceChord(.command))
        #expect(!GlanceInvocation.isGlanceChord([.option, .command]))
        #expect(!GlanceInvocation.isGlanceChord([.option, .shift]))
    }

    @Test("Flags the user did not type are ignored")
    func incidentalFlagsAreIgnored() {
        #expect(GlanceInvocation.isGlanceChord([.option, .capsLock]))
        #expect(GlanceInvocation.isGlanceChord([.option, .function, .numericPad]))
    }

    @Test("Only real page schemes may be glanced")
    func permittedSchemes() {
        for allowed in ["https://example.com", "http://example.com", "file:///tmp/a.html"] {
            #expect(GlanceInvocation.isPermittedTarget(URL(string: allowed)!))
        }
        for blocked in ["javascript:alert(1)", "data:text/html,<b>hi", "about:blank", "mailto:a@b.c"] {
            #expect(!GlanceInvocation.isPermittedTarget(URL(string: blocked)!))
        }
    }

    @Test("An off-site link out of a pinned site is a candidate only when the switch is on")
    func autoGlanceNeedsTheSwitch() {
        let link = URL(string: "https://news.example.org/story")!
        let owner = URL(string: "https://mail.example.com/inbox")!
        #expect(GlanceInvocation.shouldAutoGlance(
            linkURL: link, ownerURL: owner, ownerIsPinnedSite: true, enabled: true))
        #expect(!GlanceInvocation.shouldAutoGlance(
            linkURL: link, ownerURL: owner, ownerIsPinnedSite: true, enabled: false))
        #expect(!GlanceInvocation.shouldAutoGlance(
            linkURL: link, ownerURL: owner, ownerIsPinnedSite: false, enabled: true))
    }

    @Test("A link back to the same site is not off-site, www or not")
    func autoGlanceIgnoresSameSite() {
        let owner = URL(string: "https://example.com/inbox")!
        for sameSite in ["https://example.com/other", "https://www.example.com/other"] {
            #expect(!GlanceInvocation.shouldAutoGlance(
                linkURL: URL(string: sameSite)!, ownerURL: owner, ownerIsPinnedSite: true, enabled: true))
        }
        // A subdomain is a different host and is treated as off-site: erring
        // this way costs an extra glance rather than a missed one.
        #expect(GlanceInvocation.shouldAutoGlance(
            linkURL: URL(string: "https://files.example.com/a")!,
            ownerURL: owner, ownerIsPinnedSite: true, enabled: true))
    }
}

@Suite("Glance geometry")
struct GlanceGeometryTests {
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)

    @Test("The card is 80 percent wide, inset top and bottom, and centred")
    func cardFrame() {
        let card = GlanceGeometry.cardFrame(in: bounds)
        #expect(card.width == 800)
        #expect(card.minX == 100)
        #expect(card.minY == GlanceGeometry.verticalInset)
        #expect(card.height == 700 - GlanceGeometry.verticalInset * 2)
    }

    @Test("The rail sits outside the card when there is room for it")
    func railOutside() {
        let layout = GlanceGeometry.layout(in: bounds)
        #expect(!layout.railOverlapsCard)
        #expect(layout.rail.maxX == layout.card.minX)
        #expect(layout.rail.maxY == layout.card.maxY - GlanceGeometry.railTopInset)
    }

    @Test("At the window's minimum width the rail moves over the page rather than off the screen")
    func railInsideWhenNarrow() {
        // 400 points of content is narrower than Kylmora's window can go, which is
        // the point: the layout must not produce a negative-origin rail before
        // it is reachable by dragging.
        let layout = GlanceGeometry.layout(in: CGRect(x: 0, y: 0, width: 400, height: 500))
        #expect(layout.railOverlapsCard)
        #expect(layout.rail.minX == layout.card.minX)
        #expect(layout.rail.minX >= 0)
    }

    @Test("A caller with no element gets a zero-size origin at the centre")
    func centreOrigin() {
        let origin = GlanceGeometry.originFrame(for: nil, in: bounds)
        #expect(origin == CGRect(x: 500, y: 350, width: 0, height: 0))
        #expect(GlanceGeometry.originFrame(for: .zero, in: bounds) == origin)
    }

    @Test("A rectangle scrolled off screen falls back to the centre")
    func offscreenOriginFallsBack() {
        let offscreen = CGRect(x: -900, y: -900, width: 100, height: 20)
        #expect(GlanceGeometry.originFrame(for: offscreen, in: bounds)
                == CGRect(x: 500, y: 350, width: 0, height: 0))
    }

    @Test("An on-screen element rectangle is used as it is")
    func elementOriginIsKept() {
        let rect = CGRect(x: 120, y: 300, width: 90, height: 18)
        #expect(GlanceGeometry.originFrame(for: rect, in: bounds) == rect)
    }
}

@Suite("Glance link messages")
struct GlanceScriptTests {
    private func body(
        href: String = "https://example.com/a",
        x: Double = 10, y: Double = 20, width: Double = 100, height: Double = 18,
        viewportWidth: Double = 800, viewportHeight: Double = 600
    ) -> [String: Any] {
        [
            "href": href, "x": x, "y": y, "width": width, "height": height,
            "viewportWidth": viewportWidth, "viewportHeight": viewportHeight
        ]
    }

    @Test("A well-formed message becomes a record")
    func parsesGoodMessage() {
        let record = GlanceScripts.parseLink(body())
        #expect(record?.url.absoluteString == "https://example.com/a")
        #expect(record?.rect == CGRect(x: 10, y: 20, width: 100, height: 18))
        #expect(record?.viewport == CGSize(width: 800, height: 600))
    }

    @Test("A scheme a glance may not carry is rejected before anything else looks at it")
    func rejectsHostileSchemes() {
        #expect(GlanceScripts.parseLink(body(href: "javascript:alert(1)")) == nil)
        #expect(GlanceScripts.parseLink(body(href: "data:text/html,<b>")) == nil)
    }

    @Test("Missing, non-numeric and impossible geometry is rejected")
    func rejectsBadGeometry() {
        var missing = body()
        missing["width"] = nil
        #expect(GlanceScripts.parseLink(missing) == nil)

        var text = body()
        text["x"] = "10"
        #expect(GlanceScripts.parseLink(text) == nil)

        #expect(GlanceScripts.parseLink(body(width: -5)) == nil)
        #expect(GlanceScripts.parseLink(body(viewportWidth: 0)) == nil)
        #expect(GlanceScripts.parseLink(body(x: .nan)) == nil)
        #expect(GlanceScripts.parseLink(body(y: .infinity)) == nil)
    }

    @Test("Anything that is not the expected shape is rejected")
    func rejectsWrongShapes() {
        #expect(GlanceScripts.parseLink("https://example.com") == nil)
        #expect(GlanceScripts.parseLink([1, 2, 3]) == nil)
        #expect(GlanceScripts.parseLink([String: Any]()) == nil)
    }

    @Test("A record goes stale, so a rectangle from three scrolls ago is never used")
    func recordsGoStale() {
        let record = GlanceScripts.parseLink(body(), at: .now)!
        #expect(record.isFresh())
        #expect(!record.isFresh(at: .now.addingTimeInterval(GlanceLinkRecord.freshness + 1)))
    }
}

@Suite("Glance overlay")
@MainActor
struct GlanceOverlayTests {
    /// The dim behind the card must not dim the card. The backdrop lives on
    /// its own layer, so a 30%-opaque backdrop leaves the card and the page
    /// inside it fully opaque rather than showing the owner page through them.
    @Test("The backdrop dims without fading the card")
    func backdropIsSeparateFromCard() {
        let overlay = GlanceOverlayView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        overlay.layoutSubtreeIfNeeded()
        overlay.present(from: NSRect(x: 10, y: 10, width: 40, height: 20), animated: false) {}

        // The backdrop reaches the intended dim.
        #expect(overlay.backdropOpacity == GlanceGeometry.backdropOpacity)
        // The overlay's own layer stays fully opaque, so its subviews -- the
        // card and the glanced page -- are not dimmed with the backdrop.
        #expect((overlay.layer?.opacity ?? 1) == 1)
    }

    @Test("Dismissing clears the dim")
    func dismissClearsBackdrop() {
        let overlay = GlanceOverlayView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        overlay.layoutSubtreeIfNeeded()
        overlay.present(from: .zero, animated: false) {}
        overlay.dismiss(to: .zero, animated: false) {}
        #expect(overlay.backdropOpacity == 0)
    }
}
