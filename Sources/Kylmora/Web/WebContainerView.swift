import AppKit
import WebKit

/// Shows exactly one tab's page at a time, or an error, or nothing.
///
/// Only the visible tab's web view is in the hierarchy. Background tabs keep
/// their web view but are detached, so AppKit does no layout or drawing for
/// them.
final class WebContainerView: NSView {
    /// Long enough to read as a transition, short enough never to be in the way
    /// of someone switching tabs quickly.
    private static let crossfadeDuration: TimeInterval = 0.12

    var onNewTab: (() -> Void)?

    private weak var current: WKWebView?
    private weak var currentDocument: NSView?
    private let errorPage = ErrorPageView()
    private let emptyState = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        buildEmptyState()
        errorPage.translatesAutoresizingMaskIntoConstraints = false
        errorPage.isHidden = true
        addSubview(errorPage)
        pin(errorPage)
    }

    required init?(coder: NSCoder) {
        fatalError("WebContainerView is created in code only")
    }

    private func buildEmptyState() {
        let label = NSTextField(labelWithString: "No tab open")
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .secondaryLabelColor

        let button = NSButton(title: "New Tab", target: self, action: #selector(newTab))
        button.keyEquivalent = "\r"

        emptyState.setViews([label, button], in: .center)
        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 12
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyState)

        NSLayoutConstraint.activate([
            emptyState.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    private func pin(_ view: NSView) {
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    /// - Parameters:
    ///   - webView: the page to show, or nil when there is no tab.
    ///   - failure: shown instead of the page when the load failed.
    ///   - url: the address the failure refers to.
    ///   - document: a viewer shown over the page, for a tab that is showing
    ///     a document rather than a web page.
    func show(_ webView: WKWebView?, document: NSView? = nil, failure: NavigationFailure?, url: URL?, onRetry: (() -> Void)?) {
        swapWebView(webView)
        swapDocument(document)

        emptyState.isHidden = webView != nil

        if let failure {
            errorPage.configure(with: failure, url: url)
            errorPage.onRetry = onRetry
            reveal(errorPage)
        } else if !errorPage.isHidden {
            errorPage.isHidden = true
        }
    }

    private func swapDocument(_ document: NSView?) {
        guard document !== currentDocument else { return }
        currentDocument?.removeFromSuperview()
        currentDocument = document
        guard let document else { return }
        document.translatesAutoresizingMaskIntoConstraints = false
        addSubview(document, positioned: .below, relativeTo: errorPage)
        pin(document)
        reveal(document)
        window?.makeFirstResponder(document)
    }

    /// The view on top for the tab: its document if it has one, else its page.
    var visibleContent: NSView? { currentDocument ?? current }

    private func swapWebView(_ webView: WKWebView?) {
        guard webView !== current else { return }

        current?.removeFromSuperview()
        current = webView

        guard let webView else { return }
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView, positioned: .below, relativeTo: errorPage)
        pin(webView)
        reveal(webView)
        window?.makeFirstResponder(webView)
    }

    /// Fades a view in rather than snapping it, which is the whole of the
    /// animation budget here: anything longer gets in the way of switching tabs.
    private func reveal(_ view: NSView) {
        view.isHidden = false
        view.wantsLayer = true
        view.layer?.opacity = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.crossfadeDuration
            context.allowsImplicitAnimation = true
            view.animator().layer?.opacity = 1
        }
    }

    @objc private func newTab() {
        onNewTab?()
    }
}
