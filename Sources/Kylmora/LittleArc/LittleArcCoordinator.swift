import AppKit
import WebKit

/// Owns the Little Arc windows, however many are open at once.
///
/// Each window is one link and they do not replace one another: a user working
/// through a message can open a second without losing the first. Holding the
/// controllers is what keeps them alive -- an `NSWindowController` released
/// while its window is up takes the window with it.
@MainActor
final class LittleArcCoordinator {
    private weak var session: BrowserSession?
    private var windows: [LittleArcWindowController] = []

    init(session: BrowserSession) {
        self.session = session
    }

    /// How many little windows are open. The tests' window on the coordinator's
    /// own bookkeeping.
    var openCount: Int { windows.count }
    var openPageURLs: [URL] { windows.compactMap(\.pageURL) }

    /// Opens a link from another app in a small window of its own.
    ///
    /// - Parameter space: the space the page browses as. Normally the active
    ///   one; the General pane may send external links to a default space
    ///   instead, and this honours that without moving the user to it -- the
    ///   whole point of the window is that they stay where they are.
    func open(url: URL, in space: Space) {
        guard let session else { return }
        // The same schemes a glance may carry. A link that arrived from
        // somewhere else does not get to be `javascript:` or an opaque origin
        // under Kylmora's own chrome.
        guard GlanceInvocation.isPermittedTarget(url) else { return }

        let controller = LittleArcWindowController(url: url, identity: space.identity)
        controller.spaceChoices = { [weak session] in
            guard let session else { return [] }
            return session.spaces.map { candidate in
                LittleArcTopBar.SpaceChoice(
                    id: candidate.id,
                    title: candidate.name,
                    image: candidate.dotImage(),
                    isOwner: candidate.id == space.id
                )
            }
        }
        controller.onMove = { [weak self] controller, spaceID, webView, url in
            self?.keep(controller, webView: webView, url: url, in: spaceID)
        }
        controller.onRequestChildTab = { [weak session] configuration in
            // A popup from a little window becomes a real tab beside the one
            // the browser is showing: the page is asking for somewhere
            // permanent, and the sidebar is where pages are kept.
            guard let session, let parent = session.activeTab else { return nil }
            return session.adoptChildTab(of: parent, configuration: configuration).webView()
        }
        controller.onClose = { [weak self] closed in
            // Deferred: the window is still inside its own close call, and
            // dropping the last reference to the controller from in there would
            // deallocate it half-way through.
            DispatchQueue.main.async {
                self?.windows.removeAll { $0 === closed }
            }
        }

        windows.append(controller)
        controller.show()
    }

    /// Moves a page into the sidebar, in the space the user chose.
    private func keep(
        _ controller: LittleArcWindowController,
        webView: WKWebView,
        url: URL,
        in spaceID: UUID
    ) {
        guard let session, let space = session.spaces.first(where: { $0.id == spaceID }) else { return }
        session.adoptLittleArcPage(webView, loadedAs: controller.identity, url: url, into: space)
    }
}
