import CoreGraphics

/// What width the floating sidebar should come out at.
///
/// Compact mode pushes the sidebar exactly its own width off the window edge,
/// so it has to be told what that width is. The obvious source -- measure the
/// sidebar view -- is right only while the sidebar is in the split view: in
/// compact mode that same view *is* the floating plate's content, so measuring
/// it feeds the plate's width back in as the sidebar's own. The plate is
/// floored at the minimum width, so each pass shaved the sidebar down towards
/// 105 points and left it there: every row in the floating sidebar truncated
/// ("Audit g...", "New Sp..."), and the real sidebar coming back from compact
/// mode narrower than the user left it.
///
/// Pure, so the rule can be checked without a window.
enum SidebarMeasurement {
    /// - Parameters:
    ///   - live: the sidebar view's current width.
    ///   - isFloating: whether compact mode has it out of the split view.
    ///   - stored: the width the user set, from settings or the space.
    ///   - minimum: the narrowest a sidebar may be.
    static func resting(
        live: CGFloat, isFloating: Bool, stored: CGFloat, minimum: CGFloat
    ) -> CGFloat {
        // Floating: the view is the plate, so it says nothing about the
        // sidebar. Take what the user set.
        guard !isFloating else { return stored }
        // At or below the minimum the view has not been laid out in the split
        // view yet -- a fresh sidebar reports exactly the minimum -- and that
        // is not a width anyone chose.
        return live > minimum ? live : stored
    }
}
