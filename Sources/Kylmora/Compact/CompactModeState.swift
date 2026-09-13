import CoreGraphics

/// Which window edge the sidebar is docked against.
///
/// Compact mode is the one feature that has to know: an offscreen sidebar is
/// pushed past the edge it belongs to, and pushing it the wrong way would slide
/// it across the page instead of off the window.
enum CompactSidebarEdge: Sendable, Equatable {
    case leading
    case trailing
}

/// Every reason the chrome may be showing while compact mode says it should be
/// hidden.
///
/// Modelled as a set rather than a boolean because the reasons overlap and
/// arrive from unrelated places -- the pointer is over the strip *and* a
/// context menu is open *and* the command bar has focus -- and the chrome must
/// stay up until the last of them goes away. A single `isRevealed` flag turns
/// every one of those overlaps into a race that ends with the sidebar stuck
/// open or snapping shut under the user's cursor.
struct CompactRevealReason: OptionSet, Sendable, Equatable {
    let rawValue: Int

    init(rawValue: Int) { self.rawValue = rawValue }

    /// The pointer is inside the hover target.
    static let pointerHover = Self(rawValue: 1 << 0)
    /// A drag is hovering it. Separate from `pointerHover` because AppKit
    /// delivers dragging-destination callbacks instead of mouse-tracking ones
    /// during a drag, so the two can never be collapsed into one trigger.
    static let dragHover = Self(rawValue: 1 << 1)
    /// The user asked for the chrome to stay put. Not a hover, and not subject
    /// to the hover gate or to any grace period.
    static let userShow = Self(rawValue: 1 << 2)
    /// A context menu or pop-up button is open over the chrome.
    static let popupMenu = Self(rawValue: 1 << 3)
    /// The command bar is open. Kylmora gets this trigger for free, because
    /// the command bar is already a first-class piece of state rather than a
    /// focused descendant.
    static let commandBar = Self(rawValue: 1 << 4)
    /// The active space has no tabs, so hiding the only affordance that can
    /// open one would leave the window with nothing to click.
    static let emptySpace = Self(rawValue: 1 << 5)
    /// A deliberate timed reveal, used to show something that happened while
    /// the chrome was hidden.
    static let flash = Self(rawValue: 1 << 6)
    /// A tab is being dragged within the sidebar.
    static let movingTab = Self(rawValue: 1 << 7)
    /// A tab title is being edited in place.
    static let renamingTab = Self(rawValue: 1 << 8)
    /// The pointer left the window across this element's edge and the
    /// grace timer has not expired yet.
    static let pointerLeftWindow = Self(rawValue: 1 << 9)

    /// The reasons the `show-chrome-on-hover` preference is allowed to veto.
    /// Everything else is either an explicit user action or a state that would
    /// strand the user, and none of those may be switched off by a preference
    /// about hovering.
    static let hoverDriven: Self = [.pointerHover, .dragHover, .pointerLeftWindow]
}

/// Conditions under which compact mode stops hiding anything at all, whatever
/// the preferences say.
struct CompactSuppression: OptionSet, Sendable, Equatable {
    let rawValue: Int

    init(rawValue: Int) { self.rawValue = rawValue }

    /// A page is in HTML fullscreen. The page owns the whole window, and
    /// chrome that reveals itself on a stray mouse move over a video is worse
    /// than no compact mode at all.
    static let pageFullScreen = Self(rawValue: 1 << 0)
    /// The window is in macOS fullscreen. The system already hides the
    /// titlebar and auto-reveals it on an edge push; a second, differently
    /// timed auto-reveal underneath it reads as a bug.
    static let windowFullScreen = Self(rawValue: 1 << 1)
    /// The window is miniaturised. Nothing to lay out, and the hover state
    /// that survives the trip to the Dock would be stale on the way back.
    static let miniaturized = Self(rawValue: 1 << 2)
}

