import AppKit
import Foundation
import WebKit

/// Coordinates Vim-style keyboard navigation events received from WebKit.
@MainActor
public final class VimNavigationCoordinator: NSObject {
    public static let shared = VimNavigationCoordinator()

    public static let handlerName = "kylmoraVimNav"

    public var onAction: ((String, [String: Any]) -> Void)?

    override public init() {
        super.init()
    }

    /// Registers the message handler and installs the user script.
    public func attach(_ controller: WKUserContentController) {
        controller.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: .defaultClient)
        controller.add(self, contentWorld: .defaultClient, name: Self.handlerName)

        if Settings.shared.vimBindingsEnabled {
            controller.addUserScript(VimNavigationScript.userScript)
        }
    }

    /// Dynamically injects or activates Vim bindings on an existing web view.
    public func enableBindings(in webView: WKWebView?) {
        guard let webView else { return }
        webView.evaluateJavaScript(VimNavigationScript.script, in: nil, in: .defaultClient) { _ in }
    }
}

extension VimNavigationCoordinator: WKScriptMessageHandler {
    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.handlerName,
              let dict = message.body as? [String: Any],
              let action = dict["action"] as? String
        else { return }

        if let onAction {
            onAction(action, dict)
            return
        }

        guard let window = message.webView?.window?.windowController as? BrowserWindowController else { return }

        switch action {
        case "back":
            window.goBack(nil)
        case "forward":
            window.goForward(nil)
        case "closeTab":
            window.closeTab(nil)
        case "reopenTab":
            _ = window.session.reopenClosedTab()
        case "nextTab":
            window.selectNextTab(nil)
        case "prevTab":
            window.selectPreviousTab(nil)
        case "copyUrl":
            window.copyCurrentURL(nil)
        case "find":
            window.performFind(nil)
        case "linkHints":
            let newTab = dict["newTab"] as? Bool ?? false
            LinkHintsCoordinator.shared.showHints(in: message.webView, openInNewTab: newTab)
        default:
            break
        }
    }
}
