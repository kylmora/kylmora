import AppKit
import Foundation
import Testing
@testable import Kylmora

@Suite("Sidebar Modes and Placement (F-13)")
@MainActor
struct SidebarModesTests {

    @Test("SidebarMode and SidebarPosition have clean titles and codable representations")
    func modeAndPositionEnums() {
        #expect(SidebarMode.expanded.title == "Always Expanded")
        #expect(SidebarMode.iconsOnly.title == "Icons Only (Expand on Hover)")
        #expect(SidebarMode.compact.title == "Compact (Slide in on Hover)")
        #expect(SidebarMode.hidden.title == "Hidden")

        #expect(SidebarPosition.leading.title == "Left")
        #expect(SidebarPosition.trailing.title == "Right")

        let preset = SidebarHoverDelayPreset.preset(for: 0.22)
        #expect(preset == .balanced)
        #expect(SidebarHoverDelayPreset.preset(for: 0.0) == .instant)
        #expect(SidebarHoverDelayPreset.preset(for: 0.45) == .deliberate)
    }

    @Test("CompactModeState with iconsOnlyCollapsed keeps 60pt visible on screen when idle")
    func iconsOnlyCollapsedPushOut() {
        var state = CompactModeState()
        state.isEnabled = true
        state.measuredSidebarWidth = 260
        state.configuration.iconsOnlyCollapsed = true
        state.configuration.iconsOnlyVisibleWidth = 60

        // At rest (not hovered/revealed):
        // floatingSidebarWidth = 260
        // revealedPushOut = 4
        // hiddenPushOut = 260 - 60 - 4 = 196
        #expect(state.presentation.sidebarIsFloating)
        #expect(state.presentation.sidebarWidth == 260)
        #expect(state.presentation.sidebarPushOut == 196)

        // The visible width inside the window is width - pushOut = 260 - 196 = 64 (less 4pt float = 60pt)
        let visibleWidth = state.presentation.sidebarWidth - state.presentation.sidebarPushOut - state.effectiveConfiguration.float / 2
        #expect(visibleWidth == 60)

        // When hovered:
        state.sidebarReasons = [.pointerHover]
        #expect(state.sidebarIsRevealed)
        #expect(state.presentation.sidebarPushOut == 4)
        // Fully expanded: 260 - 4 - 4 = 252 visible points inside window!
    }

    @Test("Standard compact mode leaves only 5pt hover sliver on screen")
    func standardCompactPushOut() {
        var state = CompactModeState()
        state.isEnabled = true
        state.measuredSidebarWidth = 260
        state.configuration.iconsOnlyCollapsed = false

        let expected: CGFloat = 260 - 4 - 1
        #expect(state.presentation.sidebarWidth == 260)
        #expect(state.presentation.sidebarPushOut == expected)
        #expect(state.presentation.sidebarWidth - state.presentation.sidebarPushOut == 5)
    }

    @Test("Sidebar trailing edge preserves push-out magnitude")
    func trailingEdgeConfiguration() {
        var config = CompactModeConfiguration()
        config.sidebarEdge = .trailing
        #expect(config.sidebarEdge == .trailing)

        var state = CompactModeState()
        state.isEnabled = true
        state.configuration = config
        state.measuredSidebarWidth = 280

        let expected: CGFloat = 280 - 4 - 1
        #expect(state.effectiveConfiguration.sidebarEdge == .trailing)
        #expect(state.presentation.sidebarWidth == 280)
        #expect(state.presentation.sidebarPushOut == expected)
    }

    private func enterCompact(_ controller: CompactModeController) {
        controller.setEnabled(true, animated: false)
        controller.hoverBegan(on: .sidebar)
    }

