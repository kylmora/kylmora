import AppKit

/// What a compact-mode controller talks to.
///
/// A protocol rather than a concrete view because the state machine has to be
/// drivable without a window: the timers, the debounce and the grace period are
/// the part most likely to be wrong, and they cannot be tested against a real
/// `NSTrackingArea`.
@MainActor
protocol CompactModeHost: AnyObject {
    /// Put the chrome where `presentation` says, using `transition`'s motion.
    ///
    /// Called for every change, including the ones that move nothing, so the
    /// host can settle constraints it owns without the controller having to
    /// know which of them matter.
    func compactMode(
        _ controller: CompactModeController,
        apply presentation: CompactPresentation,
        transition: CompactTransition
    )
}

/// Compact mode: the sidebar floats over the page instead of taking width from
/// it, and comes back on hover.
///
/// The controller owns the state machine and every timer around it. It owns no
/// geometry: it computes a `CompactPresentation` and hands it to a host. That
/// split is what lets the awkward parts -- the leave debounce, the 150 ms
/// keep-hover grace, the fallback timer after the pointer leaves the window --
/// be driven from a test with an injected clock instead of from a mouse.
///
/// Timers are structured `Task`s rather than `Timer`s: a `Timer` on the main
/// run loop does not fire during a modal tracking loop, which is exactly when a
/// context menu is open over the sidebar and the grace period matters most.
@MainActor
final class CompactModeController {

    /// Sleeps the timers use, injectable so tests do not wait in real time.
    ///
    /// Deliberately a closure and not a `Clock`: every one of these is "wait,
    /// then re-check state", and a protocol with an associated instant type
    /// would make the call sites generic for no gain.
    typealias Sleep = @MainActor (Double) async throws -> Void

    private(set) var state = CompactModeState()

    private weak var host: (any CompactModeHost)?
    private let sleep: Sleep

    private var keepHoverTask: Task<Void, Never>?
    private var outsideWindowTask: Task<Void, Never>?
    private var flashTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?

    /// Suppresses the first hover after compact mode is switched on.
    ///
    /// Turning compact mode on almost always leaves the pointer inside the
    /// area the sidebar just vacated, and AppKit will deliver a mouse-entered
    /// for the strip that appears under it. Without this the sidebar animates
    /// away and immediately back, which reads as a glitch rather than as a
    /// mode change.
    private var ignoresNextHover = false

    init(
        host: (any CompactModeHost)? = nil,
        sleep: @escaping Sleep = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.host = host
        self.sleep = sleep
    }

    func setHost(_ host: any CompactModeHost) {
        self.host = host
        host.compactMode(self, apply: state.presentation, transition: .immediate)
    }

    // MARK: - The master switch

    /// Turns compact mode on or off.
    ///
    /// `animated` is false on the first call after launch: restoring a window
    /// that was already in compact mode must not play the entry animation, or
    /// every launch starts with the sidebar sliding away.
    func setEnabled(_ enabled: Bool, animated: Bool = true) {
        guard enabled != state.isEnabled else { return }
        cancelTimers()
        var next = state
        next.isEnabled = enabled
        // Everything that was keeping the chrome up belonged to the old mode.
        next.sidebarReasons = []
        next.toolbarReasons = []
        ignoresNextHover = enabled
        apply(next, forcingImmediate: !animated)
    }

    func toggle() { setEnabled(!state.isEnabled) }

    func setConfiguration(_ configuration: CompactModeConfiguration) {
        var next = state
        next.configuration = configuration
        apply(next)
    }

    /// The persistent narrow/wide sidebar state, which is a different axis from
    /// compact mode and is owned elsewhere.
    func setSidebarCollapsed(_ collapsed: Bool) {
        var next = state
        next.isSidebarCollapsed = collapsed
        apply(next)
    }

