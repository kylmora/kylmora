import Foundation
import Testing
@testable import Kylmora

// Compact mode is a state machine, a sampled curve and a click policy. All
// three are values, and all three are tested as values: there is no window
// here, and the views that apply what these decide are not exercised at all.

@Suite("Compact mode state")
struct CompactModeStateTests {

    private func enabled(width: CGFloat = 306) -> CompactModeState {
        var state = CompactModeState()
        state.isEnabled = true
        state.measuredSidebarWidth = width
        return state
    }

    @Test("With compact mode off nothing hides and nothing floats")
    func offIsInert() {
        let state = CompactModeState()
        #expect(state.hidesSidebar == false)
        #expect(state.sidebarIsRevealed)
        #expect(state.presentation.sidebarIsFloating == false)
        #expect(state.presentation.sidebarPushOut == 0)
        #expect(state.presentation.trafficLightHost == .sidebar)
    }

    @Test("A hidden sidebar leaves a sliver on screen to hover")
    func hiddenLeavesAHoverTarget() {
        let state = enabled()
        let presentation = state.presentation
        #expect(presentation.sidebarIsFloating)
        // Pushed out by its own width less the float's half and one point, so
        // five points of plate stay inside the window.
        let expected: CGFloat = 306 - 4 - 1
        #expect(presentation.sidebarPushOut == expected)
        #expect(presentation.sidebarWidth - presentation.sidebarPushOut == 5)
    }

    @Test("A revealed sidebar sits half the float outside the edge")
    func revealedOffset() {
        var state = enabled()
        state.sidebarReasons = [.pointerHover]
        #expect(state.presentation.sidebarPushOut == 4)
    }

    @Test("The chrome stays up until the last reason goes away")
    func reasonsOverlap() {
        var state = enabled()
        state.sidebarReasons = [.pointerHover, .popupMenu]
        state.sidebarReasons.remove(.pointerHover)
        #expect(state.sidebarIsRevealed)
        state.sidebarReasons.remove(.popupMenu)
        #expect(state.sidebarIsRevealed == false)
    }

    @Test("Turning hover reveal off leaves every other trigger working")
    func hoverGate() {
        var state = enabled()
        state.configuration.revealsOnHover = false
        state.sidebarReasons = [.pointerHover, .dragHover]
        #expect(state.sidebarIsRevealed == false)
        state.sidebarReasons.insert(.userShow)
        #expect(state.sidebarIsRevealed)
    }

    @Test("Collapsed and compact are different axes and combine")
    func collapsedInCompact() {
        var state = enabled()
        state.isSidebarCollapsed = true
        #expect(state.floatingSidebarWidth == 74)
        state.sidebarReasons = [.pointerHover]
        #expect(state.presentation.sidebarWidth == 74)
        #expect(state.presentation.sidebarPushOut == 4)
    }

    @Test("A compact sidebar is never narrower than the readable floor")
    func widthFloor() {
        let state = enabled(width: 90)
        #expect(state.floatingSidebarWidth == Style.Metrics.sidebarMinWidth)
    }

    @Test("Hiding both halves would strand the traffic lights, so it is refused")
    func illegalState() {
        var configuration = CompactModeConfiguration()
        configuration.hidesSidebar = true
        configuration.hidesToolbar = true
        #expect(configuration.isIllegal)
        #expect(configuration.resolved.hidesToolbar == false)
        #expect(configuration.resolved.hidesSidebar)
    }

    @Test("Hiding the toolbar alone is legal and keeps the lights on the sidebar")
    func toolbarOnly() {
        var state = enabled()
        state.configuration.hidesSidebar = false
        state.configuration.hidesToolbar = true
        let presentation = state.presentation
        #expect(presentation.sidebarIsFloating == false)
        #expect(presentation.trafficLightHost == .sidebar)
        #expect(presentation.toolbarHeight == Style.Metrics.elementSeparation)
        #expect(presentation.toolbarOpacity == 0)
    }

    @Test("A floating sidebar takes the traffic lights to the toolbar")
    func trafficLightsFollowTheChrome() {
        #expect(enabled().presentation.trafficLightHost == .toolbar)
    }

