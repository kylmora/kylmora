import AppKit
import WebKit

/// Coordinates active always-on-top floating web windows.
@MainActor
public final class FloatingWindowManager {
    public static let shared = FloatingWindowManager()

    private(set) var floatingControllers: [FloatingWebWindowController] = []

    public var onDockWebPanel: ((WKWebView, WebPanel?) -> Void)?

    private init() {}

    @discardableResult
    public func openFloatingWindow(
        webView: WKWebView? = nil,
        url: URL? = nil,
        panel: WebPanel? = nil
    ) -> FloatingWebWindowController {
        let controller = FloatingWebWindowController(
            webView: webView,
            url: url,
            panel: panel
        )

        controller.onDockBack = { [weak self, weak controller] adoptedWebView, adoptedPanel in
            guard let self, let controller else { return }
            self.floatingControllers.removeAll { $0 === controller }
            self.onDockWebPanel?(adoptedWebView, adoptedPanel)
        }

        controller.onClose = { [weak self] closedController in
            guard let self else { return }
            self.floatingControllers.removeAll { $0 === closedController }
        }

        floatingControllers.append(controller)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        return controller
    }

    public func closeAll() {
        for controller in floatingControllers {
            controller.close()
        }
        floatingControllers.removeAll()
    }
}