    /// The measured resting width, so a hidden sidebar is pushed exactly its
    /// own width rather than a default one.
    func setMeasuredSidebarWidth(_ width: CGFloat) {
        guard width > 0, width != state.measuredSidebarWidth else { return }
        var next = state
        next.measuredSidebarWidth = width
        // A width change during a reveal would animate the plate's edge as
        // well as its position; the sidebar is being dragged, not revealed.
        apply(next, forcingImmediate: true)
    }

    // MARK: - Suppression

    func setSuppression(_ suppression: CompactSuppression, active: Bool) {
        var next = state
        if active {
            next.suppressions.insert(suppression)
        } else {
            next.suppressions.remove(suppression)
        }
        if active { next.sidebarReasons = []; next.toolbarReasons = [] }
        let wasSuppressed = !state.suppressions.isEmpty
        apply(next)
        // Coming back from fullscreen, the user has no way of knowing the
        // sidebar is there, so it flashes to make that visible.
        if wasSuppressed, next.suppressions.isEmpty, next.isEnabled {
            flash()
        }
    }

    /// The window stopped being key, or was minimised or zoomed.
    ///
    /// Every hover reason is dropped unconditionally: a window-manager
    /// interaction that moves the pointer without an exit event is the classic
    /// way to leave the sidebar stuck open, and there is no state worth
    /// preserving across it.
    func windowDidResignOrResize() {
        cancelTimers()
        var next = state
        next.sidebarReasons = []
        next.toolbarReasons = []
        apply(next, forcingImmediate: true)
    }

    // MARK: - Reveal reasons

    /// Adds a reveal reason that stays until it is explicitly removed.
    func addReason(_ reason: CompactRevealReason, to target: CompactTarget) {
        cancelKeepHover(for: target)
        mutateReasons(target) { $0.insert(reason) }
    }

    func removeReason(_ reason: CompactRevealReason, from target: CompactTarget) {
        mutateReasons(target) { $0.remove(reason) }
    }

    /// The pointer or a drag entered a hover target.
    ///
    /// `isDrag` chooses the reason rather than a separate entry point, because
    /// enter and leave have to be symmetric and AppKit delivers the drag half
    /// through a different protocol -- two entry points is two chances to add
    /// one reason and remove the other.
    func hoverBegan(on target: CompactTarget, isDrag: Bool = false) {
        // Consumed, not merely checked: the flag exists to swallow exactly one
        // spurious enter, and leaving it set would swallow the user's first
        // real hover as well.
        guard !ignoresNextHover else {
            ignoresNextHover = false
            return
        }
        cancelKeepHover(for: target)
        outsideWindowTask?.cancel()
        outsideWindowTask = nil
        let delay = isDrag ? 0 : state.effectiveConfiguration.hoverDebounce
        debounce(delay: delay) { [weak self] in
            guard let self else { return }
            self.mutateReasons(target) {
                $0.insert(isDrag ? .dragHover : .pointerHover)
                $0.remove(.pointerLeftWindow)
            }
        }
    }

    /// The pointer or a drag left a hover target.
    ///
    /// - Parameter isStillInside: re-check of the pointer's actual position.
    ///   AppKit sends a spurious exit when a drag session starts, and the guard
    ///   against it asks where the pointer really is rather than believing the
    ///   event.
    func hoverEnded(
        on target: CompactTarget,
        isDrag: Bool = false,
        isStillInside: @escaping @MainActor () -> Bool = { false }
    ) {
        ignoresNextHover = false
        // Cancel any pending reveal debounce so a cursor passing across does not reveal after leaving
        debounceTask?.cancel()
        debounceTask = nil
        debounce(delay: 0) { [weak self] in
            guard let self, !isStillInside() else { return }
            let grace = target == .sidebar ? self.state.effectiveConfiguration.sidebarKeepHover : 0
            let clear = { [weak self] in
                self?.mutateReasons(target) {
                    $0.remove(isDrag ? .dragHover : .pointerHover)
                }
            }
            guard grace > 0 else { clear(); return }
            self.keepHoverTask?.cancel()
            self.keepHoverTask = Task { [weak self] in
                guard let self else { return }
                try? await self.sleep(grace)
                guard !Task.isCancelled else { return }
                clear()
            }
        }
    }

