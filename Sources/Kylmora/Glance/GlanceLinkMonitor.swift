import AppKit
import WebKit

/// Knows which link the pointer is on, in every content web view.
///
/// One shared instance, like `DownloadManager`, because the thing it tracks is
/// a property of the pointer and there is only one pointer. The alternative --
/// an instance per web view -- would mean `WebEnvironment` holding a table
/// keyed by web view purely to answer a question about the mouse.
@MainActor
final class GlanceLinkMonitor: NSObject {
    static let shared = GlanceLinkMonitor()

    /// Set by `GlanceController` when it installs itself. Every invocation
    /// path that starts inside a page arrives here.
    var onOpenGlance: ((URL, GlanceOriginHint, GlanceSource) -> Void)?
    /// Opens the link in a Little Arc window directly.
    var onOpenLittleArc: ((URL) -> Void)?

    /// So the interceptor can stand aside while a glance is already up: a
    /// modifier-click inside a glance must navigate the glance rather than be
    /// swallowed by a nesting rule the user cannot see.
    var isGlanceOpen: () -> Bool = { false }

    /// Whether this address is one of the user's pinned sites. Supplied by the
    /// integration, because pinned sites live on `BrowserSession` and nothing
    /// in this directory is allowed to know about it.
    var isPinnedSite: ((URL) -> Bool)?

    /// Path 5 (see `GlanceInvocation.shouldAutoGlance`) is off by default.
    var opensExternalPinnedSiteLinksInGlance = false

    private var record: GlanceLinkRecord?
    private weak var recordedIn: WKWebView?

    private override init() {
        super.init()
    }

    /// Adds the recording script to a configuration. Called once per web view,
    /// from `WebEnvironment.makeConfiguration(for:)`.
    ///
    /// `defaultClient` is the content world the page cannot reach: the script
    /// and its message handler are invisible to page JavaScript, so a page can
    /// neither suppress the recording nor forge one.
    func install(in configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        controller.removeScriptMessageHandler(forName: GlanceScripts.linkHandlerName,
                                              contentWorld: .defaultClient)
        controller.add(self, contentWorld: .defaultClient, name: GlanceScripts.linkHandlerName)
        controller.addUserScript(
            WKUserScript(
                source: GlanceScripts.linkSource,
                injectionTime: .atDocumentStart,
                // Subframes carry links too, and their rectangles are already
                // in the top viewport's space once mapped through `innerWidth`.
                forMainFrameOnly: false,
                in: .defaultClient
            )
        )
    }

    /// The link the pointer was last pressed on in this web view, if it is
    /// still recent enough to act on.
    func currentLink(in webView: WKWebView) -> GlanceLinkRecord? {
        guard let record, recordedIn === webView, record.isFresh() else { return nil }
        return record
    }

    /// Where the fly-out should start, in window coordinates.
    ///
    /// Window space rather than the overlay's, because this is called from the
    /// web view and the overlay is not in the picture yet; the controller
    /// converts once, at the point where it knows what it is animating.
    ///
    /// Returns nil -- meaning "grow from the centre" -- rather than a wrong
    /// rectangle whenever the mapping cannot be trusted: a pinch-magnified web
    /// view scales and translates its content underneath a viewport whose
    /// reported size does not change, so there is no proportional mapping that
    /// holds. An animation that starts in the wrong place is worse than one
    /// that starts in the middle.
    func windowOrigin(of record: GlanceLinkRecord, in webView: WKWebView) -> CGRect? {
        guard let local = rectInWebView(record, webView) else { return nil }
        return webView.convert(local, to: nil)
    }

    private func rectInWebView(_ record: GlanceLinkRecord, _ webView: WKWebView) -> CGRect? {
        guard webView.magnification == 1,
              webView.bounds.width > 0, webView.bounds.height > 0 else { return nil }

        let scaleX = webView.bounds.width / record.viewport.width
        let scaleY = webView.bounds.height / record.viewport.height
        let width = record.rect.width * scaleX
        let height = record.rect.height * scaleY
        let x = record.rect.minX * scaleX
        // CSS measures down from the top of the viewport; an unflipped AppKit
        // view measures up from the bottom.
        let top = record.rect.minY * scaleY
        let y = webView.isFlipped ? top : webView.bounds.height - top - height
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// The browser-process half of invocation path 1, and of path 5.
    ///
    /// Returns true when the navigation has been turned into a glance and must
    /// be cancelled. Called from the content tab's navigation policy decision,
    /// which is the only place that sees both the modifier flags and the
    /// destination before anything is loaded.
    func intercept(_ action: WKNavigationAction) -> Bool {
        guard !isGlanceOpen(), let url = action.request.url,
              let webView = action.sourceFrame.webView else { return false }

        let source: GlanceSource
        if GlanceInvocation.shouldGlance(action) {
            source = .link
        } else if action.navigationType == .linkActivated,
                  action.modifierFlags.isEmpty,
                  let owner = webView.backForwardList.currentItem?.url,
                  GlanceInvocation.shouldAutoGlance(
                      linkURL: url,
                      ownerURL: owner,
                      ownerIsPinnedSite: isPinnedSite?(owner) ?? false,
                      enabled: opensExternalPinnedSiteLinksInGlance
                  ) {
            source = .pinnedSiteExternalLink
        } else {
            return false
        }

        // The rectangle recorded on mousedown is only used when it belongs to
        // the link actually being followed; otherwise the panel grows from the
        // centre rather than from somewhere misleading.
        let record = currentLink(in: webView)
        let origin = record?.url == url
            ? record.flatMap { windowOrigin(of: $0, in: webView) }.map { GlanceOriginHint.element($0) }
            : nil
        onOpenGlance?(url, origin ?? .centre, source)
        return true
    }

    /// Called by `GlanceWebView` when its context menu is about to open.
    func contextMenuLink(for event: NSEvent, in webView: WKWebView) -> GlanceLinkRecord? {
        guard let record = currentLink(in: webView), let mapped = rectInWebView(record, webView) else {
            return nil
        }
        // The recorded rectangle must actually contain the press, so a stale
        // record from a link elsewhere on the page can never put a menu item on
        // a menu that belongs to something else.
        let point = webView.convert(event.locationInWindow, from: nil)
        guard mapped.insetBy(dx: -2, dy: -2).contains(point) else { return nil }
        return record
    }
}

/// Where a glance should appear to come from.
///
/// The `.element` case carries a rectangle in window coordinates; `.centre` is
/// what a bookmark or a command-bar result gets, and is not a failure -- it is
/// a zero-size-at-centre origin.
enum GlanceOriginHint: Equatable, Sendable {
    case element(CGRect)
    case centre

    var rect: CGRect? {
        if case .element(let rect) = self { return rect }
        return nil
    }
}

extension GlanceLinkMonitor: WKScriptMessageHandler {
    @MainActor
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == GlanceScripts.linkHandlerName,
              let parsed = GlanceScripts.parseLink(message.body) else { return }
        record = parsed
        recordedIn = message.webView
    }
}