/// Where the window's traffic lights are parented.
///
/// Kylmora's sidebar owns the titlebar strip, which makes
/// "hide the sidebar" mean "hide the close button" unless they are moved. This
/// is the enumeration of the places they can legally live.
enum CompactTrafficLightHost: Sendable, Equatable {
    /// The normal home: the top of the sidebar.
    case sidebar
    /// The sidebar is hidden, so they ride on the bar above the page.
    case toolbar
}

/// What compact mode hides, how fast, and where.
///
/// All of it is data so that the decisions can be argued with in a test rather
/// than inferred from a running window.
struct CompactModeConfiguration: Sendable, Equatable {
    /// The sidebar floats over the page and auto-hides.
    var hidesSidebar = true
    /// The bar above the page collapses to a gutter and auto-hides.
    /// Off by default: most of the value is in the sidebar half,
    /// and a browser with no visible back button surprises people.
    var hidesToolbar = false
    /// Pointer and drag hover reveal the chrome. Turning this off keeps every
    /// other trigger -- a user show, a popup, the command bar -- working.
    var revealsOnHover = true
    /// Animate the reveal, the collapse and the mode toggle itself.
    var animates = true
    /// The system's Reduce Motion setting. Kept separate from `animates` so
    /// that turning the preference on does not overwrite the user's choice
    /// when they turn the accessibility setting back off.
    var reducesMotion = false
    var sidebarEdge: CompactSidebarEdge = .leading

    /// The gap between the floating sidebar plate
    /// and the window edge. The same 8 points as every other gutter.
    var float: CGFloat = Style.Metrics.elementSeparation

    /// How long the sidebar stays up after the pointer leaves it.
    ///
    /// Without it, clipping the corner of the sidebar on the way to a tab
    /// collapses it under the cursor mid-reach. 150 ms is short enough not to
    /// feel sticky and long enough to absorb that.
    var sidebarKeepHover: Double = 0.15
    /// How long the chrome stays up after the pointer leaves the *window*.
    ///
    /// The sidebar could stay open while the pointer is within 200 points of
    /// the window edge by registering an OS-level pointer tracker. That needs
    /// global event monitoring, which needs entitlements Kylmora refuses, so
    /// this is a documented fallback path.
    var hideAfterPointerLeftWindow: Double = 1.0
    /// A deliberate reveal-then-hide.
    var flashDuration: Double = 0.8

    /// Debounce on both the enter and the leave edge, to absorb the jitter a
    /// native tracking area produces when the pointer grazes a boundary.
    var hoverDebounce: Double = 0

    /// Resting sidebar width, floored because a compact sidebar narrower than
    /// 150 points is unreadable, and the splitter that would normally stop
    /// you making it that narrow is not there in compact mode.
    var expandedWidthFloor: CGFloat = Style.Metrics.sidebarMinWidth
    /// Width of a collapsed sidebar in compact mode. Wider than the ordinary
    /// collapsed 60 because the floating plate carries its own padding.
    var collapsedWidth: CGFloat = 74

    init() {}

    /// The configuration with the illegal combination corrected.
    ///
    /// On Kylmora the traffic lights live on the sidebar, so hiding the sidebar
    /// moves them to the toolbar -- which means hiding both would leave the
    /// window with no close button reachable without a keyboard. The fix is
    /// to detect the combination, force it back to hide-sidebar-only, and
    /// disable the menu item rather than silently doing something else than
    /// what it says.
    var resolved: CompactModeConfiguration {
        var copy = self
        if copy.hidesSidebar && copy.hidesToolbar {
            copy.hidesToolbar = false
        }
        return copy
    }

    /// True when `hidesSidebar` and `hidesToolbar` as set cannot both be
    /// honoured. The menu item for "hide both" reads this to disable itself.
    var isIllegal: Bool { hidesSidebar && hidesToolbar }
}

