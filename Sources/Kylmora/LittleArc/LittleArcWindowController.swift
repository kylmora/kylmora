import AppKit
import Combine
import WebKit

/// One Little Arc window: a page opened from another app, in a small window
/// that appears where the link was clicked rather than on the desktop the
/// browser lives on.
///
/// It is not a tab. Nothing about it reaches the sidebar, the space's tab list
/// or the session file, and closing it discards the page. That is the whole
/// feature: the link is worth one look, and the look should not cost a space
/// switch, a tab the user has to tidy away afterwards, or the page they were
/// reading.
///
/// What it does ask is the one question worth asking -- which space the page
/// belongs to. Keeping it hands the live page to the session (`BrowserSession
/// .adoptLittleArcPage`), so it arrives as a tab where the user left it,
/// scroll position and all, rather than as a reload.
@MainActor
final class LittleArcWindowController: NSWindowController, NSWindowDelegate {
    /// The space this page browses as. Held because the page was loaded in that
    /// space's cookie jar, and that is what decides whether keeping it can move
    /// the live web view or has to load the page again.
    let identity: Space.Identity

    /// Spaces the page may be kept in, built by the coordinator from the
    /// session so this type never names a model type.
    var spaceChoices: (() -> [LittleArcTopBar.SpaceChoice])?

    /// The page is being kept in a real space. The coordinator does the move,
    /// because the session is not this window's to touch.
    var onMove: ((LittleArcWindowController, UUID, WKWebView, URL) -> Void)?

    /// The window closed with the page still in it.
    var onClose: ((LittleArcWindowController) -> Void)?

    /// A `window.open` from inside the page. A popup is the page asking for
    /// somewhere permanent, and a little window is not permanent.
    var onRequestChildTab: ((WKWebViewConfiguration) -> WKWebView?)?

    /// The address the page is actually on.
    ///
    /// The back-forward list's current item rather than `webView.url`, which
    /// names the destination of a load that may not have finished -- the same
    /// rule the omnibox and a glance's address pill follow.
    var pageURL: URL? { webView.backForwardList.currentItem?.url ?? webView.url }

    private let bar = LittleArcTopBar()
    private let webView: WKWebView
    private let pageCoordinator = PageWebCoordinator()
    private var cancellables: Set<AnyCancellable> = []
    private var keyMonitor: Any?
    /// Set before the window closes on a page that has been handed over, so the
    /// teardown below does not tear down what the new tab is now using.
    private var isHandingOff = false

    init(url: URL, identity: Space.Identity) {
        self.identity = identity
        // The space's own configuration, so the page is signed in as the space
        // the user was in and the filter lists, per-site settings and fonts all
        // apply exactly as they would in a tab.
        self.webView = WebEnvironment.shared.makeWebView(identity: identity)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: LittleArcMetrics.size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = LittleArcMetrics.minimumSize
        // Never merged into the main window's tab group: a Little Arc is a
        // separate place, and macOS joining the two would put it in the sidebar
        // by another route.
        window.tabbingMode = .disallowed
        // Dropped on whatever desktop the link was clicked on, and able to sit
        // over a full-screen app, without pulling the user to the space the
        // browser's window lives on -- which is the entire point of the window.
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.setAccessibilityLabel("Little Arc")

        super.init(window: window)

        pageCoordinator.onNewWindow = { [weak self] configuration in
            self?.onRequestChildTab?(configuration)
        }
        webView.navigationDelegate = pageCoordinator
        webView.uiDelegate = pageCoordinator

        bar.onMove = { [weak self] spaceID in self?.keep(in: spaceID) }
        bar.onReload = { [weak self] in self?.reloadOrStop() }
        buildContent(of: window)
        observePage()
        window.delegate = self
        webView.load(URLRequest(url: url))
    }

    required init?(coder: NSCoder) {
        fatalError("LittleArcWindowController is created in code only")
    }

    // MARK: - Construction

