import AppKit
import Foundation
import WebKit

/// Coordinates the interactive Element Picker between WebKit and Kylmora.
///
/// Registers a message handler in `.defaultClient` world, injects the picker
/// script on demand, receives confirmed cosmetic rules, adds them to
/// `ContentBlocker`, and presents feedback to the user.
@MainActor
final class ElementPickerCoordinator: NSObject {
    static let shared = ElementPickerCoordinator()

    static let handlerName = "elementPicker"

    private let settings: Settings
    private let blocker: ContentBlocker

    init(settings: Settings = .shared, blocker: ContentBlocker = .shared) {
        self.settings = settings
        self.blocker = blocker
        super.init()
    }

    /// Registers the message handler in the configuration's content controller.
    func attach(_ controller: WKUserContentController) {
        controller.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: .defaultClient)
        controller.add(self, contentWorld: .defaultClient, name: Self.handlerName)
    }

    /// Launches interactive element picking mode in the provided web view.
    func startPicking(in webView: WKWebView?) {
        guard let webView else { return }
        webView.evaluateJavaScript(ElementPickerScript.script, in: nil, in: .defaultClient) { _ in }
    }
}

extension ElementPickerCoordinator: WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.handlerName,
              let dict = message.body as? [String: Any],
              let action = dict["action"] as? String
        else { return }

        switch action {
        case "createRule":
            guard let rule = dict["rule"] as? String, !rule.isEmpty else { return }
            blocker.addUserRule(rule)

            // Deliver feedback toast to the window hosting this web view
            if let window = message.webView?.window?.windowController as? BrowserWindowController {
                window.session.showToast?(
                    Toast(
                        symbolName: "target",
                        message: "Blocked element: \(rule)",
                        identity: "element-picker-\(UUID().uuidString)"
                    )
                )
            }
        case "cancel":
            break
        default:
            break
        }
    }
}
