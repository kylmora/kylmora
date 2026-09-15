import AppKit
import Combine
import WebKit

/// A sleek, always-on-top floating window for web panels or detached web content.
@MainActor
public final class FloatingWebWindowController: NSWindowController, NSWindowDelegate {
    public var onDockBack: ((WKWebView, WebPanel?) -> Void)?
    public var onClose: ((FloatingWebWindowController) -> Void)?

    private let topBar: FloatingTopBarView
    private(set) var webView: WKWebView
    private(set) var panel: WebPanel?
    private var cancellables: Set<AnyCancellable> = []
    private var isDockingBack = false

    public var isAlwaysOnTop: Bool {
        get { window?.level == .floating }
        set {
            window?.level = newValue ? .floating : .normal
            topBar.setPinned(newValue)
        }
    }

    public init(
        webView: WKWebView? = nil,
        url: URL? = nil,
        panel: WebPanel? = nil,
        initialSize: NSSize = NSSize(width: 420, height: 600)
    ) {
        self.panel = panel

        let effectiveWebView: WKWebView
        if let existing = webView {
            effectiveWebView = existing
        } else {
            effectiveWebView = WebEnvironment.shared.makeWebView(identity: .standard)
            if let targetURL = url ?? panel?.url {
                if targetURL.scheme == "kylmora" && (targetURL.host == "scratchpad" || targetURL.host == "notes") {
                    effectiveWebView.loadHTMLString(ScratchpadContent.html, baseURL: nil)
                } else {
                    effectiveWebView.load(URLRequest(url: targetURL))
                }
            }
        }
        self.webView = effectiveWebView

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 300, height: 320)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.level = .floating

        self.topBar = FloatingTopBarView()

        super.init(window: window)
        window.delegate = self

        buildUI(in: window)
        wireActions()
        observeWebView()

        if !window.setFrameUsingName("KylmoraFloatingWebWindow") {
            window.center()
        }
        window.setFrameAutosaveName("KylmoraFloatingWebWindow")
        topBar.setPinned(true)
    }

    required init?(coder: NSCoder) {
        fatalError("FloatingWebWindowController is created in code only")
    }

    private func buildUI(in window: NSWindow) {
        let container = NSView()
        container.wantsLayer = true
        topBar.translatesAutoresizingMaskIntoConstraints = false
        webView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(topBar)
        container.addSubview(webView)
        window.contentView = container

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: container.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            webView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    private func wireActions() {
        topBar.onBack = { [weak self] in self?.webView.goBack() }
        topBar.onForward = { [weak self] in self?.webView.goForward() }
        topBar.onReloadOrStop = { [weak self] in
            guard let self else { return }
            if self.webView.isLoading {
                self.webView.stopLoading()
            } else {
                self.webView.reload()
            }
        }
        topBar.onTogglePin = { [weak self] in
            guard let self, let window = self.window else { return }
            let newState = window.level != .floating
            self.isAlwaysOnTop = newState
        }
        topBar.onCycleOpacity = { [weak self] in
            guard let self, let window = self.window else { return }
            let current = window.alphaValue
            if current > 0.9 {
                window.alphaValue = 0.85
            } else if current > 0.75 {
                window.alphaValue = 0.65
            } else {
                window.alphaValue = 1.0
            }
        }
        topBar.onDock = { [weak self] in
            self?.dockBack()
        }
    }

    private func observeWebView() {
        webView.publisher(for: \.title, options: [.initial, .new])
            .sink { [weak self] title in
                let display = title?.isEmpty == false ? title! : (self?.panel?.title ?? "Floating Window")
                self?.topBar.setTitle(display)
                self?.window?.title = display
            }
            .store(in: &cancellables)

        webView.publisher(for: \.isLoading, options: [.initial, .new])
            .sink { [weak self] loading in
                self?.topBar.setLoading(loading)
            }
            .store(in: &cancellables)

        webView.publisher(for: \.canGoBack, options: [.initial, .new])
            .sink { [weak self] canGo in
                self?.topBar.setCanGoBack(canGo)
            }
            .store(in: &cancellables)

        webView.publisher(for: \.canGoForward, options: [.initial, .new])
            .sink { [weak self] canGo in
                self?.topBar.setCanGoForward(canGo)
            }
            .store(in: &cancellables)
    }

    public func dockBack() {
        guard !isDockingBack else { return }
        isDockingBack = true
        onDockBack?(webView, panel)
        close()
    }

    public func windowWillClose(_ notification: Notification) {
        if !isDockingBack {
            onClose?(self)
        }
    }
}