    @Test("Fullscreen suppresses compact mode without switching it off")
    func suppression() {
        var state = enabled()
        state.suppressions = [.pageFullScreen]
        #expect(state.isEnabled)
        #expect(state.isActive == false)
        #expect(state.presentation.sidebarIsFloating == false)
        state.suppressions = []
        #expect(state.presentation.sidebarIsFloating)
    }

    @Test("The toolbar collapses to the gutter, not to nothing")
    func toolbarCollapsesToTheGutter() {
        var state = enabled()
        state.configuration.hidesSidebar = false
        state.configuration.hidesToolbar = true
        #expect(state.presentation.toolbarHeight == Style.Metrics.elementSeparation)
        state.toolbarReasons = [.pointerHover]
        #expect(state.presentation.toolbarHeight == Style.Metrics.topBarHeight)
        #expect(state.presentation.toolbarOpacity == 1)
    }
}

@Suite("Compact mode transitions")
struct CompactTransitionTests {

    @Test("Reveal and collapse are asymmetric, and the reveal overshoots")
    func asymmetric() {
        #expect(CompactTransition.reveal.duration == 0.25)
        #expect(CompactTransition.collapse.duration == 0.15)
        #expect(CompactTransition.reveal.curve == .revealSpring)
        #expect(CompactTransition.reveal.curve.mediaTimingFunction == nil)
        #expect(CompactTransition.collapse.curve.mediaTimingFunction != nil)
    }

    @Test("Switching the mode on and off is its own, quicker motion")
    func toggleMotion() {
        var before = CompactModeState()
        before.measuredSidebarWidth = 300
        var after = before
        after.isEnabled = true
        #expect(after.transition(from: before) == .enter)
        #expect(before.transition(from: after) == .exit)
        #expect(CompactTransition.enter.duration == 0.12)
        #expect(CompactTransition.enter.curve == .easeIn)
        #expect(CompactTransition.exit.curve == .easeOut)
    }

    @Test("A reveal animates one way and a collapse the other")
    func revealAndCollapse() {
        var hidden = CompactModeState()
        hidden.isEnabled = true
        var shown = hidden
        shown.sidebarReasons = [.pointerHover]
        #expect(shown.transition(from: hidden) == .reveal)
        #expect(hidden.transition(from: shown) == .collapse)
    }

    @Test("A second reveal reason moves nothing, so it animates nothing")
    func noMotionWithoutMovement() {
        var one = CompactModeState()
        one.isEnabled = true
        one.sidebarReasons = [.pointerHover]
        var two = one
        two.sidebarReasons.insert(.popupMenu)
        #expect(two.transition(from: one) == .immediate)
    }

    @Test("Reduce Motion turns every transition into an immediate one")
    func reducedMotion() {
        var before = CompactModeState()
        before.configuration.reducesMotion = true
        var after = before
        after.isEnabled = true
        #expect(after.transition(from: before) == .immediate)
    }
}

@Suite("Compact mode controller")
@MainActor
struct CompactModeControllerTests {

    /// Records what the controller asked for, and lets the test drive the
    /// timers by hand.
    final class Recorder: CompactModeHost {
        var presentations: [CompactPresentation] = []
        var transitions: [CompactTransition] = []
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func compactMode(
            _ controller: CompactModeController,
            apply presentation: CompactPresentation,
            transition: CompactTransition
        ) {
            presentations.append(presentation)
            transitions.append(transition)
        }

        func sleep(_ seconds: Double) async {
            await withCheckedContinuation { waiters.append($0) }
        }

        var hasWaiters: Bool { !waiters.isEmpty }

        func fireTimers() {
            let pending = waiters
            waiters = []
            for waiter in pending { waiter.resume() }
        }
    }

    /// Lets any tasks the controller started run up to their next suspension.
    private func settle() async {
        for _ in 0..<8 { await Task.yield() }
    }

    /// Turns compact mode on and absorbs the one spurious hover the toggle
    /// itself causes -- which is what AppKit delivers, and what the controller
    /// swallows exactly once.
    private func enterCompact(_ controller: CompactModeController) {
        controller.setEnabled(true)
        controller.hoverBegan(on: .sidebar)
    }

    private func makePair() -> (CompactModeController, Recorder) {
        let recorder = Recorder()
        let controller = CompactModeController(sleep: { [recorder] in await recorder.sleep($0) })
        controller.setHost(recorder)
        controller.setMeasuredSidebarWidth(300)
        return (controller, recorder)
    }

