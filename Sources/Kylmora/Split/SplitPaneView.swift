import AppKit
import WebKit

/// One pane of a split: a live web view in a rounded card, with a focus outline
/// and a close button that appears on hover.
///
/// The pane owns none of the web view's lifetime. `Tab` does, which is
/// what lets the same web view move from the single-page container into a pane
/// and back out again without the page reloading or losing its scroll position.
@MainActor
final class SplitPaneView: NSView {
    let tabID: Tab.ID

    var onClose: (() -> Void)?

    private var webView: WKWebView?
    private let closeButton = NSButton()
    private var hoverArea: NSTrackingArea?

    private(set) var isFocused = false

    init(tabID: Tab.ID) {
        self.tabID = tabID
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = SplitMetrics.paneCornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = Style.Colors.pageFill.cgColor
        layer?.borderWidth = SplitMetrics.focusOutlineWidth
        // Transparent rather than absent, so gaining focus changes a colour and
        // never a layout: a border that appears would shift the page by 2pt.
        layer?.borderColor = NSColor.clear.cgColor

        buildCloseButton()
    }

    required init?(coder: NSCoder) {
        fatalError("SplitPaneView is created in code only")
    }

    private func buildCloseButton() {
        let image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: "Close this pane"
        )
        closeButton.image = image
        closeButton.imagePosition = .imageOnly
        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(close)
        closeButton.toolTip = "Close this pane"
        closeButton.isHidden = true
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: SplitMetrics.paneCloseButtonInset),
            closeButton.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -SplitMetrics.paneCloseButtonInset
            ),
            closeButton.widthAnchor.constraint(equalToConstant: SplitMetrics.paneCloseButtonSide),
            closeButton.heightAnchor.constraint(equalToConstant: SplitMetrics.paneCloseButtonSide)
        ])
    }

    /// Puts the tab's page in this pane, creating the web view if the tab has
    /// never been shown.
    ///
    /// Every pane of a visible split is a live page, which is the whole point of
    /// the feature: a pane showing a suspended tab's placeholder while its
    /// neighbour renders would be worse than not splitting at all.
    func adopt(_ webView: WKWebView) {
        guard webView !== self.webView else { return }

        self.webView?.removeFromSuperview()
        self.webView = webView

        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView, positioned: .below, relativeTo: closeButton)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    /// Hands the web view back without unloading it, so a tab leaving a split
    /// keeps its page for whatever shows it next.
    func releaseWebView() {
        webView?.removeFromSuperview()
        webView = nil
    }

    func setFocused(_ focused: Bool) {
        guard focused != isFocused else { return }
        isFocused = focused
        layer?.borderColor = focused ? SplitMetrics.focusOutlineColor.cgColor : NSColor.clear.cgColor
        if focused { window?.makeFirstResponder(webView) }
    }

    /// A semantic colour resolved into a layer has to be resolved again when the
    /// appearance changes; `cgColor` captured at build time would keep the light
    /// accent in dark mode.
    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = Style.Colors.pageFill.cgColor
        layer?.borderColor = isFocused ? SplitMetrics.focusOutlineColor.cgColor : NSColor.clear.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        closeButton.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        closeButton.isHidden = true
    }

    @objc private func close() {
        onClose?()
    }
}
