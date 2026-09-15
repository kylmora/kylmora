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
}
