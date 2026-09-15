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
}