    @Test("The sidebar stays up for the grace period after the pointer leaves")
    func keepHoverGrace() async {
        let (controller, recorder) = makePair()
        enterCompact(controller)
        controller.hoverBegan(on: .sidebar)
        #expect(controller.state.sidebarIsRevealed)

        controller.hoverEnded(on: .sidebar)
        await settle()
        // Still up: the grace timer is running.
        #expect(controller.state.sidebarIsRevealed)
        #expect(recorder.hasWaiters)

        recorder.fireTimers()
        await settle()
        #expect(controller.state.sidebarIsRevealed == false)
    }

    @Test("Coming back within the grace period cancels the collapse")
    func graceIsCancelled() async {
        let (controller, recorder) = makePair()
        enterCompact(controller)
        controller.hoverBegan(on: .sidebar)
        controller.hoverEnded(on: .sidebar)
        await settle()
        controller.hoverBegan(on: .sidebar)
        recorder.fireTimers()
        await settle()
        #expect(controller.state.sidebarIsRevealed)
    }

    @Test("A spurious exit during a drag is ignored")
    func spuriousExitIgnored() async {
        let (controller, recorder) = makePair()
        enterCompact(controller)
        controller.hoverBegan(on: .sidebar)
        controller.hoverEnded(on: .sidebar, isStillInside: { true })
        await settle()
        recorder.fireTimers()
        await settle()
        #expect(controller.state.sidebarIsRevealed)
    }

    @Test("Leaving the window keeps the sidebar up until the fallback timer")
    func pointerLeftWindow() async {
        let (controller, recorder) = makePair()
        enterCompact(controller)
        controller.hoverBegan(on: .sidebar)
        controller.pointerLeftWindow()
        await settle()
        #expect(controller.state.sidebarIsRevealed)

        recorder.fireTimers()
        await settle()
        #expect(controller.state.sidebarIsRevealed == false)
    }

    @Test("A flash shows the sidebar and puts it away again")
    func flash() async {
        let (controller, recorder) = makePair()
        controller.setEnabled(true)
        controller.flash()
        #expect(controller.state.sidebarIsRevealed)
        // The timer has to have started before it can be fired.
        await settle()
        recorder.fireTimers()
        await settle()
        #expect(controller.state.sidebarIsRevealed == false)
    }

    @Test("A user-pinned sidebar is not put away by any timer")
    func userShowSurvivesTimers() async {
        let (controller, recorder) = makePair()
        enterCompact(controller)
        controller.toggleUserShow()
        controller.hoverBegan(on: .sidebar)
        controller.hoverEnded(on: .sidebar)
        await settle()
        recorder.fireTimers()
        await settle()
        #expect(controller.state.sidebarIsRevealed)
        controller.toggleUserShow()
        #expect(controller.state.sidebarIsRevealed == false)
    }

    @Test("The hover that follows switching the mode on is swallowed")
    func ignoresTheHoverThatTheToggleCauses() async {
        let (controller, _) = makePair()
        controller.setEnabled(true)
        controller.hoverBegan(on: .sidebar)
        #expect(controller.state.sidebarIsRevealed == false)
    }

    @Test("Losing key clears every hover reason at once")
    func windowResignClearsHover() async {
        let (controller, _) = makePair()
        controller.setEnabled(true)
        controller.addReason(.popupMenu, to: .sidebar)
        controller.windowDidResignOrResize()
        #expect(controller.state.sidebarIsRevealed == false)
    }

    @Test("Restoring a compact window does not animate")
    func startupIsNotAnimated() {
        let (controller, recorder) = makePair()
        controller.setEnabled(true, animated: false)
        #expect(recorder.transitions.last == .immediate)
    }
}

@Suite("Compact reveal curve")
struct CompactRevealCurveTests {

    @Test("The reconstruction passes through every sample it was given")
    func hitsItsKnots() {
        for knot in CompactRevealCurve.knots {
            #expect(abs(CompactRevealCurve.value(at: knot.time) - knot.value) < 0.000001)
        }
    }