    private func buildContent(of window: NSWindow) {
        let container = NSView()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bar)
        container.addSubview(webView)
        window.contentView = container

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            webView.topAnchor.constraint(equalTo: bar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    private func observePage() {
        webView.publisher(for: \.url, options: [.initial, .new])
            .sink { [weak self] _ in self?.updateChrome() }
            .store(in: &cancellables)
        webView.publisher(for: \.title, options: [.initial, .new])
            .sink { [weak self] _ in self?.updateChrome() }
            .store(in: &cancellables)
        webView.publisher(for: \.isLoading, options: [.initial, .new])
            .sink { [weak self] isLoading in self?.bar.setLoading(isLoading) }
            .store(in: &cancellables)
    }

    /// The strip and the window's own title follow the committed page. The
    /// titlebar is hidden, but the window still has a title: that is what
    /// Mission Control, the Window menu and VoiceOver read.
    private func updateChrome() {
        let address = pageURL.map { AddressFormatter.display($0) } ?? ""
        let title = (webView.title?.isEmpty == false ? webView.title : nil) ?? address
        bar.show(title: title, address: address, spaces: spaceChoices?() ?? [])
        bar.showIcon(for: pageURL, in: webView, isPrivate: identity.isPrivate)
        window?.title = title
    }

    // MARK: - Showing and closing

    /// Opens on whichever screen the pointer is on.
    ///
    /// The link was clicked where the user is looking, so that is where the
    /// window has to appear for the feature to mean anything.
    func show() {
        if let screen = Self.screenUnderPointer() {
            window?.setFrame(LittleArcPlacement.frame(in: screen.visibleFrame), display: false)
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        startKeyMonitor()
    }

    private static func screenUnderPointer() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
    }

    override func close() {
        stopKeyMonitor()
        // A handed-over page belongs to its new tab now: nil-ing its delegates
        // or stopping the load here would break the tab that just adopted it.
        if !isHandingOff {
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.stopLoading()
        }
        super.close()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?(self)
    }

    // MARK: - Key handling

    /// Command-Return and Command-W, caught rather than left to the menu bar.
    ///
    /// Command-W would otherwise reach the main window's Close Tab item, which
    /// names a tab this window does not have; Command-Return has no menu item
    /// at all. Both are scoped to this window being key, so a little window
    /// cannot swallow a keystroke meant for the browser.
    private func startKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers == .command else { return event }

            switch event.keyCode {
            case 36, 76: // Return, and the numeric keypad's Enter.
                self.keepInOwnerSpace()
                return nil
            case 13: // W.
                self.window?.performClose(nil)
                return nil
            default:
                break
            }

            // Command-1 through Command-9 moves to that space immediately
            if let chars = event.charactersIgnoringModifiers,
               let first = chars.first,
               let digit = first.wholeNumberValue,
               digit >= 1 && digit <= 9 {
                self.keepInSpace(at: digit - 1)
                return nil
            }

            return event
        }
    }

    /// Keeps the page in the space at the given index (0-based, corresponding to ⌘1..⌘9).
    func keepInSpace(at index: Int) {
        guard bar.choices.indices.contains(index) else { return }
        keep(in: bar.choices[index].id)
    }

    private func stopKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func reloadOrStop() {
        if webView.isLoading {
            webView.stopLoading()
        } else {
            webView.reload()
        }
    }

    // MARK: - Keeping the page

    /// Keeps the page in the space it is already signed in to.
    func keepInOwnerSpace() {
        guard let owner = bar.ownerSpaceID else { return }
        keep(in: owner)
    }

    private func keep(in spaceID: UUID) {
        guard !isHandingOff, let url = pageURL else { return }
        // Checked against the choices that were actually offered, so a space
        // that was removed while the window was open cannot be kept into.
        guard bar.choices.contains(where: { $0.id == spaceID }) else { return }

        isHandingOff = true
        onMove?(self, spaceID, webView, url)
        window?.performClose(nil)
    }
}
