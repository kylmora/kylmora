import AppKit
import Combine
import WebKit

/// Owns the one open glance: its page, its overlay, its timers, and the state
/// machine that says what any of them are allowed to do next.
///
/// Everything here is plumbing. Every rule is in `GlanceMachine`, which is why
/// this type has no `if isAnimating` and no `guard !closing` anywhere in it.
@MainActor
final class GlanceController {
    /// Called when a glance becomes a real tab. The web view handed over is
    /// live: its content process, its scroll position and its back-forward list
    /// are intact, and the caller is expected to adopt it rather than reload it
    /// (`Tab.init(adopting:identity:)`).
    var onPromote: ((WKWebView, URL, UUID?) -> Void)?

    /// A `window.open` from inside a glance. Routed to a real tab, because a
    /// popup is the page asking for somewhere permanent and a glance is not.
    var onRequestChildTab: ((WKWebViewConfiguration) -> WKWebView?)?

    private var machine = GlanceMachine()
    private let overlay = GlanceOverlayView()

    private weak var host: NSView?
    private var ownerPage: (() -> NSView?)?
    private var identity: (() -> Space.Identity)?

    private var webView: WKWebView?
    private var coordinator: PageWebCoordinator?
    private var focusRelay: GlanceFocusRelay?
    private var cancellables: Set<AnyCancellable> = []

    /// Whether anything inside the glance holds focus, kept current by the
    /// injected focus script. Read synchronously when Escape arrives, which is
    /// why it is cached rather than asked for.
    private var contentHasFocus = false

    private var keyMonitor: Any?
    private var confirmationTask: Task<Void, Never>?

    /// The origin the panel flew out of, kept so the fly-back lands on the same
    /// place the user clicked.
    private var originFrame: CGRect = .zero

    var isOpen: Bool { machine.isOpen }
    /// Expand is only offered once the panel has settled.
    var canPromote: Bool { machine.phase == .open || machine.phase == .awaitingConfirmation }

    init() {
        overlay.onClose = { [weak self] in self?.dismiss(.closeButton) }
        overlay.onPromote = { [weak self] in self?.promote() }
        overlay.onBackdropClick = { [weak self] in self?.dismiss(.clickOutsideCard) }
    }

    /// Wires the controller into the content pane.
    ///
    /// - Parameters:
    ///   - host: the view the overlay covers. Also the coordinate space the
    ///     fly-out origin is converted into.
    ///   - ownerPage: the view showing the page a glance is laid over, which is
    ///     what gets scaled back and dimmed. A closure rather than a reference
    ///     because the visible web view changes with every tab switch.
    ///   - identity: the identity a glanced page loads under. A glance inherits
    ///     the space's, so peeking at a link from a work tab does not quietly
    ///     load it with personal cookies.
    func install(
        in host: NSView,
        ownerPage: @escaping () -> NSView?,
        identity: @escaping () -> Space.Identity
    ) {
        self.host = host
        self.ownerPage = ownerPage
        self.identity = identity

        GlanceLinkMonitor.shared.isGlanceOpen = { [weak self] in self?.isOpen ?? false }
        GlanceLinkMonitor.shared.onOpenGlance = { [weak self] url, origin, source in
            self?.open(url: url, origin: origin, source: source)
        }
    }

    // MARK: - Commands

    func open(url: URL, origin: GlanceOriginHint, source: GlanceSource, ownerTabID: UUID? = nil) {
        guard let host, GlanceInvocation.isPermittedTarget(url) else { return }
        // Window coordinates on the way in, because the callers are web views
        // and menu items that have never heard of the overlay.
        let converted = origin.rect.map { host.convert($0, from: nil) }
        run(machine.open(GlanceRequest(url: url, origin: converted, source: source, ownerTabID: ownerTabID)))
    }

    func dismiss(_ reason: GlanceDismissal) {
        run(machine.dismiss(reason))
    }

    func promote() {
        run(machine.promote())
    }

    /// Escape, wherever the focus is. Separated from `dismiss` because only
    /// this path consults the focus guard.
    private func escapePressed() {
        dismiss(.escapeKey(contentHasFocus: contentHasFocus))
    }

