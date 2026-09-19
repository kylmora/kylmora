import AppKit
import Foundation
import Testing
@testable import Kylmora

@Suite("Start page")
@MainActor
struct StartPageTests {
    @Test("The start page has an address of its own that nothing else matches")
    func address() {
        #expect(StartPage.isStartPage(StartPage.url))
        #expect(StartPage.isStartPage(URL(string: "KYLMORA://Start")!))
        #expect(!StartPage.isStartPage(URL(string: "https://kylmora.com/start")!))
        #expect(!StartPage.isStartPage(URL(string: "about:blank")!))
        #expect(NewTabTarget.allCases.first == .kylmora)
        #expect(NewTabTarget.allCases.map(\.title).allSatisfy { !$0.isEmpty })
    }

    @Test("A tab on the start page is titled New Tab, shows no address, and leaves it on the next load")
    func tabState() {
        let tab = Tab(url: StartPage.url, identity: .standard)
        #expect(tab.showsStartPage)
        #expect(tab.displayTitle == "New Tab")
        #expect(tab.displayURL == StartPage.url)
        #expect(tab.contentOverlay is StartPageView)
        #expect(tab.contentOverlay === tab.contentOverlay, "one view, kept")
        #expect(tab.snapshot().url == StartPage.url)

        tab.load(URL(string: "https://example.com/")!)
        #expect(!tab.showsStartPage)
        #expect(tab.contentOverlay == nil)
        #expect(tab.displayURL == URL(string: "https://example.com/")!)

        tab.load(StartPage.url)
        #expect(tab.showsStartPage)
        #expect(!tab.isLoading)
        #expect(tab.displayTitle == "New Tab")

        // Restored from a session the same way.
        let restored = Tab(restoring: tab.snapshot(), identity: .standard)
        #expect(restored.showsStartPage)
    }

    @Test("The page shows pinned sites and most visited as tiles, closed tabs and reading list as rows")
    func content() {
        let view = StartPageView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        var model = StartPageModel()
        model.spaceName = "Work"
        model.pinned = [
            StartPageModel.Link(url: URL(string: "https://github.com")!, title: "GitHub"),
            StartPageModel.Link(url: URL(string: "https://linear.app")!, title: "")
        ]
        model.topSites = [
            StartPageModel.Link(url: URL(string: "https://github.com/x")!, title: "Pinned already"),
            StartPageModel.Link(url: URL(string: "https://news.ycombinator.com")!, title: "HN"),
            StartPageModel.Link(url: URL(string: "https://apple.com")!, title: "Apple")
        ]
        model.recentlyClosed = [StartPageModel.Link(id: "c1", url: URL(string: "https://a.example/1")!, title: "One")]
        model.readingList = [
            StartPageModel.Link(id: "r1", url: URL(string: "https://b.example/1")!, title: "Read me"),
            StartPageModel.Link(id: "r2", url: URL(string: "https://b.example/2")!, title: "And me")
        ]
        #expect(model.pinned[1].title == "linear.app", "an empty title falls back to the host")
        #expect(model.topSitesNotPinned.map(\.title) == ["HN", "Apple"], "a pinned host is not a top site too")

        view.configure(with: model)
        #expect(view.tileCount == 4)
        #expect(view.rowCount == 3)
        #expect(!model.isEmpty)

        var opened: URL?
        view.onOpen = { opened = $0 }
        // Find a tile and press it.
        func tiles(in view: NSView) -> [StartPageTile] {
            view.subviews.flatMap { ($0 as? StartPageTile).map { [$0] } ?? tiles(in: $0) }
        }
        let tile = tiles(in: view).first { $0.link.title == "HN" }
        tile?.activate()
        #expect(opened == URL(string: "https://news.ycombinator.com"))

        view.configure(with: StartPageModel())
        #expect(view.tileCount == 0)
        #expect(view.rowCount == 0)
    }

    @Test("A new tab in the session opens on the start page and records no visit")
    func sessionNewTab() {
        let (session, _) = TestSession.make()
        let tab = session.newTab()
        #expect(tab.showsStartPage)
        #expect(tab.displayTitle == "New Tab")
    }
}

// The start page sat at the *bottom* of the window. An `NSScrollView` lays its
// document out from the bottom-left, so a page with less content than the
// window is tall hung off the bottom edge -- and a new space, whose page is a
// heading and one line, read as a blank tab with nothing in it at all.

@Suite("The start page fills from the top")
@MainActor
struct StartPageLayoutTests {
    private func laidOut(_ model: StartPageModel, height: CGFloat = 800) -> StartPageView {
        let view = StartPageView()
        view.frame = NSRect(x: 0, y: 0, width: 1000, height: height)
        view.configure(with: model)
        view.layoutSubtreeIfNeeded()
        return view
    }

    @Test("Its document is flipped, so the first thing on it is at the top")
    func theDocumentIsFlipped() {
        #expect(laidOut(StartPageModel()).fillsFromTheTop)
    }

    @Test("An almost empty page still starts at the top of the window")
    func aShortPageStaysUp() {
        // The failure this covers: content 300 points tall in an 800-point
        // window, sitting 500 points down.
        let view = laidOut(StartPageModel(spaceName: "Work"))
        #expect(view.contentFrame.minY < 100, "content began \(view.contentFrame.minY) points down")
    }

    @Test("A full page starts at the top too")
    func aLongPageStartsAtTheTop() {
        var model = StartPageModel(spaceName: "Work")
        model.topSites = (0..<8).map {
            StartPageModel.Link(url: URL(string: "https://example\($0).com/")!, title: "Example \($0)")
        }
        let view = laidOut(model)
        #expect(view.contentFrame.minY < 100)
    }

    @Test("Even with nothing to show, the page says something")
    func anEmptyPageIsNotBlank() {
        let view = laidOut(StartPageModel(spaceName: "Work"))
        #expect(view.contentFrame.height > 0)
    }
}
