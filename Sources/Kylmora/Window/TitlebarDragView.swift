import AppKit

/// The strip at the top of the sidebar that stands in for a titlebar.
///
/// The window has no real titlebar (`fullSizeContentView`, hidden title), so the
/// behaviours people expect from one have to be provided deliberately. This view
/// supplies the two that matter: dragging the window, and double-clicking to
/// zoom.
final class TitlebarDragView: NSView {
    /// AppKit moves the window for us when the view reports itself as titlebar
    /// background, which also gives the correct behaviour with Stage Manager and
    /// with click-through from an inactive window.
    override var mouseDownCanMoveWindow: Bool { true }

    /// Honours the system setting rather than assuming zoom.
    ///
    /// System Settings offers Zoom, Minimize or Do Nothing for a titlebar
    /// double-click. Hardcoding zoom would override a choice the user already
    /// made for every other window on their Mac.
    private var doubleClickAction: String {
        UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2 else {
            super.mouseDown(with: event)
            return
        }

        switch doubleClickAction {
        case "Minimize":
            window?.performMiniaturize(nil)
        case "None":
            break
        default:
            window?.performZoom(nil)
        }
    }
}
