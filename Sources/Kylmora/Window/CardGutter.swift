import CoreGraphics

/// How wide a gutter the page card leaves on its leading edge.
///
/// The card keeps a gutter of its own on the top, trailing and bottom edges.
/// The leading one is variable because the sidebar usually supplies it: with
/// the sidebar in the split view, the card runs flush to the divider and the
/// sidebar is the margin.
///
/// Pure arithmetic, apart from the window, so every combination can be checked
/// at once -- which is how the compact case was found. In compact mode the
/// sidebar is not collapsed, it is *removed* from the split view and floated
/// over the page, so `isSidebarCollapsed` stays false and the card was given
/// the flush-to-the-divider inset for a divider that was no longer there. The
/// card then ran into the window's own rounded corner: at the top left its
/// square edge sat under the corner's arc, and at the bottom left the card's
/// corner and the window's pinched together. The right and bottom edges, which
/// keep their own gutter, looked right -- which is exactly how it was reported.
enum CardGutter {
    static func leadingInset(
        mode: SidebarMode,
        isTrailing: Bool,
        isZenMode: Bool,
        isSidebarCollapsed: Bool,
        isCompact: Bool
    ) -> CGFloat {
        // Zen mode is the one place the card is meant to reach the window edge.
        if isZenMode { return 0 }
        // Icons-only without compact keeps the strip in the layout, so the card
        // starts after it.
        if mode == .iconsOnly && !isCompact {
            return isTrailing ? 0 : 60
        }
        // Nothing in the layout on that side: the card supplies its own margin,
        // the same one it keeps on the other three edges.
        if isSidebarCollapsed || isCompact {
            return Style.Metrics.elementSeparation
        }
        return isTrailing ? Style.Metrics.elementSeparation : 0
    }
}
