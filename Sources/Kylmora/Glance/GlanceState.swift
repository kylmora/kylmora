import Foundation

/// Where a glance came from. Only `.link` carries an element rectangle, so this
/// is also what decides whether the overlay flies out of something or grows
/// from the centre of the page.
enum GlanceSource: Equatable, Sendable {
    /// Modifier-click on a link in the page.
    case link
    /// The page's own context menu, "Open Link in Glance".
    case contextMenu
    /// A bookmark or a command-bar result opened with the glance modifier.
    case command
    /// An off-site link out of a tab that is on a pinned site.
    case pinnedSiteExternalLink
}

/// Everything needed to open one glance.
///
/// `origin` is in the coordinate space of the view the overlay is installed in.
/// It is nil when the caller has no element to fly out of (a bookmark, a
/// command-bar result), which the geometry turns into a zero-size rectangle at
/// the centre rather than into "no animation": the overlay should still read as
/// arriving from somewhere.
struct GlanceRequest: Equatable, Sendable {
    let url: URL
    let origin: CGRect?
    let source: GlanceSource
    /// The tab the glance is layered over. Dismissing it restores that tab, and
    /// a promotion inserts the new tab immediately after it.
    let ownerTabID: UUID?

    init(url: URL, origin: CGRect? = nil, source: GlanceSource, ownerTabID: UUID? = nil) {
        self.url = url
        self.origin = origin
        self.source = source
        self.ownerTabID = ownerTabID
    }
}

/// Why a glance is being taken down.
///
/// The distinction that matters is `isForced`: a tab closing or the application
/// quitting cannot be refused, so those paths skip both the animation guard and
/// the Escape confirmation. Everything else is a request that the state machine
/// is allowed to turn down.
enum GlanceDismissal: Equatable, Sendable {
    case escapeKey(contentHasFocus: Bool)
    case closeButton
    case clickOutsideCard
    /// A different tab or space became active under the glance.
    case selectionChanged
    case ownerTabClosed
    case applicationQuitting

    var isForced: Bool {
        switch self {
        case .ownerTabClosed, .applicationQuitting: true
        default: false
        }
    }

    /// Moving the selection elsewhere skips the animation: the page the
    /// glance was covering is already gone, so flying the panel back onto it
    /// would animate towards the wrong thing.
    var isAnimated: Bool {
        switch self {
        case .selectionChanged, .ownerTabClosed, .applicationQuitting: false
        default: true
        }
    }

    /// Only a reflex Escape is worth a confirmation. A deliberate click on the
    /// close button is already the confirmation.
    var needsConfirmation: Bool {
        if case .escapeKey(let hasFocus) = self { return hasFocus }
        return false
    }
}

enum GlancePhase: Equatable, Sendable {
    case closed
    case opening
    case open
    /// One Escape has been pressed with something focused inside the page. A
    /// second one, or the close button, within the confirmation window closes.
    case awaitingConfirmation
    case closing
    /// Growing to full size on the way to becoming a real tab.
    case promoting
}

/// What the machine asks the world to do. Every one of these is a side effect
/// the controller performs; none of them feed back into the machine except
/// through an explicit event, which is what keeps the rules below testable
/// without a window on screen.
enum GlanceEffect: Equatable, Sendable {
    /// Build the web view and start the load.
    case loadPage(GlanceRequest)
    case animateOpen(GlanceRequest)
    /// Flash the close button and start the confirmation countdown.
    case armConfirmation(TimeInterval)
    case disarmConfirmation
    case animateClose(animated: Bool)
    /// Destroy the web view and remove the overlay. Never emitted on the
    /// promotion path, where the page is handed on rather than thrown away.
    case teardown
    case animatePromotion
    /// Give the live web view to a new tab. The overlay is dismantled around
    /// it; the page itself is not touched, so nothing reloads and nothing
    /// scrolls back to the top.
    case handOffWebView(GlanceRequest)
}

/// The whole of glance's behaviour, with no view, no timer and no web view in
/// sight.
///
/// A typical manager carries six boolean flags (`_animating`, `animatingOpen`,
/// `animatingFullOpen`, `closingGlance`, `#duringOpening`, `#ignoreClose`) that
/// exist only because its phases are implicit. Making the phase the state
/// instead means the rules that read those flags -- no nesting, no dismissal
/// mid-animation, the Escape guard, and a promotion that must not destroy the
/// page -- are each one line here and one test there.
struct GlanceMachine: Equatable, Sendable {
    /// Long enough to be a deliberate second press, short enough that the armed
    /// close button is not still waiting when the user has moved on. The value
    /// is kept because the number is the whole point of the feature.
    static let confirmationWindow: TimeInterval = 3

    private(set) var phase: GlancePhase = .closed
    private(set) var request: GlanceRequest?

    var isOpen: Bool { phase != .closed }

    /// True while an animation owns the overlay, which is when a dismissal that
    /// can be refused is refused.
    private var isAnimating: Bool {
        phase == .opening || phase == .closing || phase == .promoting
    }

    mutating func open(_ request: GlanceRequest) -> [GlanceEffect] {
        // Glances do not nest: a second one while one is up is simply the
        // first one; there is one slot.
        guard phase == .closed else { return [] }
        self.request = request
        phase = .opening
        return [.loadPage(request), .animateOpen(request)]
    }

    /// Idempotent, because it is driven both by the animation's completion
    /// handler and by a watchdog: a completion handler that never arrives must
    /// not leave the overlay permanently unclosable.
    mutating func openingFinished() -> [GlanceEffect] {
        guard phase == .opening else { return [] }
        phase = .open
        return []
    }

    mutating func dismiss(_ reason: GlanceDismissal) -> [GlanceEffect] {
        guard phase != .closed else { return [] }

        if reason.isForced {
            phase = .closed
            request = nil
            return [.disarmConfirmation, .teardown]
        }

        // Refusing a dismissal mid-flight is what stops a double Escape during
        // the open animation from tearing down a half-built overlay.
        guard !isAnimating else { return [] }

        if phase == .open, reason.needsConfirmation {
            phase = .awaitingConfirmation
            return [.armConfirmation(Self.confirmationWindow)]
        }

        phase = .closing
        return [.disarmConfirmation, .animateClose(animated: reason.isAnimated)]
    }

    /// The confirmation window elapsed with no second press, so the glance goes
    /// back to being simply open and the next Escape starts the guard again.
    mutating func confirmationLapsed() -> [GlanceEffect] {
        guard phase == .awaitingConfirmation else { return [] }
        phase = .open
        return [.disarmConfirmation]
    }

    mutating func closingFinished() -> [GlanceEffect] {
        guard phase == .closing else { return [] }
        phase = .closed
        request = nil
        return [.teardown]
    }

    /// Expand: the glance becomes a real tab.
    mutating func promote() -> [GlanceEffect] {
        guard phase == .open || phase == .awaitingConfirmation else { return [] }
        phase = .promoting
        return [.disarmConfirmation, .animatePromotion]
    }

    /// The one asymmetry in the machine, and the one that looks wrong on
    /// purpose: promotion ends in `.closed` like a dismissal, but emits
    /// `handOffWebView` instead of `teardown`. The page survives; only the
    /// overlay around it goes away.
    mutating func promotionFinished() -> [GlanceEffect] {
        guard phase == .promoting, let request else { return [] }
        phase = .closed
        self.request = nil
        return [.handOffWebView(request)]
    }
}
