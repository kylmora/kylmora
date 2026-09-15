import AppKit
import WebKit

/// One pane of a split: a live web view in a rounded card, with a focus outline,
/// sticky toggle button, unsplit button, and close button that appears on hover.
///
/// The pane owns none of the web view's lifetime. `Tab` does, which is
/// what lets the same web view move from the single-page container into a pane
/// and back out again without the page reloading or losing its scroll position.
@MainActor
final class SplitPaneView: NSView {
    let tabID: Tab.ID

    var onClose: (() -> Void)?
    var onToggleStick: (() -> Void)?
    var onUnsplit: (() -> Void)?

    private var webView: WKWebView?
    private let closeButton = NSButton()
    private let stickButton = NSButton()
    private let unsplitButton = NSButton()
    private var hoverArea: NSTrackingArea?

    private(set) var isFocused = false
    private(set) var isSticky = false
    private var isHovered = false

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

        buildButtons()
    }

    required init?(coder: NSCoder) {
        fatalError("SplitPaneView is created in code only")
    }

    private func buildButtons() {
        // 1. Close Button (trailing)
        let closeImage = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: "Close this pane"
        )
        closeButton.image = closeImage
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

        // 2. Stick Button (middle)
        let stickImage = NSImage(
            systemSymbolName: "pin",
            accessibilityDescription: "Stick this pane"
        )
        stickButton.image = stickImage
        stickButton.imagePosition = .imageOnly
        stickButton.isBordered = false
        stickButton.bezelStyle = .regularSquare
        stickButton.contentTintColor = .secondaryLabelColor
        stickButton.target = self
        stickButton.action = #selector(toggleStick)
        stickButton.toolTip = "Stick this pane (keep open while switching other tabs)"
        stickButton.isHidden = true
        stickButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stickButton)

        // 3. Unsplit Button (leading of buttons)
        let unsplitImage = NSImage(
            systemSymbolName: "arrow.up.forward.app",
            accessibilityDescription: "Unsplit: Open in standalone tab"
        )
        unsplitButton.image = unsplitImage
        unsplitButton.imagePosition = .imageOnly
        unsplitButton.isBordered = false
        unsplitButton.bezelStyle = .regularSquare
        unsplitButton.contentTintColor = .secondaryLabelColor
        unsplitButton.target = self
        unsplitButton.action = #selector(unsplit)
        unsplitButton.toolTip = "Unsplit: Open in standalone tab"
        unsplitButton.isHidden = true
        unsplitButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(unsplitButton)

        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: SplitMetrics.paneCloseButtonInset),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SplitMetrics.paneCloseButtonInset),
            closeButton.widthAnchor.constraint(equalToConstant: SplitMetrics.paneCloseButtonSide),
            closeButton.heightAnchor.constraint(equalToConstant: SplitMetrics.paneCloseButtonSide),

            stickButton.topAnchor.constraint(equalTo: topAnchor, constant: SplitMetrics.paneCloseButtonInset),
            stickButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -SplitMetrics.paneButtonSpacing),
            stickButton.widthAnchor.constraint(equalToConstant: SplitMetrics.paneCloseButtonSide),
            stickButton.heightAnchor.constraint(equalToConstant: SplitMetrics.paneCloseButtonSide),

            unsplitButton.topAnchor.constraint(equalTo: topAnchor, constant: SplitMetrics.paneCloseButtonInset),
            unsplitButton.trailingAnchor.constraint(equalTo: stickButton.leadingAnchor, constant: -SplitMetrics.paneButtonSpacing),
            unsplitButton.widthAnchor.constraint(equalToConstant: SplitMetrics.paneCloseButtonSide),
            unsplitButton.heightAnchor.constraint(equalToConstant: SplitMetrics.paneCloseButtonSide)
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
        addSubview(webView, positioned: .below, relativeTo: unsplitButton)
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

    func setSticky(_ sticky: Bool) {
        isSticky = sticky
        stickButton.image = NSImage(
            systemSymbolName: sticky ? "pin.fill" : "pin",
            accessibilityDescription: sticky ? "Unstick this pane" : "Stick this pane"
        )
        stickButton.contentTintColor = sticky ? .controlAccentColor : .secondaryLabelColor
        stickButton.toolTip = sticky ? "Unstick this pane" : "Stick this pane (keep open while switching other tabs)"
        stickButton.isHidden = !sticky && !isHovered
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
        isHovered = true
        closeButton.isHidden = false
        unsplitButton.isHidden = false
        stickButton.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        closeButton.isHidden = true
        unsplitButton.isHidden = true
        stickButton.isHidden = !isSticky
    }

    @objc private func close() {
        onClose?()
    }

    @objc private func toggleStick() {
        onToggleStick?()
    }

    @objc private func unsplit() {
        onUnsplit?()
    }
}
