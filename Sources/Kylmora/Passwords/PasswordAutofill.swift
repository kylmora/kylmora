import AppKit
import WebKit
import LocalAuthentication

/// Fills saved logins into pages and offers to save new ones, backed by the
/// macOS Keychain. A small script in each page focuses a login form's
/// fields and, when the user clicks one, asks native for a credential; on
/// submit it hands the typed login back to be saved.
///
/// The site a request is for is read from the frame's real URL, never from the
/// page, so a page can only ever reach the logins saved for its own origin --
/// the one boundary that makes exposing this to page JavaScript safe.
@MainActor
final class PasswordAutofill: NSObject {
    static let shared = PasswordAutofill()
    private let settings = Settings.shared
    private static let messageName = "kylmoraPasswords"

    func attach(_ controller: WKUserContentController) {
        controller.addScriptMessageHandler(self, contentWorld: .page, name: Self.messageName)
        controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }

    // MARK: - Backing the script

    private func credential(for host: String) -> PasswordCredential? {
        guard settings.passwordProvider == .keychain, settings.passwordOfferAutofill, !host.isEmpty else { return nil }
        return KeychainPasswordStore.credentials(host: host).first
    }

    /// Touch ID (or the login password) before a saved password is revealed to a
    /// page, when the setting asks for it. A machine with no biometrics falls
    /// through so autofill still works.
    private func authorize() async -> Bool {
        guard settings.passwordUsesTouchID else { return true }
        let context = LAContext()
        context.localizedFallbackTitle = "Enter Password"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return true }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "fill your saved password") { success, _ in
                continuation.resume(returning: success)
            }
        }
    }

    private func offerToSave(host: String, username: String, password: String) {
        guard settings.passwordProvider == .keychain, settings.passwordOfferSave, !host.isEmpty, !password.isEmpty else { return }
        let existing = KeychainPasswordStore.credentials(host: host)
        // Nothing to do if this exact login is already stored.
        if existing.contains(where: { $0.username == username && $0.password == password }) { return }
        let updating = existing.contains { $0.username == username }
        let alert = NSAlert()
        alert.messageText = updating ? "Update the password for \(host)?" : "Save this password for \(host)?"
        alert.informativeText = username.isEmpty ? "Kylmora can fill it in for you next time." : "Username: \(username)"
        alert.addButton(withTitle: updating ? "Update" : "Save Password")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn {
            KeychainPasswordStore.save(host: host, username: username, password: password)
        }
    }
}

extension PasswordAutofill: WKScriptMessageHandlerWithReply {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) async -> (Any?, String?) {
        guard let body = message.body as? [String: Any], let action = body["action"] as? String else { return (nil, nil) }
        let host = message.frameInfo.request.url?.host() ?? message.webView?.url?.host() ?? ""
        switch action {
        case "lookup":
            guard let credential = credential(for: host), await authorize() else { return (nil, nil) }
            return ([
                "username": credential.username,
                "password": credential.password,
                "submit": settings.passwordSubmitAutomatically
            ], nil)
        case "save":
            // Show the prompt on the next tick rather than blocking the reply
            // handler with a modal while the page is navigating away on submit.
            let username = body["username"] as? String ?? ""
            let password = body["password"] as? String ?? ""
            Task { self.offerToSave(host: host, username: username, password: password) }
            return (nil, nil)
        default:
            return (nil, nil)
        }
    }
}

private extension PasswordAutofill {
    /// Runs in the page: wires a login form's fields so a click fills the saved
    /// login, and reports the typed login on submit so it can be saved. It asks
    /// native for the credential only on focus, so a saved site prompts (and
    /// Touch ID fires) when the user goes to sign in, not on every page load.
    static let script = """
    (function() {
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.kylmoraPasswords;
      if (!handler) return;
      let filled = false;

      function setValue(el, value) {
        try {
          const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
          setter.call(el, value);
        } catch (e) { el.value = value; }
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      }

      function usernameNear(pw, root) {
        const inputs = Array.prototype.slice.call((root || document).querySelectorAll('input'));
        const i = inputs.indexOf(pw);
        for (let j = i - 1; j >= 0; j--) {
          const t = (inputs[j].type || 'text').toLowerCase();
          if (t === 'text' || t === 'email' || t === 'tel') return inputs[j];
        }
        return null;
      }

      async function fillInto(pw) {
        if (filled) return;
        try {
          const creds = await handler.postMessage({ action: 'lookup' });
          if (!creds) return;
          filled = true;
          const user = usernameNear(pw);
          if (user && creds.username) setValue(user, creds.username);
          if (creds.password) setValue(pw, creds.password);
          if (creds.submit && pw.form && pw.form.requestSubmit) pw.form.requestSubmit();
        } catch (e) {}
      }

      function wire() {
        const pw = document.querySelector('input[type="password"]');
        if (!pw || pw.dataset.kylmoraWired) return;
        pw.dataset.kylmoraWired = '1';
        const trigger = function() { fillInto(pw); };
        pw.addEventListener('focus', trigger);
        const user = usernameNear(pw);
        if (user) user.addEventListener('focus', trigger);
      }

      document.addEventListener('submit', function(e) {
        const form = e.target;
        if (!form || !form.querySelectorAll) return;
        const pw = form.querySelector('input[type="password"]');
        if (!pw || !pw.value) return;
        const user = usernameNear(pw, form);
        handler.postMessage({ action: 'save', username: user ? user.value : '', password: pw.value });
      }, true);

      wire();
      new MutationObserver(function() { wire(); }).observe(document.documentElement, { childList: true, subtree: true });
    })();
    """
}