    @Test("It overshoots, peaks at 73% and lands a little short")
    func overshoots() {
        let peak = CompactRevealCurve.value(at: 0.73)
        #expect(peak > 1.0108 && peak < 1.011)
        #expect(CompactRevealCurve.value(at: 1) < 1.0035)
        #expect(CompactRevealCurve.value(at: 1) > 1.003)
        // Nothing between the samples may rise above the measured peak.
        for sample in CompactRevealCurve.samples() { #expect(sample <= peak + 0.000001) }
    }

    @Test("It crosses 1 about three-fifths of the way through")
    func crossingPoint() {
        let samples = CompactRevealCurve.samples()
        let crossing = samples.firstIndex { $0 >= 1 } ?? samples.count
        #expect(crossing >= 55 && crossing <= 62)
    }

    @Test("It rises without hesitating on the way to the peak")
    func risesMonotonically() {
        let samples = CompactRevealCurve.samples()
        for index in 1...73 { #expect(samples[index] >= samples[index - 1]) }
        for index in 75...100 { #expect(samples[index] <= samples[index - 1]) }
    }

    @Test("It is 101 stops, like the one it reconstructs")
    func sampleCount() {
        #expect(CompactRevealCurve.samples().count == 101)
        #expect(CompactRevealCurve.value(at: -1) == 0)
        #expect(CompactRevealCurve.value(at: 2) == CompactRevealCurve.value(at: 1))
    }
}

@Suite("Essentials")
struct EssentialsTests {

    private let spaceA = UUID()
    private let spaceB = UUID()

    private func site(_ address: String, title: String = "Site") -> PinnedSite {
        PinnedSite(url: URL(string: address)!, title: title)
    }

    private func snapshot(
        a: [PinnedSite] = [],
        b: [PinnedSite] = [],
        active: UUID? = nil,
        tabs: [EssentialsSnapshot.OpenTab] = [],
        activeTab: UUID? = nil
    ) -> EssentialsSnapshot {
        EssentialsSnapshot(
            spaces: [
                EssentialsSnapshot.SpaceEntry(id: spaceA, pinnedSites: a),
                EssentialsSnapshot.SpaceEntry(id: spaceB, pinnedSites: b)
            ],
            activeSpaceID: active ?? spaceA,
            openTabs: tabs,
            activeTabID: activeTab
        )
    }

    @Test("An essential pinned in one space is visible from the other")
    func sharedAcrossSpaces() {
        let controller = EssentialsController()
        let shot = snapshot(a: [site("https://a.example")], active: spaceB)
        #expect(controller.essentials(in: shot).count == 1)
    }

    @Test("The active space's own tiles come first")
    func activeSpaceFirst() {
        let controller = EssentialsController()
        let shot = snapshot(
            a: [site("https://a.example")],
            b: [site("https://b.example")],
            active: spaceB
        )
        #expect(controller.essentials(in: shot).first?.url.host() == "b.example")
    }

    @Test("The same site pinned in two spaces is one tile")
    func deduplicated() {
        let controller = EssentialsController()
        let shot = snapshot(a: [site("https://a.example/x")], b: [site("https://a.example/x?q=1")])
        #expect(controller.essentials(in: shot).count == 1)
    }

    @Test("Turning sharing off shows only the active space's tiles")
    func perSpace() {
        var configuration = EssentialsConfiguration()
        configuration.isSharedAcrossSpaces = false
        let controller = EssentialsController(configuration: configuration)
        let shot = snapshot(a: [site("https://a.example")], active: spaceB)
        #expect(controller.essentials(in: shot).isEmpty)
    }

    @Test("The strip has a limit, and says so")
    func maximum() {
        var configuration = EssentialsConfiguration()
        configuration.maximumCount = 2
        let controller = EssentialsController(configuration: configuration)
        let shot = snapshot(a: [site("https://a.example"), site("https://b.example")])
        #expect(controller.badge(in: shot) == "2/2")
        #expect(controller.canAdd(URL(string: "https://c.example")!, in: shot) == false)
        #expect(
            controller.rejection(forAdding: URL(string: "https://c.example")!, in: shot)
                == .atMaximum(2)
        )
    }

    @Test("A site that is already a tile is rejected as such, not as full")
    func alreadyEssential() {
        let controller = EssentialsController()
        let shot = snapshot(a: [site("https://a.example")])
        #expect(
            controller.rejection(forAdding: URL(string: "https://a.example")!, in: shot)
                == .alreadyEssential
        )
    }

    @Test("Clicking an open essential shows its tab and changes nothing else")
    func clickSelectsWithoutResetting() {
        let controller = EssentialsController()
        let pinned = site("https://mail.example/inbox")
        let tab = UUID()
        let shot = snapshot(
            a: [pinned],
            tabs: [.init(id: tab, spaceID: spaceA, url: URL(string: "https://mail.example/inbox/42")!)]
        )
        #expect(controller.activate(pinned, clickCount: 1, in: shot) == .selectTab(tab))
    }

    @Test("Clicking the tile you are already looking at does nothing")
    func clickOnTheActiveTab() {
        let controller = EssentialsController()
        let pinned = site("https://a.example")
        let tab = UUID()
        let shot = snapshot(
            a: [pinned],
            tabs: [.init(id: tab, spaceID: spaceA, url: URL(string: "https://a.example")!)],
            activeTab: tab
        )
        #expect(controller.activate(pinned, clickCount: 1, in: shot) == .none)
    }

    @Test("Clicking a tile with no tab opens one")
    func clickOpens() {
        let controller = EssentialsController()
        let pinned = site("https://a.example")
        let shot = snapshot(a: [pinned])
        #expect(controller.activate(pinned, clickCount: 1, in: shot) == .openTab(pinned.url))
    }

    @Test("A double click is what resets a strayed tile")
    func doubleClickResets() {
        let controller = EssentialsController()
        let pinned = site("https://mail.example/inbox")
        let tab = UUID()
        let strayed = URL(string: "https://mail.example/inbox/42")!
        let shot = snapshot(a: [pinned], tabs: [.init(id: tab, spaceID: spaceA, url: strayed)])
        #expect(
            controller.activate(pinned, clickCount: 2, in: shot) == .reset(tab: tab, to: pinned.url)
        )
    }