/// A compact-mode transition, and the motion that belongs to it.
///
/// Reveal and collapse are deliberately asymmetric -- the reveal is slower and
/// overshoots, the collapse is quick and flat. That asymmetry is what makes the
/// sidebar feel like it is coming to meet you and getting out of the way, and
/// symmetric timing reads as sluggish in one direction or twitchy in the other.
enum CompactTransition: Sendable, Equatable {
    /// Apply immediately. Used for startup restore, for window resizes and
    /// whenever motion is reduced.
    case immediate
    case reveal
    case collapse
    /// Compact mode was switched on.
    case enter
    /// Compact mode was switched off.
    case exit

    var duration: Double {
        switch self {
        case .immediate: 0
        case .reveal: 0.25
        case .collapse: 0.15
        case .enter, .exit: 0.12
        }
    }

    var curve: CompactTimingCurve {
        switch self {
        case .immediate: .linear
        case .reveal: .revealSpring
        case .collapse: .ease
        case .enter: .easeIn
        case .exit: .easeOut
        }
    }
}

/// The easing curves compact mode uses, named rather than expressed as control
/// points so that the sampled spring can sit alongside the standard ones.
enum CompactTimingCurve: Sendable, Equatable {
    case linear
    case ease
    case easeIn
    case easeOut
    /// The 101-stop sampled spring reconstructed in `CompactRevealCurve`.
    case revealSpring
}

/// Where every piece of compact chrome should be right now.
///
/// The state machine produces one of these and the views apply it. Keeping the
/// geometry in a value means the hard part -- which of nine overlapping reveal
/// reasons wins, and what the offsets are when the sidebar is collapsed and
/// docked right -- is testable without a window.
struct CompactPresentation: Sendable, Equatable {
    /// The sidebar is out of the split view and floating over the page.
    var sidebarIsFloating: Bool
    /// Horizontal offset of the floating sidebar from its docked edge, in
    /// points, positive meaning "pushed out of the window".
    ///
    /// The sign convention here is the distance travelled rather than a
    /// coordinate, so it reads the same for both edges and the edge choice
    /// stays in one place.
    var sidebarPushOut: CGFloat
    /// Width the floating plate is laid out at.
    var sidebarWidth: CGFloat
    /// Height of the bar above the page.
    var toolbarHeight: CGFloat
    /// Opacity of the bar's contents. Separate from the height because the
    /// contents fade faster than the strip collapses, so the controls never
    /// render squashed.
    var toolbarOpacity: CGFloat
    var trafficLightHost: CompactTrafficLightHost
}

/// The compact-mode state machine.
///
/// Pure, and deliberately so: it is fed events and measurements and answers
/// with geometry. Everything that makes compact mode hard to get right --
/// overlapping reveal reasons, the two independent halves, the interaction with
/// an already-collapsed sidebar, the illegal state -- is decided here, where it
/// can be tested, instead of inside a tracking-area callback where it cannot.
struct CompactModeState: Sendable, Equatable {
    /// The master switch.
    var isEnabled = false
    var configuration = CompactModeConfiguration()
    var suppressions: CompactSuppression = []
    var sidebarReasons: CompactRevealReason = []
    var toolbarReasons: CompactRevealReason = []

    /// Measured resting width of the sidebar, before the compact floor is
    /// applied. Written from the split view so an offscreen sidebar is pushed
    /// exactly its own width and not a guess at it.
    var measuredSidebarWidth: CGFloat = Style.Metrics.sidebarWidth

    /// The *other* axis: the persistent narrow/wide sidebar state.
    ///
    /// Collapsed and compact are independent axes. A collapsed sidebar in
    /// compact mode is a slim strip that disappears entirely until hovered,
    /// which is a different and legitimate state from either one alone --
    /// and folding them into a single three-way mode, which is the obvious
    /// simplification, makes that state unreachable.
    var isSidebarCollapsed = false

    init() {}

    /// Compact mode is on and nothing is suppressing it.
    var isActive: Bool { isEnabled && suppressions.isEmpty }

