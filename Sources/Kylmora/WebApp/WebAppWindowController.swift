import AppKit
import Combine
import WebKit

/// A standalone chromeless window hosting a single Web App (SSB).
/// Delivers an app-like experience with its own window, full content blocking,
/// Boosts, dark mode, and seamless integration back to Kylmora.
@MainActor
final class WebAppWindowController: NSWindowController, NSWindowDelegate {
    let app: InstalledWebApp
    let identity: Space.Identity

    var onOpenInBrowser: ((URL) -> Void)?
    var onClose: ((WebAppWindowController) -> Void)?
    var onRequestChildTab: ((WKWebViewConfiguration) -> WKWebView?)?

    var pageURL: URL? { webView.backForwardList.currentItem?.url ?? webView.url ?? app.url }

    let bar = WebAppTopBar()
    let webView: WKWebView
    private let pageCoordinator = PageWebCoordinator()
    private var cancellables: Set<AnyCancellable> = []
    private var keyMonitor: Any?

    init(app: InstalledWebApp, identity: Space.Identity = .standard) {
        self.app = app
        self.identity = identity
        self.webView = WebEnvironment.shared.makeWebView(identity: identity)

        let initialSize = NSSize(width: 1040, height: 720)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = app.name
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 320)
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("KylmoraWebApp_\(app.id.uuidString)")

        super.init(window: window)

        pageCoordinator.onNewWindow = { [weak self] configuration in
            self?.onRequestChildTab?(configuration)
        }
        webView.navigationDelegate = pageCoordinator
        webView.uiDelegate = pageCoordinator

        setupTopBarActions()
        buildContent(of: window)
        observePage()

        window.delegate = self
        webView.load(URLRequest(url: app.url))
    }

    required init?(coder: NSCoder) {
        fatalError("WebAppWindowController is created in code only")
    }

    private func setupTopBarActions() {
        bar.onBack = { [weak self] in self?.webView.goBack() }
        bar.onForward = { [weak self] in self?.webView.goForward() }
        bar.onReload = { [weak self] in self?.reloadOrStop() }
        bar.onToggleDarkMode = { [weak self] in self?.toggleDarkMode() }
        bar.onOpenInBrowser = { [weak self] in
            guard let self, let url = self.pageURL else { return }
            self.onOpenInBrowser?(url)
        }
        bar.onMoreAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case "zoom-in": self.zoomIn()
            case "zoom-out": self.zoomOut()
            case "zoom-reset": self.zoomReset()
            case "boost": self.openBoostEditor()
            case "copy-url": self.copyCurrentURL()
            case "reveal-finder": self.revealInFinder()
            default: break
            }
        }
    }

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
        webView.publisher(for: \.canGoBack, options: [.initial, .new])
            .sink { [weak self] _ in self?.updateChrome() }
            .store(in: &cancellables)
        webView.publisher(for: \.canGoForward, options: [.initial, .new])
            .sink { [weak self] _ in self?.updateChrome() }
            .store(in: &cancellables)
        webView.publisher(for: \.isLoading, options: [.initial, .new])
            .sink { [weak self] _ in self?.updateChrome() }
            .store(in: &cancellables)
    }

    private func updateChrome() {
        let currentURL = pageURL
        let title = (webView.title?.isEmpty == false ? webView.title : nil) ?? app.name
        let isDark: Bool
        if let host = currentURL?.host?.lowercased() {
            isDark = BoostStore.shared.boost(for: host)?.isDarkModeEnabled ?? false
        } else {
            isDark = false
        }

        bar.update(
            title: title,
            url: currentURL,
            canGoBack: webView.canGoBack,
            canGoForward: webView.canGoForward,
            isLoading: webView.isLoading,
            isDark: isDark
        )
        bar.showIcon(for: currentURL, in: webView, isPrivate: identity.isPrivate)
        window?.title = title
    }

    func show() {
        if window?.frame.origin == .zero {
            window?.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        startKeyMonitor()
    }

    override func close() {
        stopKeyMonitor()
        super.close()
        onClose?(self)
    }

    func windowWillClose(_ notification: Notification) {
        stopKeyMonitor()
        onClose?(self)
    }

    // MARK: - Actions

    func reloadOrStop() {
        if webView.isLoading {
            webView.stopLoading()
        } else {
            webView.reload()
        }
    }

    func toggleDarkMode() {
        guard let host = pageURL?.host?.lowercased() else { return }
        let isNowDark = BoostStore.shared.toggleDarkMode(for: host)
        if let boost = BoostStore.shared.boost(for: host) {
            BoostCoordinator.shared.applyLive(boost: boost, to: webView)
        } else {
            let temp = Boost(host: host, isDarkModeEnabled: isNowDark)
            BoostCoordinator.shared.applyLive(boost: temp, to: webView)
        }
        updateChrome()
    }

    func zoomIn() {
        webView.pageZoom = min(3.0, webView.pageZoom + 0.1)
    }

    func zoomOut() {
        webView.pageZoom = max(0.5, webView.pageZoom - 0.1)
    }

    func zoomReset() {
        webView.pageZoom = 1.0
    }

    func copyCurrentURL() {
        guard let url = pageURL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
    }

    func openBoostEditor() {
        guard let url = pageURL else { return }
        let editor = BoostEditorViewController(url: url, webView: webView)
        window?.contentViewController?.presentAsSheet(editor)
    }

    func revealInFinder() {
        if let path = app.appBundlePath, FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }

    // MARK: - Keyboard shortcuts

    private func startKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // Command shortcuts
            if flags == .command {
                switch event.charactersIgnoringModifiers {
                case "[":
                    if self.webView.canGoBack {
                        self.webView.goBack()
                        return nil
                    }
                case "]":
                    if self.webView.canGoForward {
                        self.webView.goForward()
                        return nil
                    }
                case "r":
                    self.reloadOrStop()
                    return nil
                case "+", "=":
                    self.zoomIn()
                    return nil
                case "-":
                    self.zoomOut()
                    return nil
                case "0":
                    self.zoomReset()
                    return nil
                case "w":
                    self.close()
                    return nil
                default:
                    break
                }
            } else if flags == [.command, .shift] {
                if event.charactersIgnoringModifiers?.lowercased() == "c" {
                    self.copyCurrentURL()
                    return nil
                }
            } else if flags == [.command, .option] {
                if event.charactersIgnoringModifiers?.lowercased() == "d" {
                    self.toggleDarkMode()
                    return nil
                } else if event.charactersIgnoringModifiers?.lowercased() == "e" {
                    self.openBoostEditor()
                    return nil
                }
            }

            return event
        }
    }

    private func stopKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
}