    @Test("Resetting a tile that has not strayed does nothing")
    func doubleClickOnAnUnchangedTile() {
        let controller = EssentialsController()
        let pinned = site("https://a.example")
        let tab = UUID()
        let shot = snapshot(a: [pinned], tabs: [.init(id: tab, spaceID: spaceA, url: pinned.url)])
        #expect(controller.activate(pinned, clickCount: 2, in: shot) == .none)
    }

    @Test("A tab in another space does not count as open here")
    func clickDoesNotSwitchSpace() {
        let controller = EssentialsController()
        let pinned = site("https://a.example")
        let shot = snapshot(
            a: [pinned],
            tabs: [.init(id: UUID(), spaceID: spaceB, url: pinned.url)]
        )
        #expect(controller.activate(pinned, clickCount: 1, in: shot) == .openTab(pinned.url))
    }

    @Test("Removing a tile demotes it into whichever space you are in")
    func removalDemotesIntoTheActiveSpace() {
        let controller = EssentialsController()
        let pinned = site("https://a.example")
        let shot = snapshot(a: [pinned], active: spaceB)
        let removal = controller.removal(of: pinned, in: shot)
        #expect(removal?.removeFrom == spaceA)
        #expect(removal?.demoteInto == spaceB)
    }
}

@Suite("Pinned tab navigation")
struct EssentialsNavigationPolicyTests {

    private let pinned = URL(string: "https://mail.example/inbox")!

    @Test("A link to another site opens a new tab and leaves the tile alone")
    func offHostLinkOpensATab() {
        let target = URL(string: "https://news.example/story")!
        #expect(
            EssentialsNavigationPolicy.destination(
                pinned: pinned,
                target: target,
                isLinkActivation: true
            ) == .newTab(target)
        )
    }

    @Test("A link within the same site stays in the tab")
    func sameHostStays() {
        #expect(
            EssentialsNavigationPolicy.destination(
                pinned: pinned,
                target: URL(string: "https://mail.example/settings")!,
                isLinkActivation: true
            ) == .sameTab
        )
    }

    @Test("Only a click counts: a redirect stays put")
    func redirectsStay() {
        #expect(
            EssentialsNavigationPolicy.destination(
                pinned: pinned,
                target: URL(string: "https://accounts.example/signin")!,
                isLinkActivation: false
            ) == .sameTab
        )
    }

    @Test("A target with no host is left to WebKit")
    func hostlessTargets() {
        #expect(
            EssentialsNavigationPolicy.destination(
                pinned: pinned,
                target: URL(string: "about:blank")!,
                isLinkActivation: true
            ) == .sameTab
        )
    }
}