    @Test("Hover delay debounce postpones reveal until delay expires")
    func hoverDelayDebounce() async {
        final class TestHost: CompactModeHost, @unchecked Sendable {
            func compactMode(
                _ controller: CompactModeController,
                apply presentation: CompactPresentation,
                transition: CompactTransition
            ) {}
        }

        let host = await MainActor.run { TestHost() }
        let controller = await MainActor.run {
            CompactModeController(
                host: host,
                sleep: { duration in
                    try await Task.sleep(for: .milliseconds(10))
                }
            )
        }

        await MainActor.run {
            enterCompact(controller)
            var cfg = controller.state.configuration
            cfg.hoverDebounce = 0.20
            controller.setConfiguration(cfg)
        }

        // Before hover: not revealed
        let isRevealedBefore = await MainActor.run { controller.state.sidebarIsRevealed }
        #expect(!isRevealedBefore)

        // Trigger real hover
        await MainActor.run {
            controller.hoverBegan(on: .sidebar)
        }

        // Give debounce task time to execute
        var isRevealedAfter = false
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(20))
            isRevealedAfter = await MainActor.run { controller.state.sidebarIsRevealed }
            if isRevealedAfter { break }
        }

        #expect(isRevealedAfter)
    }

    @Test("Exiting hover before debounce delay cancels scheduled reveal")
    func hoverGrazeCancelled() async {
        final class TestHost: CompactModeHost, @unchecked Sendable {
            func compactMode(
                _ controller: CompactModeController,
                apply presentation: CompactPresentation,
                transition: CompactTransition
            ) {}
        }

        let host = await MainActor.run { TestHost() }
        let controller = await MainActor.run {
            CompactModeController(
                host: host,
                sleep: { duration in
                    try await Task.sleep(for: .milliseconds(150))
                }
            )
        }

        await MainActor.run {
            enterCompact(controller)
            var cfg = controller.state.configuration
            cfg.hoverDebounce = 0.30
            controller.setConfiguration(cfg)

            // Pointer enters
            controller.hoverBegan(on: .sidebar)
            // Pointer leaves immediately before debounce completes
            controller.hoverEnded(on: .sidebar)
        }

        // Wait past the debounce duration
        try? await Task.sleep(for: .milliseconds(50))

        let isRevealed = await MainActor.run { controller.state.sidebarIsRevealed }
        #expect(!isRevealed)
    }

    @Test("Settings stores and loads sidebar preferences")
    func settingsPersistence() {
        let settings = Settings.shared
        let originalMode = settings.sidebarMode
        let originalPos = settings.sidebarPosition
        let originalDelay = settings.sidebarHoverDelay
        let originalZen = settings.zenModeEnabled

        defer {
            settings.sidebarMode = originalMode
            settings.sidebarPosition = originalPos
            settings.sidebarHoverDelay = originalDelay
            settings.zenModeEnabled = originalZen
        }

        settings.sidebarMode = .iconsOnly
        #expect(settings.sidebarMode == .iconsOnly)
        #expect(settings.compactModeConfiguration.iconsOnlyCollapsed)

        settings.sidebarPosition = .trailing
        #expect(settings.sidebarPosition == .trailing)
        #expect(settings.compactModeConfiguration.sidebarEdge == .trailing)

        settings.sidebarHoverDelay = 0.40
        #expect(settings.sidebarHoverDelay == 0.40)
        #expect(settings.compactModeConfiguration.hoverDebounce == 0.40)

        settings.zenModeEnabled = true
        #expect(settings.zenModeEnabled)
    }

    @Test("Writing the mode it already has says nothing")
    func unchangedModeDoesNotNotify() {
        // The window controller answers `sidebarModeDidChange` by calling
        // `setSidebarMode`, which writes the mode straight back. A post on
        // every write is therefore a loop -- and because a main-queue observer
        // is called synchronously on the main thread, it is recursion, not a
        // busy loop. Entering compact mode overflowed the stack and killed the
        // app before it drew a frame of it.
        let settings = Settings.shared
        let original = settings.sidebarMode
        defer { settings.sidebarMode = original }

        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: .sidebarModeDidChange, object: nil, queue: nil
        ) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        settings.sidebarMode = .expanded
        posts = 0

        settings.sidebarMode = .compact
        #expect(posts == 1, "a real change is announced once")
        settings.sidebarMode = .compact
        settings.sidebarMode = .compact
        #expect(posts == 1, "writing the same mode again announces nothing")
        // And the compact flag still follows the mode, written every time.
        #expect(settings.compactModeEnabled)

        settings.sidebarMode = .expanded
        #expect(posts == 2)
        #expect(!settings.compactModeEnabled)
    }
}

/// The gutter the page card leaves where the sidebar would be.
@Suite("The page card's leading gutter")
@MainActor
struct CardGutterTests {
    private let gap = Style.Metrics.elementSeparation

