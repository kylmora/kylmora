import AppKit
import Foundation
import Testing
@testable import Kylmora

@Suite("Tab strip reorder and per-tab emoji")
@MainActor
struct TabStripReorderTests {
    @Test("A pointer lands in the gap after every cell whose middle it has passed")
    func dropIndex() {
        let mids: [CGFloat] = [90, 274, 458]
        #expect(TabStripView.dropIndex(pointerX: 10, midpoints: mids) == 0)
        #expect(TabStripView.dropIndex(pointerX: 100, midpoints: mids) == 1)
        #expect(TabStripView.dropIndex(pointerX: 300, midpoints: mids) == 2)
        #expect(TabStripView.dropIndex(pointerX: 900, midpoints: mids) == 3)
        #expect(TabStripView.dropIndex(pointerX: 5, midpoints: []) == 0)
    }

    @Test("Dragging a cell past another reports the move; a short press is a select")
    func reorder() {
        let strip = TabStripView(frame: NSRect(x: 0, y: 0, width: 900, height: TabStripView.height))
        let tabs = (0..<3).map { Tab(url: URL(string: "https://\($0).example/")!, identity: .standard) }
        strip.show(tabs, activeID: tabs[0].id, isPrivate: false)
        strip.layoutSubtreeIfNeeded()
        var moves: [(Int, Int)] = []
        var selected: Tab?
        strip.onReorder = { moves.append(($0, $1)) }
        strip.onSelect = { selected = $0 }

        let first = strip.cells[0]
        let farRight = strip.convert(NSPoint(x: 880, y: 10), to: first)
        first.onDrag?(farRight)
        first.onDrop?(farRight)
        #expect(moves.count == 1)
        #expect(moves.first?.0 == 0)
        #expect(moves.first?.1 == 3, "past the last cell means the end")

        // Dropping where it already is changes nothing.
        let ownPlace = strip.convert(NSPoint(x: 20, y: 10), to: first)
        first.onDrop?(ownPlace)
        #expect(moves.count == 1)

        strip.cells[1].onSelect?()
        #expect(selected === tabs[1])
    }

    @Test("An emoji replaces the favicon in the row, and only an emoji is accepted")
    func emoji() {
        #expect(Tab.firstEmoji(in: " 🚀 rocket") == "🚀")
        #expect(Tab.firstEmoji(in: "👩‍💻") == "👩‍💻")
        #expect(Tab.firstEmoji(in: "abc") == nil)
        #expect(Tab.firstEmoji(in: "") == nil)
        #expect(Tab.firstEmoji(in: "1") == nil, "a digit is not an emoji")

        let tab = Tab(url: URL(string: "https://a.example/")!, identity: .standard)
        tab.setEmoji("🚀")
        #expect(tab.emoji == "🚀")
        #expect(tab.snapshot().emoji == "🚀")
        #expect(Tab(restoring: tab.snapshot(), identity: .standard).emoji == "🚀")
        tab.setEmoji("x")
        #expect(tab.emoji == nil)

        let row = TabRowView()
        row.configure(TabRowContent(title: "Launch", emoji: "🚀"))
        #expect(row.showsEmoji)
        #expect(row.favicon.isHidden)
        row.configure(TabRowContent(title: "Launch"))
        #expect(!row.showsEmoji)
        #expect(!row.favicon.isHidden)
    }
}
