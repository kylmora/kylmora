import AppKit
import WebKit

/// A content web view that offers "Open Link in Glance" on its context menu.
///
/// WebKit exposes no delegate hook for the macOS context menu -- `WKUIDelegate`'s
/// menu callbacks are iOS-only, and the `WKMenuItemIdentifier` constants that
/// would name WebKit's own items are not in the public SDK -- so the only
/// supported seam is `NSView.willOpenMenu(_:with:)`, which means a subclass.
/// That is the entire reason this type exists; it adds no behaviour of its own.
///
/// Whether the menu belongs to a link is answered from the record
/// `GlanceLinkMonitor` took on mousedown, cross-checked against where the press
/// actually landed. The right-button mousedown that opens the menu dispatches
/// the DOM event before WebKit asks for the menu, so the record is there by the
/// time this runs; if it ever is not, the item is simply absent that once,
/// which is the right way round to lose the race.
@MainActor
final class GlanceWebView: WKWebView {
    private var pendingLink: URL?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)

        let link = GlanceLinkMonitor.shared.contextMenuLink(for: event, in: self)?.url
        pendingLink = link

        ContextMenuManager.shared.customize(
            menu: menu,
            for: self,
            event: event,
            pendingLink: link
        )
    }

    @objc private func openLinkInGlance() {
        guard let url = pendingLink else { return }
        let origin = GlanceLinkMonitor.shared.currentLink(in: self)
            .flatMap { GlanceLinkMonitor.shared.windowOrigin(of: $0, in: self) }
        GlanceLinkMonitor.shared.onOpenGlance?(url, origin.map { .element($0) } ?? .centre, .contextMenu)
    }

    @objc private func openLinkInLittleArc() {
        guard let url = pendingLink else { return }
        GlanceLinkMonitor.shared.onOpenLittleArc?(url)
    }

    @objc private func openLinkInSplit() {
        guard let url = pendingLink else { return }
        GlanceLinkMonitor.shared.onOpenSplit?(url)
    }

    @objc func inspectElementFromMenu() {
        if #available(macOS 13.3, *) {
            isInspectable = true
        }
        if responds(to: Selector(("_showInspector:"))) {
            perform(Selector(("_showInspector:")), with: nil)
        } else if let inspector = (self as AnyObject).value(forKey: "_inspector") as? AnyObject {
            if inspector.responds(to: Selector(("show"))) {
                inspector.perform(Selector(("show")))
            }
        } else {
            NSApp.sendAction(Selector(("showWebInspector:")), to: self, from: nil)
        }
    }
}
