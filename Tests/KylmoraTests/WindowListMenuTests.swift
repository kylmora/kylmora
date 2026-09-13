import Testing
@testable import Kylmora

@Suite("Numbered View-menu shortcuts")
@MainActor
struct WindowListMenuTests {
    /// Tabs: Cmd-1 to Cmd-8 by position, and Cmd-9 always the last tab when
    /// there are nine or more.
    @Test("Tab shortcuts number the first eight and send the ninth to the last")
    func tabShortcuts() {
        let f = { WindowListMenu.shortcut(forIndex: $0, count: 12, lastIsNine: true) }
        #expect(f(0) == "1")
        #expect(f(7) == "8")
        #expect(f(8) == "")   // the ninth of twelve gets no shortcut
        #expect(f(10) == "")
        #expect(f(11) == "9") // the last of twelve is Cmd-9
    }

    @Test("With eight or fewer tabs each gets its own digit and none is the ninth")
    func tabShortcutsShortList() {
        let f = { WindowListMenu.shortcut(forIndex: $0, count: 5, lastIsNine: true) }
        #expect(f(0) == "1")
        #expect(f(4) == "5")   // last of five is Cmd-5, not Cmd-9
    }

    /// Pinned sites number all nine straight through; there is no "last is the
    /// ninth" rule because a tenth pin simply has no shortcut.
    @Test("Pinned-site shortcuts number the first nine in order")
    func pinnedShortcuts() {
        let f = { WindowListMenu.shortcut(forIndex: $0, count: 12, lastIsNine: false) }
        #expect(f(0) == "1")
        #expect(f(8) == "9")
        #expect(f(9) == "")
    }
}
