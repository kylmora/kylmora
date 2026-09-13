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

        guard let record = GlanceLinkMonitor.shared.contextMenuLink(for: event, in: self) else {
            pendingLink = nil
            return
        }
        pendingLink = record.url

        let item = NSMenuItem(title: "Open Link in Glance", action: #selector(openLinkInGlance), keyEquivalent: "")
        item.target = self
        // Directly under WebKit's own "Open Link in New Window", which is where
        // the eye looks for a third way to open the same link.
        menu.insertItem(item, at: min(2, menu.numberOfItems))

        let littleArcItem = NSMenuItem(title: "Open Link in Little Arc", action: #selector(openLinkInLittleArc), keyEquivalent: "")
        littleArcItem.target = self
        menu.insertItem(littleArcItem, at: min(3, menu.numberOfItems))
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
}
