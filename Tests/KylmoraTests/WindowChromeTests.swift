import Foundation
import Testing
@testable import Kylmora

@Suite("Window controls")
struct WindowChromeTests {
    @Test("With the sidebar showing, the controls are always visible")
    func sidebarShowing() {
        #expect(WindowChrome.hidesWindowControls(sidebarCollapsed: false, topBarHovered: false) == false)
        #expect(WindowChrome.hidesWindowControls(sidebarCollapsed: false, topBarHovered: true) == false)
    }

    @Test("With the sidebar hidden, the controls go away")
    func sidebarHidden() {
        #expect(WindowChrome.hidesWindowControls(sidebarCollapsed: true, topBarHovered: false))
    }

    @Test("Hovering the bar brings them back, so the window stays closable")
    func hoverReveals() {
        #expect(WindowChrome.hidesWindowControls(sidebarCollapsed: true, topBarHovered: true) == false)
    }

    @Test("Space is reserved only while the controls are actually showing there")
    func leadingInset() {
        let reserved: CGFloat = 78
        let normal: CGFloat = 6

        // Sidebar showing: the lights are over there, so nothing to avoid.
        #expect(WindowChrome.topBarLeadingInset(
            sidebarCollapsed: false, topBarHovered: false, reserved: reserved, normal: normal) == normal)
        #expect(WindowChrome.topBarLeadingInset(
            sidebarCollapsed: false, topBarHovered: true, reserved: reserved, normal: normal) == normal)

        // Sidebar hidden and lights hidden: nothing to avoid either.
        #expect(WindowChrome.topBarLeadingInset(
            sidebarCollapsed: true, topBarHovered: false, reserved: reserved, normal: normal) == normal)

        // Sidebar hidden and hovering: the lights are on this bar, step aside.
        #expect(WindowChrome.topBarLeadingInset(
            sidebarCollapsed: true, topBarHovered: true, reserved: reserved, normal: normal) == reserved)
    }
}