    /// The pointer left the window entirely.
    ///
    /// The chrome could stay up while the pointer is within 200 points of the
    /// edge by asking the OS to track it outside the window. Kylmora cannot:
    /// that needs global event monitoring and the entitlement that comes with
    /// it. This is the fallback for the same situation -- a fixed timer --
    /// and it is a real behavioural difference, not a port.
    func pointerLeftWindow() {
        guard state.isActive else { return }
        outsideWindowTask?.cancel()
        mutateReasons(.sidebar) { $0.insert(.pointerLeftWindow) }
        outsideWindowTask = Task { [weak self] in
            guard let self else { return }
            try? await self.sleep(self.state.effectiveConfiguration.hideAfterPointerLeftWindow)
            guard !Task.isCancelled else { return }
            self.mutateReasons(.sidebar) {
                $0.remove(.pointerLeftWindow)
                $0.remove(.pointerHover)
                $0.remove(.dragHover)
            }
        }
    }

    /// The pointer came back into the window without landing on the chrome.
    func pointerReturnedToWindow() {
        outsideWindowTask?.cancel()
        outsideWindowTask = nil
        mutateReasons(.sidebar) { $0.remove(.pointerLeftWindow) }
    }

    /// A deliberate reveal-then-hide, for something that happened while the
    /// chrome was away.
    func flash(duration: Double? = nil) {
        guard state.isActive else { return }
        flashTask?.cancel()
        mutateReasons(.sidebar) { $0.insert(.flash) }
        let seconds = duration ?? state.effectiveConfiguration.flashDuration
        flashTask = Task { [weak self] in
            guard let self else { return }
            try? await self.sleep(seconds)
            guard !Task.isCancelled else { return }
            self.mutateReasons(.sidebar) { $0.remove(.flash) }
        }
    }

    /// Pins the chrome open, or lets it go again. The user's own override, and
    /// the only reason no timer may clear.
    func toggleUserShow() {
        let shown = state.sidebarReasons.contains(.userShow)
        cancelTimers()
        var next = state
        if shown {
            next.sidebarReasons.remove(.userShow)
            next.toolbarReasons.remove(.userShow)
        } else {
            next.sidebarReasons.insert(.userShow)
            next.toolbarReasons.insert(.userShow)
        }
        apply(next)
    }

    // MARK: - Plumbing

    /// Which half of the chrome a reveal reason belongs to.
    enum CompactTarget: Sendable, Equatable {
        case sidebar
        case toolbar
    }

    private func mutateReasons(
        _ target: CompactTarget,
        _ change: (inout CompactRevealReason) -> Void
    ) {
        var next = state
        switch target {
        case .sidebar: change(&next.sidebarReasons)
        case .toolbar: change(&next.toolbarReasons)
        }
        apply(next)
    }

    private func apply(_ next: CompactModeState, forcingImmediate: Bool = false) {
        guard next != state else { return }
        let previous = state
        state = next
        let transition: CompactTransition =
            forcingImmediate ? .immediate : next.transition(from: previous)
        host?.compactMode(self, apply: state.presentation, transition: transition)
    }

    private func debounce(delay: Double? = nil, _ work: @escaping @MainActor () -> Void) {
        let actualDelay = delay ?? state.effectiveConfiguration.hoverDebounce
        guard actualDelay > 0 else { return work() }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            try? await self.sleep(actualDelay)
            guard !Task.isCancelled else { return }
            work()
        }
    }

    private func cancelKeepHover(for target: CompactTarget) {
        guard target == .sidebar else { return }
        keepHoverTask?.cancel()
        keepHoverTask = nil
    }

    private func cancelTimers() {
        keepHoverTask?.cancel()
        outsideWindowTask?.cancel()
        flashTask?.cancel()
        debounceTask?.cancel()
        keepHoverTask = nil
        outsideWindowTask = nil
        flashTask = nil
        debounceTask = nil
    }
}