    @Test("Compact mode gives the card its own margin")
    func compactKeepsTheGutter() {
        // The sidebar is removed from the split view in compact mode, not
        // collapsed, so `isSidebarCollapsed` is false -- and the card was
        // given the flush-to-the-divider inset of 0 for a divider that was no
        // longer there. It ran into the window's rounded corners: a square
        // edge under the arc at the top left, two corners pinched together at
        // the bottom left, while the other edges kept their gutter and looked
        // right.
        #expect(CardGutter.leadingInset(
            mode: .compact, isTrailing: false, isZenMode: false,
            isSidebarCollapsed: false, isCompact: true
        ) == gap)
        #expect(CardGutter.leadingInset(
            mode: .iconsOnly, isTrailing: false, isZenMode: false,
            isSidebarCollapsed: false, isCompact: true
        ) == gap)
    }

    @Test("With the sidebar in the layout the card starts at the divider")
    func expandedRunsFlush() {
        #expect(CardGutter.leadingInset(
            mode: .expanded, isTrailing: false, isZenMode: false,
            isSidebarCollapsed: false, isCompact: false
        ) == 0)
        // On the trailing side nothing is on the card's leading edge, so it
        // carries its own margin there.
        #expect(CardGutter.leadingInset(
            mode: .expanded, isTrailing: true, isZenMode: false,
            isSidebarCollapsed: false, isCompact: false
        ) == gap)
    }

    @Test("A collapsed or hidden sidebar leaves the same margin as compact")
    func collapsedMatchesCompact() {
        #expect(CardGutter.leadingInset(
            mode: .hidden, isTrailing: false, isZenMode: false,
            isSidebarCollapsed: true, isCompact: false
        ) == gap)
    }

    @Test("Icons-only keeps room for the strip, and zen mode keeps none")
    func iconsOnlyAndZen() {
        #expect(CardGutter.leadingInset(
            mode: .iconsOnly, isTrailing: false, isZenMode: false,
            isSidebarCollapsed: false, isCompact: false
        ) == 60)
        #expect(CardGutter.leadingInset(
            mode: .compact, isTrailing: false, isZenMode: true,
            isSidebarCollapsed: false, isCompact: true
        ) == 0)
    }
}

/// Where the window's traffic lights sit while compact mode has them.
@Suite("The traffic lights on the compact top bar")
@MainActor
struct CompactTrafficLightTests {
    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
    }

    private func makeBar() -> NSView {
        let bar = NSView(frame: NSRect(
            x: 0, y: 0, width: 800, height: Style.Metrics.topBarHeight
        ))
        return bar
    }

    @Test("They land on the bar's centre line")
    func centredOnTheBar() throws {
        let window = makeWindow()
        let bar = makeBar()
        let lights = try #require(CompactTrafficLights(window: window))
        lights.move(to: .toolbar, toolbarView: bar)

        let buttons = bar.subviews.compactMap { $0 as? NSButton }
        #expect(buttons.count == 3, "all three moved onto the bar")
        for button in buttons {
            #expect(abs(button.frame.midY - bar.bounds.midY) <= 0.5,
                    "a light sits on the same centre line as the bar's own buttons")
        }
    }

    @Test("The bar takes them back when AppKit reclaims them")
    func reclaimedLightsComeBack() throws {
        // AppKit puts the standard window buttons back into `NSTitlebarView`
        // whenever it rebuilds the titlebar. Nothing we own places them there,
        // so they sat six points off the titlebar's bottom edge while the bar
        // started eight points lower -- the three lights floating above the
        // toolbar buttons they are meant to line up with. The bar re-adopts
        // them on every layout.
        let window = makeWindow()
        let bar = makeBar()
        let lights = try #require(CompactTrafficLights(window: window))
        lights.move(to: .toolbar, toolbarView: bar)

        let stolen = try #require(bar.subviews.compactMap { $0 as? NSButton }.first)
        let thief = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 28))
        thief.addSubview(stolen)
        stolen.frame.origin = CGPoint(x: 9, y: 6)
        #expect(stolen.superview !== bar)

        lights.recentre(in: bar)

        #expect(stolen.superview === bar, "the bar took it back")
        #expect(abs(stolen.frame.midY - bar.bounds.midY) <= 0.5, "and put it on the centre line")
    }
}

/// The lights on the sidebar's own header strip.
@Suite("The traffic lights on the sidebar header")
@MainActor
struct SidebarHeaderTrafficLightTests {
    private func makeWindow(hosting header: SidebarHeaderView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        header.frame = NSRect(
            x: 0, y: 600 - Style.Metrics.titlebarHeight,
            width: 300, height: Style.Metrics.titlebarHeight
        )
        window.contentView?.addSubview(header)
        return window
    }

    @Test("They sit on the same line as the space's name")
    func centredOnTheStrip() {
        // The lights are the window's own buttons: the titlebar places them
        // six points off its bottom edge, and this strip is 53 points tall
        // with the name centred at 26.5. Left alone they floated twelve points
        // above the name they belong beside.
        let header = SidebarHeaderView()
        let window = makeWindow(hosting: header)
        header.layoutSubtreeIfNeeded()
        header.layout()

        let lights = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
        #expect(lights.count == 3)
        for light in lights {
            #expect(light.superview === header, "the strip hosts the light")
            #expect(abs(light.frame.midY - header.bounds.midY) <= 0.5,
                    "on the strip's centre line, which is the name's")
        }
    }

    @Test("It leaves them alone when something else is hosting them")
    func yieldsWhenNotTheHost() {
        // Compact mode moves them to the page's top bar, and a trailing
        // sidebar leaves them over the page. The strip must not snatch them
        // back on its next layout.
        let header = SidebarHeaderView()
        let window = makeWindow(hosting: header)
        header.hostsTrafficLights = false
        header.layout()

        let close = window.standardWindowButton(.closeButton)
        #expect(close?.superview !== header)
    }
}

