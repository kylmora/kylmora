import AppKit

/// The numbers the split chrome draws with.
///
/// Separate from `Style.Metrics` because they are derived from it rather
/// than measured alongside it: every value here is the universal gutter plus or
/// minus something, and writing that derivation down is what stops a later
/// re-measurement of the gutter leaving the split view behind.
enum SplitMetrics {

    /// The gap between two panes, which is also the draggable divider.
    ///
    /// The two axes get slightly different values, and the vertical divider's
    /// is literally `separation + 1`. The asymmetry is not a typo: a vertical
    /// divider is a one-point line of chrome between two pages and reads
    /// thinner than a horizontal one of the same size, because the eye
    /// measures it against the full height of the window rather than its
    /// width.
    static func dividerThickness(for axis: SplitLayout.Axis) -> CGFloat {
        switch axis {
        case .horizontal: return Style.Metrics.elementSeparation + 1
        case .vertical: return Style.Metrics.elementSeparation
        }
    }

    /// Each pane is the same rounded card the single-pane content area is, so a
    /// two-pane split reads as two of the same surface rather than as one
    /// surface cut in half.
    static let paneCornerRadius = Style.Metrics.contentCornerRadius

    /// A 2-point outline, drawn inside the pane's bounds, so focus moving
    /// between panes never changes their size.
    static let focusOutlineWidth: CGFloat = 2

    /// The close button in a pane's corner, which appears on hover.
    static let paneCloseButtonSide: CGFloat = 20
    static let paneCloseButtonInset: CGFloat = 6
    static let paneButtonSpacing: CGFloat = 4

    /// The outline colour. The accent is the only colour in the chrome that
    /// already means "this is the thing you are acting on", and a split has no
    /// other signal for which pane a keystroke will reach.
    static var focusOutlineColor: NSColor { .controlAccentColor }
}