    // MARK: - Effects

    private func run(_ effects: [GlanceEffect]) {
        for effect in effects {
            switch effect {
            case .loadPage(let request):
                loadPage(request)
            case .animateOpen(let request):
                animateOpen(request)
            case .armConfirmation(let window):
                armConfirmation(window)
            case .disarmConfirmation:
                confirmationTask?.cancel()
                confirmationTask = nil
                overlay.setConfirmationArmed(false)
            case .animateClose(let animated):
                animateClose(animated: animated)
            case .teardown:
                teardown()
            case .animatePromotion:
                animatePromotion()
            case .handOffWebView(let request):
                handOff(request)
            }
        }
    }

    private func loadPage(_ request: GlanceRequest) {
        guard let identity = identity?() else { return }

        let configuration = WebEnvironment.shared.makeConfiguration(for: identity)
        let relay = GlanceFocusRelay(controller: self)
        configuration.userContentController.add(
            relay, contentWorld: .defaultClient, name: GlanceScripts.focusHandlerName
        )
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: GlanceScripts.focusSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                in: .defaultClient
            )
        )
        focusRelay = relay

        let webView = WebEnvironment.shared.makeWebView(configuration: configuration)
        // The same delegate a Little Arc window's page runs on: a glance and a
        // little window answer a download and a `window.open` the same way.
        let coordinator = PageWebCoordinator { [weak self] configuration in
            self?.makeChildWebView(with: configuration)
        }
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        self.coordinator = coordinator
        self.webView = webView

        contentHasFocus = false
        overlay.setPage(webView)
        overlay.showAddress(request.url)
        observe(webView, fallback: request.url)
        webView.load(URLRequest(url: request.url))
    }

    /// The address pill follows the committed page for exactly the reason the
    /// omnibox does: `WKWebView.url` names the destination of a load the
    /// moment it starts, so a glanced page could otherwise put any address it
    /// liked under the lock while showing its own content.
    private func observe(_ webView: WKWebView, fallback: URL) {
        cancellables.removeAll()
        webView.publisher(for: \.url, options: [.initial, .new])
            .sink { [weak self, weak webView] _ in
                guard let self, let webView else { return }
                self.overlay.showAddress(webView.backForwardList.currentItem?.url ?? fallback)
            }
            .store(in: &cancellables)
    }

    private func animateOpen(_ request: GlanceRequest) {
        guard let host else { return }
        if overlay.superview !== host {
            overlay.frame = host.bounds
            overlay.autoresizingMask = [.width, .height]
            host.addSubview(overlay)
        }
        overlay.layoutSubtreeIfNeeded()

        originFrame = GlanceGeometry.originFrame(for: request.origin, in: overlay.bounds)
        let animated = !GlanceGeometry.prefersReducedMotion
        setOwnerScaled(true, animated: animated)
        overlay.present(from: originFrame, animated: animated) { [weak self] in
            self?.run(self?.machine.openingFinished() ?? [])
        }
        startKeyMonitor()
    }

    private func animateClose(animated: Bool) {
        let animated = animated && !GlanceGeometry.prefersReducedMotion
        setOwnerScaled(false, animated: animated)
        overlay.dismiss(to: originFrame, animated: animated) { [weak self] in
            self?.run(self?.machine.closingFinished() ?? [])
        }
    }

    private func animatePromotion() {
        let animated = !GlanceGeometry.prefersReducedMotion
        setOwnerScaled(false, animated: animated)
        overlay.growToFull(animated: animated) { [weak self] in
            self?.run(self?.machine.promotionFinished() ?? [])
        }
    }

    private func armConfirmation(_ window: TimeInterval) {
        overlay.setConfirmationArmed(true)
        confirmationTask?.cancel()
        confirmationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(window))
            guard !Task.isCancelled, let self else { return }
            self.run(self.machine.confirmationLapsed())
        }
    }

    /// Dismissal destroys the page.
    ///
    /// No `interactionState` is captured and nothing is kept to resume from: a
    /// glance is a look, not a tab, and its tab is removed outright for the
    /// same reason. Keeping it would mean either a hidden tab holding a content
    /// process nobody can see, or a restore path for something that was never
    /// persisted in the first place.
    private func teardown() {
        stopKeyMonitor()
        confirmationTask?.cancel()
        confirmationTask = nil
        cancellables.removeAll()
        setOwnerScaled(false, animated: false)

        if let webView {
            detachScripts(from: webView)
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.stopLoading()
        }
        _ = overlay.releasePage()
        webView = nil
        coordinator = nil
        focusRelay = nil
        contentHasFocus = false
        overlay.removeFromSuperview()
    }

    /// Promotion: the page leaves with everything it has.
    ///
    /// The glance's own delegates and scripts come off first so the adopting
    /// `Tab` finds a clean web view, and the overlay is dismantled around the
    /// page rather than over it -- nothing calls `stopLoading`, nothing
    /// captures `interactionState`, nothing reloads.
    private func handOff(_ request: GlanceRequest) {
        stopKeyMonitor()
        cancellables.removeAll()
        setOwnerScaled(false, animated: false)

        guard let webView else { teardown(); return }
        detachScripts(from: webView)
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        _ = overlay.releasePage()
        overlay.removeFromSuperview()

        let committed = webView.backForwardList.currentItem?.url ?? request.url
        self.webView = nil
        coordinator = nil
        focusRelay = nil
        contentHasFocus = false
        onPromote?(webView, committed, request.ownerTabID)
    }

    /// `WKUserContentController` holds its message handlers strongly, so a
    /// handler that is not removed outlives the glance and keeps this
    /// controller alive with it.
    private func detachScripts(from webView: WKWebView) {
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: GlanceScripts.focusHandlerName, contentWorld: .defaultClient
        )
    }

    /// Scales and leaves the page behind to the dim the overlay draws. A
    /// layer-backed `NSView` anchors at its centre, so a plain scale is already
    /// about the middle of the page.
    private func setOwnerScaled(_ scaled: Bool, animated: Bool) {
        guard let page = ownerPage?() else { return }
        page.wantsLayer = true
        let scale = scaled ? GlanceGeometry.ownerScale : 1
        let transform = CATransform3DMakeScale(scale, scale, 1)
        guard animated else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            page.layer?.transform = transform
            CATransaction.commit()
            return
        }
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = page.layer?.presentation()?.transform ?? page.layer?.transform
        animation.toValue = transform
        animation.duration = GlanceGeometry.animationDuration
        animation.timingFunction = CAMediaTimingFunction(
            controlPoints: GlanceGeometry.closeCurve.0, GlanceGeometry.closeCurve.1,
            GlanceGeometry.closeCurve.2, GlanceGeometry.closeCurve.3
        )
        page.layer?.transform = transform
        page.layer?.add(animation, forKey: "glance.ownerScale")
    }

    // MARK: - Keyboard

    /// Escape and Cmd-O are caught with a local monitor rather than through the
    /// responder chain, because the first responder while a glance is open is
    /// the glanced `WKWebView` and a web view consumes both.
    private func startKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isOpen else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53, modifiers.isEmpty {
                self.escapePressed()
                return nil
            }
            if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "o" {
                self.promote()
                return nil
            }
            return event
        }
    }

    private func stopKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    // MARK: - Called back by the web view

    fileprivate func setContentHasFocus(_ hasFocus: Bool) {
        contentHasFocus = hasFocus
    }

    fileprivate func makeChildWebView(with configuration: WKWebViewConfiguration) -> WKWebView? {
        onRequestChildTab?(configuration)
    }
}

/// Relays the focus script's messages. A separate object because
/// `WKUserContentController` retains its handlers, and a retained
/// `GlanceController` would outlive every glance it ever opened.
private final class GlanceFocusRelay: NSObject, WKScriptMessageHandler {
    private weak var controller: GlanceController?

    init(controller: GlanceController) {
        self.controller = controller
    }

    @MainActor
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == GlanceScripts.focusHandlerName,
              let hasFocus = message.body as? Bool else { return }
        controller?.setContentHasFocus(hasFocus)
    }
}