    /// The corrected configuration. Nothing downstream reads the raw one.
    var effectiveConfiguration: CompactModeConfiguration { configuration.resolved }

    var hidesSidebar: Bool { isActive && effectiveConfiguration.hidesSidebar }
    var hidesToolbar: Bool { isActive && effectiveConfiguration.hidesToolbar }

    /// Filters out the reveal reasons the hover preference vetoes.
    private func honoured(_ reasons: CompactRevealReason) -> CompactRevealReason {
        effectiveConfiguration.revealsOnHover ? reasons : reasons.subtracting(.hoverDriven)
    }

    var sidebarIsRevealed: Bool {
        guard hidesSidebar else { return true }
        return !honoured(sidebarReasons).isEmpty
    }

    var toolbarIsRevealed: Bool {
        guard hidesToolbar else { return true }
        return !honoured(toolbarReasons).isEmpty
    }

    /// The width the floating plate is laid out at.
    var floatingSidebarWidth: CGFloat {
        let config = effectiveConfiguration
        return isSidebarCollapsed
            ? config.collapsedWidth
            : max(measuredSidebarWidth, config.expandedWidthFloor)
    }

    /// How far offscreen a hidden sidebar sits.
    ///
    /// Not the full width: `float / 2 + 1` points are left on screen and that
    /// sliver is the hover target. It has to stay inside the window, because a
    /// tracking area on a view that is entirely outside its window's bounds
    /// receives nothing, and an invisible strip pinned to the window edge as a
    /// second, separate hover target would then have to be kept in sync with
    /// the sidebar's own -- two things to get wrong instead of one.
    var hiddenPushOut: CGFloat {
        floatingSidebarWidth - revealedPushOut - 1
    }

    /// A revealed sidebar sits half the float *outside* the window edge, so the
    /// plate's rounded corner and its shadow read as floating rather than as a
    /// panel butted against the frame.
    var revealedPushOut: CGFloat { effectiveConfiguration.float / 2 }

    /// Height of the collapsed toolbar strip: the universal gutter, so the
    /// page's top edge keeps the same margin it has everywhere else.
    var collapsedToolbarHeight: CGFloat { Style.Metrics.elementSeparation }

    var presentation: CompactPresentation {
        let sidebarFloating = hidesSidebar
        let revealed = sidebarIsRevealed
        return CompactPresentation(
            sidebarIsFloating: sidebarFloating,
            sidebarPushOut: sidebarFloating ? (revealed ? revealedPushOut : hiddenPushOut) : 0,
            sidebarWidth: sidebarFloating ? floatingSidebarWidth : measuredSidebarWidth,
            toolbarHeight: toolbarIsRevealed
                ? Style.Metrics.topBarHeight
                : collapsedToolbarHeight,
            toolbarOpacity: toolbarIsRevealed ? 1 : 0,
            // The lights follow the chrome that is still on screen. When the
            // sidebar floats they cannot ride on it: it is offscreen most of
            // the time, and traffic lights that slide away with it are worse
            // than none.
            trafficLightHost: sidebarFloating ? .toolbar : .sidebar
        )
    }

    /// The motion that belongs to a change from `old` to `self`.
    ///
    /// Derived rather than passed in, because the caller that adds a reveal
    /// reason does not know whether it was the first one -- and "animate only
    /// if this was the transition that actually moved something" is precisely
    /// the condition that gets forgotten and produces a re-triggered 0.25 s
    /// spring on every mouse move inside the sidebar.
    func transition(from old: CompactModeState) -> CompactTransition {
        let config = effectiveConfiguration
        guard config.animates, !config.reducesMotion else { return .immediate }
        if old.isActive != isActive { return isActive ? .enter : .exit }
        guard presentation != old.presentation else { return .immediate }
        let revealing = (sidebarIsRevealed && !old.sidebarIsRevealed)
            || (toolbarIsRevealed && !old.toolbarIsRevealed)
        return revealing ? .reveal : .collapse
    }
}
