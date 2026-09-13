import Foundation

/// When the standard window controls should be on screen.
///
/// The window has no titlebar, so the sidebar hosts the traffic lights. Hiding
/// the sidebar leaves them on the page's top bar, on top of its first button.
/// One answer is to hide them; hiding them for good would leave no way to
/// close the window with a mouse, so they come back while the pointer is on the
/// bar they would occupy.
///
/// Kept separate from the window controller so the rule is a test rather than
/// something only a screenshot can confirm.
enum WindowChrome {
    static func hidesWindowControls(sidebarCollapsed: Bool, topBarHovered: Bool, keepsButtons: Bool = false) -> Bool {
        // "Show standard window buttons in Compact Mode": the lights stay
        // whatever the sidebar is doing.
        if keepsButtons { return false }
        return sidebarCollapsed && !topBarHovered
    }

    /// Leading space the top bar reserves before its first button. Only the
    /// revealed lights need it: with the sidebar showing they are over there,
    /// and with them hidden there is nothing to make room for.
    static func topBarLeadingInset(
        sidebarCollapsed: Bool,
        topBarHovered: Bool,
        reserved: CGFloat,
        normal: CGFloat
    ) -> CGFloat {
        hidesWindowControls(sidebarCollapsed: sidebarCollapsed, topBarHovered: topBarHovered)
            || !sidebarCollapsed
            ? normal
            : reserved
    }
}
