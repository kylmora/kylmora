import AppKit

/// The sidebar's home in the window, from compact mode's point of view.
///
/// A protocol because the split view belongs to the window controller and
/// compact mode may not reach into it. It also makes the awkward half -- taking
/// a view controller out of an `NSSplitViewController` and putting it back at
/// the width it had -- something a test can stand in for.
@MainActor
protocol CompactSidebarSlot: AnyObject {
    /// The width the sidebar rests at, read before it is taken out so it can
    /// be put back at the same size.
    var restingSidebarWidth: CGFloat { get }
    /// Takes the sidebar out of the layout and hands over its view controller.
    /// The caller becomes responsible for parenting it.
    func detachSidebar() -> NSViewController
    /// Puts it back where it was.
    func reattachSidebar(_ controller: NSViewController)
}

/// Everything compact mode does to a window, behind one object.
///
/// The window controller owns one of these and tells it about four things:
/// the mode being toggled, the sidebar being collapsed, the command bar
/// opening, and the window losing key. Everything else -- hover, drag hover,
/// the timers, the geometry, the traffic lights -- happens in here.
///
/// It is the `CompactModeHost` for the controller, which means the decision of
/// *what* the chrome should look like and the work of *making* it look that way
/// stay in different files. That separation is what keeps the state machine
/// testable: none of the code below appears in a test, and none of the code it
/// implements needs to.
@MainActor
final class CompactChrome: CompactModeHost {

    let controller: CompactModeController

    private weak var slot: (any CompactSidebarSlot)?
    private weak var contentView: NSView?
    private weak var toolbarView: NSView?
    private let overlay: CompactSidebarOverlay
    private let toolbar: CompactToolbarCollapse?
    private let trafficLights: CompactTrafficLights?
    /// Where the window's lights are now. The window controller lays the
    /// top bar out around them when they ride on it.
    var onTrafficLightHostChange: ((CompactTrafficLightHost) -> Void)?

    /// The sidebar while it is floating. Held so it can be handed back.
    private var floatingSidebar: NSViewController?
    /// The controller the floating sidebar is a child of while it is out of
    /// the split view. Without a parent it drops out of the responder chain
    /// and the sidebar's own menu items stop validating.
    private weak var floatingParent: NSViewController?

    /// - Parameters:
    ///   - contentView: the view the plate floats over -- the page side of the
    ///     window, not the window's content view, so the plate is clipped to
    ///     the page and cannot stray over the toolbar.
    ///   - toolbarTopConstraint: pins the bar above the page to the card's top
    ///     edge. Nil turns the toolbar half off entirely, which is what a
    ///     caller that has not exposed the constraint gets.
    init(
        slot: any CompactSidebarSlot,
        contentView: NSView,
        toolbarView: NSView?,
        toolbarTopConstraint: NSLayoutConstraint?,
        window: NSWindow?,
        configuration: CompactModeConfiguration = CompactModeConfiguration()
    ) {
        self.slot = slot
        self.contentView = contentView
        self.toolbarView = toolbarView
        self.overlay = CompactSidebarOverlay(edge: configuration.sidebarEdge)
        self.toolbar = toolbarTopConstraint.flatMap { constraint in
            toolbarView.map { CompactToolbarCollapse(topConstraint: constraint, fadingView: $0) }
        }
        self.trafficLights = window.flatMap(CompactTrafficLights.init)
        self.controller = CompactModeController()

        controller.setConfiguration(configuration)
        overlay.onHoverBegan = { [weak self] isDrag in
            self?.controller.hoverBegan(on: .sidebar, isDrag: isDrag)
        }
        overlay.onHoverEnded = { [weak self] isDrag in
            guard let self else { return }
            self.controller.hoverEnded(on: .sidebar, isDrag: isDrag) { [weak self] in
                self?.overlay.containsPointer ?? false
            }
        }
        controller.setHost(self)
    }

    // MARK: - The switch

    /// Turns compact mode on or off.
    ///
    /// Goes through here rather than straight to the controller because the
    /// sidebar's resting width has to be read while it is still in the split
    /// view. Once it has been taken out there is nothing left to measure, and
    /// a hidden sidebar pushed by a default width instead of its own leaves a
    /// strip of plate on screen.
    func setEnabled(_ enabled: Bool, animated: Bool = true) {
        if enabled, let slot {
            controller.setMeasuredSidebarWidth(slot.restingSidebarWidth)
        }
        controller.setEnabled(enabled, animated: animated)
    }

    func toggle() { setEnabled(!controller.state.isEnabled) }

    /// Sets the configuration and updates the overlay edge if needed.
    func setConfiguration(_ configuration: CompactModeConfiguration) {
        overlay.setEdge(configuration.sidebarEdge)
        controller.setConfiguration(configuration)
    }

    /// Updates the sidebar docking edge on the overlay and controller.
    func updateSidebarEdge(_ edge: CompactSidebarEdge) {
        overlay.setEdge(edge)
        var configuration = controller.state.configuration
        configuration.sidebarEdge = edge
        controller.setConfiguration(configuration)
    }

    // MARK: - CompactModeHost

    func compactMode(
        _ controller: CompactModeController,
        apply presentation: CompactPresentation,
        transition: CompactTransition
    ) {
        if presentation.sidebarIsFloating {
            detachIfNeeded(width: presentation.sidebarWidth)
        } else {
            reattachIfNeeded()
        }
        overlay.setWidth(presentation.sidebarWidth)
        overlay.setPushOut(presentation.sidebarPushOut, transition: transition)
        toolbar?.apply(
            height: presentation.toolbarHeight,
            opacity: presentation.toolbarOpacity,
            transition: transition
        )
        trafficLights?.move(to: presentation.trafficLightHost, toolbarView: toolbarView)
        onTrafficLightHostChange?(presentation.trafficLightHost)
    }

    // MARK: - Moving the sidebar in and out of the layout

    private func detachIfNeeded(width: CGFloat) {
        guard floatingSidebar == nil, let slot, let contentView else { return }
        let sidebar = slot.detachSidebar()
        floatingSidebar = sidebar
        floatingParent = contentView.window?.contentViewController
        floatingParent?.addChild(sidebar)

        if overlay.superview == nil {
            overlay.install(in: contentView, float: controller.state.effectiveConfiguration.float)
        }
        overlay.isHidden = false
        overlay.setWidth(width)
        overlay.setContent(sidebar.view)
    }

    private func reattachIfNeeded() {
        guard let sidebar = floatingSidebar, let slot else { return }
        floatingSidebar = nil
        sidebar.removeFromParent()
        overlay.setContent(nil)
        overlay.isHidden = true
        slot.reattachSidebar(sidebar)
    }
}