// MARK: - Floating Top Bar

@MainActor
final class FloatingTopBarView: NSView {
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onReloadOrStop: (() -> Void)?
    var onTogglePin: (() -> Void)?
    var onCycleOpacity: (() -> Void)?
    var onDock: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Floating Window")
    private let backButton = IconButton(symbolName: "chevron.left", label: "Back", side: 20)
    private let forwardButton = IconButton(symbolName: "chevron.right", label: "Forward", side: 20)
    private let reloadButton = IconButton(symbolName: "arrow.clockwise", label: "Reload", side: 20)
    private let pinButton = IconButton(symbolName: "pin.fill", label: "Always on Top", side: 20)
    private let opacityButton = IconButton(symbolName: "circle.lefthalf.filled", label: "Cycle Opacity", side: 20)
    private let dockButton = IconButton(symbolName: "sidebar.trailing", label: "Dock into Sidebar", side: 20)
    private let separator = NSBox()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("FloatingTopBarView is created in code only")
    }

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 34).isActive = true

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        titleLabel.textColor = Style.Colors.primaryText
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail

        backButton.setClickHandler { [weak self] in self?.onBack?() }
        forwardButton.setClickHandler { [weak self] in self?.onForward?() }
        reloadButton.setClickHandler { [weak self] in self?.onReloadOrStop?() }
        pinButton.setClickHandler { [weak self] in self?.onTogglePin?() }
        opacityButton.setClickHandler { [weak self] in self?.onCycleOpacity?() }
        dockButton.setClickHandler { [weak self] in self?.onDock?() }

        pinButton.isActive = true

        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .separator

        let navStack = NSStackView(views: [backButton, forwardButton, reloadButton])
        navStack.translatesAutoresizingMaskIntoConstraints = false
        navStack.orientation = .horizontal
        navStack.spacing = 2
        navStack.alignment = .centerY

        let actionStack = NSStackView(views: [opacityButton, pinButton, dockButton])
        actionStack.translatesAutoresizingMaskIntoConstraints = false
        actionStack.orientation = .horizontal
        actionStack.spacing = 2
        actionStack.alignment = .centerY

        addSubview(navStack)
        addSubview(titleLabel)
        addSubview(actionStack)
        addSubview(separator)

        // Trailing traffic light clearance (about 70 points on leading)
        NSLayoutConstraint.activate([
            navStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 74),
            navStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: navStack.trailingAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: actionStack.leadingAnchor, constant: -6),

            actionStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            actionStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    func setTitle(_ title: String) {
        titleLabel.stringValue = title
    }

    func setPinned(_ isPinned: Bool) {
        pinButton.setSymbol(isPinned ? "pin.fill" : "pin.slash", label: isPinned ? "Always on Top (Active)" : "Always on Top (Off)")
        pinButton.isActive = isPinned
        pinButton.contentTintColor = isPinned ? .systemBlue : Style.Colors.secondaryText
    }

    func setLoading(_ isLoading: Bool) {
        if isLoading {
            reloadButton.setSymbol("xmark", label: "Stop Loading")
        } else {
            reloadButton.setSymbol("arrow.clockwise", label: "Reload")
        }
    }

    func setCanGoBack(_ canGo: Bool) {
        backButton.isEnabled = canGo
    }

    func setCanGoForward(_ canGo: Bool) {
        forwardButton.isEnabled = canGo
    }
}
