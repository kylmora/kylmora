import AppKit
import WebKit

/// The delegate for a page shown outside a tab -- a glance, a Little Arc
/// window.
///
/// A tab has its own (`TabNavigationHandler`) because a tab's navigation also
/// feeds the session: titles, history, failures, the address field. A glance
/// and a little window are not in the session at all, and they answer the two
/// questions a page can ask that the chrome has to decide: what a download
/// means, and what a `window.open` means.
///
/// One type for both, because two copies of that policy is how the two drift
/// apart -- and a download that works from a tab and not from a glance is a
/// bug nobody finds by reading either file alone.
@MainActor
final class PageWebCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    /// Asked for a web view when the page calls `window.open`. Nil drops the
    /// popup, which is the right answer for a page the user has not kept.
    var onNewWindow: ((WKWebViewConfiguration) -> WKWebView?)?

    init(onNewWindow: ((WKWebViewConfiguration) -> WKWebView?)? = nil) {
        self.onNewWindow = onNewWindow
    }

    @MainActor
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        onNewWindow?(configuration)
    }

    @MainActor
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(DownloadManager.shared.policy(for: navigationAction))
    }

    @MainActor
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(DownloadManager.shared.policy(for: navigationResponse))
    }

    @MainActor
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        DownloadManager.shared.adopt(download)
    }

    @MainActor
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        DownloadManager.shared.adopt(download)
    }
}
