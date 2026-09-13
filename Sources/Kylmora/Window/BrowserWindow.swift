import AppKit

/// The browser window: `NSWindow` with one rule of its own about focus.
///
/// WebKit moves first responder to its web view whenever a page focuses an
/// element -- an autofocused search box on a new-tab page does it the moment
/// the page appears. If the command bar is open at that moment the keystrokes
/// meant for the bar land in the page instead, with the bar still showing its
/// placeholder. The window controller installs a policy that refuses such a
/// move while the bar is open; everything else passes through unchanged.
@MainActor
final class BrowserWindow: NSWindow {
    /// Answers whether `responder` may take first responder now. Nil allows
    /// everything, which is `NSWindow`'s own behaviour.
    var focusPolicy: ((NSResponder?) -> Bool)?

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if let focusPolicy, !focusPolicy(responder) { return false }
        return super.makeFirstResponder(responder)
    }
}
