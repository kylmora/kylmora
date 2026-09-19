import AppKit
import WebKit

/// The docked side panel: one extension's page, beside the web page.
///
/// It is an ordinary extension page -- the same `chrome-extension://` origin
/// the popup and the options page use -- hosted in a web view made from the
/// configuration the engine hands out for that extension, so `chrome.storage`,
/// `chrome.runtime` and the rest work in it exactly as they do in a popup. The
/// two things added are the side panel API, which the engine does not have,
/// and the message handler it answers through.
@available(macOS 15.4, *)
@MainActor
final class ExtensionPanelViewController: NSViewController, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    /// Asked to answer a call from the page. Set by the service that owns the
    /// API's meaning.
    var handles: ((UUID, String, [String: Any]) -> ExtensionSidebarBroker.Reply)?
    var onClose: (() -> Void)?

    private let header = NSView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let webContainer = NSView()
    /// The panel's own card, the same one the page sits in: rounded, inset
    /// from the window edges by the gutter, hairlined and shadowed.
    private let card = NSView()
    private let cardShadow = CALayer()
    /// What the gutter around the card shows: the window's own material with
    /// the space's colour washed over it, exactly as the strip around the page
    /// card does. Without it the split view's plain backing shows through and
    /// the panel looks like a white sheet with a card drawn on it.
    private let underlay = NSVisualEffectView()
    private let tint = TintView()
    private var pageEdgeConstraint: NSLayoutConstraint?
    private var windowEdgeConstraint: NSLayoutConstraint?
    private var webView: WKWebView?
    /// Which extension the page on screen belongs to, so a message from it is
    /// attributed to that extension and no other.
    private(set) var extensionID: UUID?
    private var loadedURL: URL?

    override func loadView() {
        let root = CardHostView()
        root.wantsLayer = true
        root.translatesAutoresizingMaskIntoConstraints = false

        // Everything below is the page card's own recipe, because the panel is
        // the same kind of surface sitting beside it. A panel drawn edge to
        // edge with square corners reads as something bolted on rather than as
        // part of this window.
        underlay.material = .sidebar
        underlay.blendingMode = .behindWindow
        // Greys out with the rest of the window when it loses focus, which a
        // saturated strip beside a greyed page would not.
        underlay.state = .followsWindowActiveState
        underlay.translatesAutoresizingMaskIntoConstraints = false
        tint.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(underlay)
        root.addSubview(tint)

        cardShadow.cornerCurve = .continuous
        cardShadow.cornerRadius = Style.Metrics.contentCornerRadius
        cardShadow.shadowOffset = CGSize(width: 0, height: -Style.Metrics.cardShadowOffset)
        cardShadow.shadowRadius = Style.Metrics.cardShadowRadius
        cardShadow.shadowOpacity = 1
        cardShadow.actions = ["bounds": NSNull(), "position": NSNull(), "shadowPath": NSNull()]

        card.wantsLayer = true
        card.layer?.cornerRadius = Style.Metrics.contentCornerRadius
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false

        buildHeader()
        webContainer.translatesAutoresizingMaskIntoConstraints = false
        webContainer.wantsLayer = true

        root.addSubview(card)
        root.layer?.addSublayer(cardShadow)
        root.card = card
        root.cardShadow = cardShadow
        card.addSubview(header)
        card.addSubview(webContainer)

        // The gutter faces the window; the side facing the page is flush,
        // because the page card already keeps a gutter of its own there and
        // two gutters side by side would read as a gap twice as wide as every
        // other gap in the window.
        let gutter = Style.Metrics.elementSeparation
        let pageEdge = card.leadingAnchor.constraint(equalTo: root.leadingAnchor)
        let windowEdge = card.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -gutter)
        pageEdgeConstraint = pageEdge
        windowEdgeConstraint = windowEdge

        NSLayoutConstraint.activate([
            underlay.topAnchor.constraint(equalTo: root.topAnchor),
            underlay.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            underlay.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            underlay.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            tint.topAnchor.constraint(equalTo: root.topAnchor),
            tint.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tint.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            card.topAnchor.constraint(equalTo: root.topAnchor, constant: Style.Metrics.contentTopInset),
            card.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -gutter),
            pageEdge,
            windowEdge,

            header.topAnchor.constraint(equalTo: card.topAnchor),
            header.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            // The page card's own top bar, to the point: the two cards sit
            // side by side and a header four points shorter than the toolbar
            // beside it reads as a misalignment, which is exactly what it is.
            header.heightAnchor.constraint(equalToConstant: Style.Metrics.topBarHeight),

            webContainer.topAnchor.constraint(equalTo: header.bottomAnchor),
            webContainer.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            webContainer.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            webContainer.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        // The card's colours are appearance-aware and live on a layer, which
        // does not follow light and dark by itself.
        root.onAppearanceChange = { [weak self] in self?.updateCardColours() }
        view = root
        updateCardColours()
        updateGutters()
    }

    override func viewWillLayout() {
        super.viewWillLayout()
        // The sidebar can move from one edge to the other, and the panel goes
        // with it: whichever side faces the page is the flush one.
        updateGutters()
    }

    /// The strip around the card wears the space's colour, the same one the
    /// strip around the page card wears.
    var spaceWash: NSColor? {
        get { tint.wash }
        set { tint.wash = newValue }
    }

    var spaceGradient: WashGradient? {
        get { tint.gradientWash }
        set { tint.gradientWash = newValue }
    }

    func showSpaceWash(_ wash: NSColor?, animatedOver duration: TimeInterval) {
        tint.transitionDuration = duration
        tint.wash = wash
        tint.transitionDuration = 0
        tint.show(wash, animatedOver: duration)
    }

    func showSpaceGradient(_ gradient: WashGradient?, animatedOver duration: TimeInterval) {
        tint.transitionDuration = duration
        tint.gradientWash = gradient
        tint.transitionDuration = 0
    }

    func blendSpaceWash(toward other: NSColor?, fraction: CGFloat) {
        tint.blend(toward: other, fraction: fraction)
    }

    /// The panel sits opposite the sidebar, so a sidebar on the trailing edge
    /// puts the panel on the leading one and the gutters swap.
    private func updateGutters() {
        let gutter = Style.Metrics.elementSeparation
        let panelIsLeading = Settings.shared.sidebarPosition == .trailing
        pageEdgeConstraint?.constant = panelIsLeading ? gutter : 0
        windowEdgeConstraint?.constant = panelIsLeading ? 0 : -gutter
    }

    private func updateCardColours() {
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            card.layer?.backgroundColor = Style.Colors.pageFill.cgColor
            // The same hairline the page card carries: a pale panel on a pale
            // material would otherwise lose the rounded corner that says this
            // is a card at all.
            card.layer?.borderColor = Style.Colors.hairline.cgColor
            card.layer?.borderWidth = Style.Metrics.hairline
            cardShadow.shadowColor = Style.Colors.cardShadow.cgColor
        }
    }

    private func buildHeader() {
        header.translatesAutoresizingMaskIntoConstraints = false
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = Style.Colors.secondaryText
        iconView.setAccessibilityElement(false)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = Style.Colors.secondaryText
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.usesSingleLineMode = true

        let reload = IconButton(symbolName: "arrow.clockwise", label: "Reload Panel", side: 22)
        reload.setClickHandler { [weak self] in self?.webView?.reload() }
        let close = IconButton(symbolName: "xmark", label: "Close Panel", side: 22)
        close.setClickHandler { [weak self] in self?.onClose?() }

        let separator = NSBox()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .separator

        let titleStack = NSStackView(views: [iconView, titleLabel])
        titleStack.orientation = .horizontal
        titleStack.alignment = .centerY
        titleStack.spacing = 6
        titleStack.translatesAutoresizingMaskIntoConstraints = false

        let actionStack = NSStackView(views: [reload, close])
        actionStack.orientation = .horizontal
        actionStack.alignment = .centerY
        actionStack.spacing = 2
        actionStack.translatesAutoresizingMaskIntoConstraints = false

        header.addSubview(titleStack)
        header.addSubview(actionStack)
        header.addSubview(separator)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            titleStack.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            titleStack.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: actionStack.leadingAnchor, constant: -6),

            actionStack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -6),
            actionStack.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            separator.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: header.bottomAnchor),
        ])
    }

    /// Shows one extension's panel page, reusing the web view when the same
    /// page is already there: a panel that reloaded itself every time the
    /// active tab changed would lose whatever the user had typed in it.
    func show(extensionID: UUID,
              context: WKWebExtensionContext,
              path: String,
              title: String,
              icon: NSImage?) {
        loadViewIfNeeded()
        titleLabel.stringValue = title
        // An extension without an icon of its own gets the same outlined
        // symbol the rest of the chrome uses for a panel.
        iconView.image = icon ?? NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: nil)
        iconView.contentTintColor = icon == nil ? Style.Colors.secondaryText : nil
        let url = context.baseURL.appending(path: path)
        if self.extensionID == extensionID, loadedURL == url, webView != nil { return }

        teardownWebView()
        let configuration = context.webViewConfiguration ?? WKWebViewConfiguration()
        configuration.userContentController.addUserScript(WKUserScript(
            source: ExtensionSidebarShim.page,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        configuration.userContentController.addScriptMessageHandler(
            self,
            contentWorld: .page,
            name: ExtensionSidebarShim.messageHandlerName
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webContainer.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: webContainer.topAnchor),
            webView.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),
        ])
        self.webView = webView
        self.extensionID = extensionID
        loadedURL = url
        webView.load(URLRequest(url: url))
    }

    /// Lets the page go. A panel that is closed should not keep running the
    /// extension's code, which is what the user closing it asked for.
    func clear() {
        teardownWebView()
        extensionID = nil
        loadedURL = nil
        titleLabel.stringValue = ""
        iconView.image = nil
    }

    private func teardownWebView() {
        guard let webView else { return }
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: ExtensionSidebarShim.messageHandlerName, contentWorld: .page)
        controller.removeAllUserScripts()
        webView.stopLoading()
        webView.removeFromSuperview()
        self.webView = nil
    }

    // MARK: - The page calling the API

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let extensionID, let body = message.body as? [String: Any],
              let method = body["method"] as? String
        else { return (nil, "That is not a side panel call.") }
        let arguments = (body["args"] as? [String: Any]) ?? [:]
        switch handles?(extensionID, method, arguments) ?? .failure("Kylmora is not answering side panel calls.") {
        case .done:
            return (nil, nil)
        case .value(let values):
            return (values.mapValues(\.json), nil)
        case .failure(let message):
            return (nil, message)
        }
    }
}

/// Keeps the card's shadow under the card.
///
/// A shadow drawn on the card's own layer would be clipped by the mask that
/// rounds its corners, so it is a layer of its own underneath, and its frame
/// has to follow the card's by hand.
@MainActor
final class CardHostView: NSView {
    weak var card: NSView?
    var cardShadow: CALayer?
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    override func layout() {
        super.layout()
        guard let card, let cardShadow else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cardShadow.frame = card.frame
        cardShadow.shadowPath = CGPath(
            roundedRect: CGRect(origin: .zero, size: card.frame.size),
            cornerWidth: Style.Metrics.contentCornerRadius,
            cornerHeight: Style.Metrics.contentCornerRadius,
            transform: nil
        )
        CATransaction.commit()
    }
}
