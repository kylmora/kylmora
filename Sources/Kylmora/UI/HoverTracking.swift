import AppKit

extension NSView {
    /// The one tracking area every hoverable view here wants: enter and exit,
    /// while the app is active, clipped to what is visible. Call from
    /// `updateTrackingAreas` and keep what it returns:
    ///
    ///     override func updateTrackingAreas() {
    ///         super.updateTrackingAreas()
    ///         trackingArea = installHoverTracking(replacing: trackingArea)
    ///     }
    func installHoverTracking(replacing previous: NSTrackingArea?) -> NSTrackingArea {
        if let previous { removeTrackingArea(previous) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        return area
    }

    /// Whether the pointer is really over this view at this instant.
    ///
    /// `mouseExited` is not guaranteed. The app deactivating with the pointer
    /// over a row, a menu or an overlay opening on top of one, a list
    /// reloading or scrolling under a pointer that never moves -- each of
    /// these can take the pointer off a view without an exit event ever
    /// arriving, which leaves the view painted as hovered with nothing
    /// hovering it. Asking the window where the pointer actually is settles
    /// the question, and it is the only thing that can.
    ///
    /// False whenever the window is not the one being used, because a
    /// highlight in a background window is not feedback about anything.
    var isPointerInside: Bool {
        guard let window, window.isKeyWindow else { return false }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(point) && visibleRect.contains(point)
    }
}