/// Who holds the window's lights, given what the window is showing.
@Suite("Where the traffic lights live")
@MainActor
struct TrafficLightHostTests {
    /// The rule `updateTrafficLights` applies. The header strip keeps them
    /// while it is on screen to keep them; otherwise they ride the page's bar.
    private func ridesOnBar(
        compact: Bool, trailing: Bool, collapsed: Bool
    ) -> Bool {
        compact || trailing || collapsed
    }

    @Test("A collapsed sidebar hands them to the page's bar")
    func collapsedHandsThemOver() {
        // The strip is the sidebar's, and a collapsed sidebar has no strip:
        // the lights went with it and the window was left with no close
        // button at all.
        #expect(ridesOnBar(compact: false, trailing: false, collapsed: true))
        #expect(ridesOnBar(compact: true, trailing: false, collapsed: false))
        #expect(ridesOnBar(compact: false, trailing: true, collapsed: false))
    }

    @Test("A sidebar that is there keeps them")
    func visibleSidebarKeepsThem() {
        #expect(!ridesOnBar(compact: false, trailing: false, collapsed: false))
    }
}

/// What width compact mode floats the sidebar at.
@Suite("The floating sidebar's width")
@MainActor
struct SidebarMeasurementTests {
    private let minimum = Style.Metrics.sidebarMinWidth

    @Test("A floating sidebar is never measured")
    func floatingIsNotMeasured() {
        // While it floats, the sidebar view is the plate's content: its width
        // is the plate's width. Reading it back as the sidebar's own resting
        // width shaved it towards the floor on every pass -- a floating
        // sidebar with every row truncated, and a real sidebar that came back
        // from compact mode narrower than it went in.
        #expect(SidebarMeasurement.resting(
            live: minimum, isFloating: true, stored: 233, minimum: minimum
        ) == 233)
        #expect(SidebarMeasurement.resting(
            live: 105, isFloating: true, stored: 233, minimum: minimum
        ) == 233)
    }

    @Test("A sidebar in the split view is measured")
    func dockedIsMeasured() {
        #expect(SidebarMeasurement.resting(
            live: 260, isFloating: false, stored: 233, minimum: minimum
        ) == 260)
    }

    @Test("A width at the floor is not a width anyone chose")
    func minimumMeansNotLaidOutYet() {
        // A sidebar that has not been laid out in the split view reports
        // exactly the minimum, which is how the floor got in in the first
        // place.
        #expect(SidebarMeasurement.resting(
            live: minimum, isFloating: false, stored: 233, minimum: minimum
        ) == 233)
        #expect(SidebarMeasurement.resting(
            live: 0, isFloating: false, stored: 233, minimum: minimum
        ) == 233)
    }
}

/// Getting the floating sidebar to go away again.
@Suite("Putting the floating sidebar away")
@MainActor
struct DismissFloatingSidebarTests {
    @Test("Dismiss clears the pin and the hover holding it open")
    func dismissClearsEverything() {
        // The button that does this is *inside* the sidebar, so the pointer is
        // on the plate when it is pressed. Clearing only the pin would leave
        // the hover reason holding the sidebar open and the click would look
        // ignored.
        let controller = CompactModeController()
        controller.setEnabled(true, animated: false)
        controller.hoverBegan(on: .sidebar, isDrag: true)
        controller.toggleUserShow()
        #expect(controller.state.sidebarIsRevealed)

        controller.dismissSidebar()
        #expect(!controller.state.sidebarIsRevealed, "nothing is holding it open any more")
    }

    @Test("A pin put the sidebar on top of the only button that unpinned it")
    func pinDoesNotStrandTheUser() {
        // The toolbar's toggle pins the floating sidebar, and the sidebar then
        // covers that toolbar. Pinned, it does not answer the pointer leaving
        // either -- so with a mouse alone there was no way back out. The
        // sidebar carries its own dismiss button for exactly this state.
        let controller = CompactModeController()
        controller.setEnabled(true, animated: false)
        controller.toggleUserShow()
        #expect(controller.state.sidebarIsRevealed, "pinned open")

        controller.pointerLeftWindow()
        #expect(controller.state.sidebarIsRevealed, "and a pin outlasts the pointer")

        controller.dismissSidebar()
        #expect(!controller.state.sidebarIsRevealed)
    }
}
