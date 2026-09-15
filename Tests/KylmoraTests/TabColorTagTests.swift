import AppKit
import Foundation
import Testing
@testable import Kylmora

@Suite("Tab colour tags and the unread dot")
@MainActor
struct TabColorTagTests {
    @Test("A tag is kept on the tab, survives the session file, and can be cleared")
    func tags() {
        let tab = Tab(url: URL(string: "https://a.example/")!, identity: .standard)
        #expect(tab.colorTag == nil)
        var changes = 0
        let token = tab.didChange.sink { changes += 1 }
        defer { token.cancel() }
        tab.setColorTag(.green)
        tab.setColorTag(.green)
        #expect(tab.colorTag == .green)
        #expect(changes == 1, "the same tag again is not a change")
        #expect(tab.snapshot().colorTag == "green")
        let restored = Tab(restoring: tab.snapshot(), identity: .standard)
        #expect(restored.colorTag == .green)
        tab.setColorTag(nil)
        #expect(tab.snapshot().colorTag == nil)

        var stale = tab.snapshot()
        stale.colorTag = "chartreuse"
        #expect(Tab(restoring: stale, identity: .standard).colorTag == nil, "an unknown colour restores untagged")
        #expect(TabColorTag.gray.title == "Grey")
        #expect(TabColorTag.allCases.count == 7)
    }

    @Test("A title change after the tab was last looked at is unread until it is looked at again")
    func unread() {
        let tab = Tab(url: URL(string: "https://a.example/")!, identity: .standard)
        #expect(!tab.hasUnreadChange)
        tab.backdateLastActive(by: 60)
        tab.noteTitleChanged("")
        #expect(!tab.hasUnreadChange, "an empty title is not a change")
        tab.noteTitleChanged("New message (1)")
        #expect(tab.hasUnreadChange)
        tab.markActive()
        #expect(!tab.hasUnreadChange, "looking at it clears the mark")
    }

    @Test("The row draws the tag and unread dots and speaks them")
    func row() {
        let row = TabRowView()
        row.configure(TabRowContent(title: "Inbox", colorTag: .red, hasUnreadChange: true))
        #expect(row.showsTagDot)
        #expect(row.showsUnreadDot)
        #expect(row.accessibilityLabel()?.contains("tagged red") == true)
        #expect(row.accessibilityLabel()?.contains("changed since you last looked") == true)
        row.configure(TabRowContent(title: "Inbox"))
        #expect(!row.showsTagDot)
        #expect(!row.showsUnreadDot)
    }

    @Test("The session sets a tag through the tab")
    func session() {
        let (session, _) = TestSession.make()
        let tab = session.newTab(url: URL(string: "https://a.example/")!)
        session.setColorTag(.blue, for: tab)
        #expect(tab.colorTag == .blue)
        #expect(session.snapshot().spaces.flatMap(\.tabs).contains { $0.colorTag == "blue" })
    }
}
