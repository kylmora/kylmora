import AppKit
import Testing
@testable import Kylmora

// The ranker is the part of the command bar with judgement in it, so it is the
// part these tests are mostly about: which row is first, and why. The view is
// exercised only where it makes a decision of its own -- what collapses, what
// the arrow keys select, and how many rows fit -- never for its pixels.

private func tab(
    _ title: String,
    _ address: String,
    id: UUID = UUID(),
    isActive: Bool = false
) -> TabCandidate {
    TabCandidate(
        id: id,
        title: title,
        address: address,
        url: URL(string: "https://\(address)")!,
        isActive: isActive
    )
}

private func history(
    _ title: String,
    _ key: String,
    visits: Int = 1
) -> HistoryCandidate {
    HistoryCandidate(url: URL(string: "https://\(key)")!, title: title, key: key, visitCount: visits)
}

@Suite("Command bar ranking")
struct CommandRankerTests {
    @Test("An empty query has no answer, so it produces no rows")
    func emptyQueryRanksNothing() {
        let ranked = CommandRanker.rank(
            query: "   ",
            tabs: [tab("Example", "example.com")],
            history: [history("Example", "example.com")]
        )
        #expect(ranked.isEmpty)
    }

    @Test("Candidates that do not match are dropped, not ordered last")
    func nonMatchesAreExcluded() {
        let ranked = CommandRanker.rank(
            query: "zebra",
            tabs: [tab("Example", "example.com")],
            history: [history("Apple", "apple.com")]
        )
        #expect(ranked.isEmpty)
    }

    @Test("A query that is the whole host beats a query that is merely a prefix")
    func exactHostWinsOverPrefix() {
        let ranked = CommandRanker.rank(
            query: "apple.com",
            tabs: [],
            history: [
                history("Apple Developer", "developer.apple.com/docs"),
                history("Apple", "apple.com")
            ]
        )
        #expect(ranked.first?.subtitle == "apple.com")
    }

    @Test("An open tab outranks a history row of the same match quality")
    func openTabsOutrankHistory() {
        let ranked = CommandRanker.rank(
            query: "swift",
            // Same match quality on both sides, and the history row carries
            // the largest frequency bonus there is.
            tabs: [tab("Swift Forums", "swift.org/forums")],
            history: [history("Swift Docs", "swift.org/documentation", visits: 5_000)]
        )
        #expect(ranked.count == 2)
        #expect(ranked[0].kind == .openTab)
        #expect(ranked[1].kind == .history)
    }

    @Test("Frequency lifts a history row but cannot overturn a better match")
    func frequencyIsCappedBelowMatchQuality() {
        let ranked = CommandRanker.rank(
            query: "doc",
            tabs: [],
            history: [
                // Matches only inside a word, but visited constantly.
                history("Reference", "example.com/api-doc", visits: 5_000),
                // Matches from the first character of the address.
                history("Docs", "doc.example.com", visits: 1)
            ]
        )
        #expect(ranked.first?.subtitle == "doc.example.com")
        // The frequent one still ranks, and still got its full bonus.
        #expect(ranked.count == 2)
        #expect(ranked[1].score == CommandRanker.Tier.wordPrefix + CommandRanker.maximumFrequencyBonus)
    }

    @Test("The tab you are already looking at is not offered as somewhere to go")
    func activeTabIsExcluded() {
        let ranked = CommandRanker.rank(
            query: "example",
            tabs: [
                tab("Example", "example.com", isActive: true),
                tab("Example Two", "example.org")
            ],
            history: []
        )
        #expect(ranked.count == 1)
        #expect(ranked[0].subtitle == "example.org")
    }

    @Test("A history row for a page that is already open is folded into the tab")
    func historyDoesNotRepeatAnOpenTab() {
        let id = UUID()
        let ranked = CommandRanker.rank(
            query: "example",
            tabs: [tab("Example", "example.com", id: id)],
            history: [history("Example", "example.com", visits: 40)]
        )
        #expect(ranked.count == 1)
        #expect(ranked[0].action == .switchToTab(id))
    }

    @Test("Scheme and www are noise: pasting a full URL still matches its history row")
    func matchingIgnoresSchemeAndWWW() {
        let ranked = CommandRanker.rank(
            query: "https://www.example.com",
            tabs: [],
            history: [history("Example", "example.com")]
        )
        #expect(ranked.count == 1)
        #expect(ranked[0].score >= CommandRanker.Tier.exactHost)
    }

    @Test("Matching ignores case and accents")
    func matchingIsCaseAndDiacriticInsensitive() {
        #expect(CommandRanker.score(query: "CAFE", title: "Café Reviews", address: "example.com") != nil)
        #expect(CommandRanker.score(query: "café", title: "Cafe Reviews", address: "example.com") != nil)
    }

    @Test("The match ladder is ordered, and each rung is reachable")
    func tiersAreOrdered() {
        #expect(CommandRanker.score(query: "example.com", title: "x", address: "example.com/a")
                == CommandRanker.Tier.exactHost)
        #expect(CommandRanker.score(query: "exam", title: "x", address: "example.com/a")
                == CommandRanker.Tier.addressPrefix)
        #expect(CommandRanker.score(query: "wel", title: "Welcome", address: "example.com")
                == CommandRanker.Tier.titlePrefix)
        #expect(CommandRanker.score(query: "docs", title: "x", address: "apple.com/docs")
                == CommandRanker.Tier.wordPrefix)
        #expect(CommandRanker.score(query: "ampl", title: "x", address: "example.com")
                == CommandRanker.Tier.substring)
        #expect(CommandRanker.score(query: "zzz", title: "x", address: "example.com") == nil)
    }

    @Test("On an equal score the shorter, more canonical address comes first")
    func shorterAddressBreaksTies() {
        let ranked = CommandRanker.rank(
            query: "ex",
            tabs: [],
            history: [
                history("Deep", "example.com/a/deep/page"),
                history("Root", "example.com")
            ]
        )
        #expect(ranked.map(\.subtitle) == ["example.com", "example.com/a/deep/page"])
    }

    @Test("Ranking does not depend on the order candidates were gathered in")
    func orderingIsTotal() {
        let entries = [
            history("One", "example.com/one", visits: 3),
            history("Two", "example.com/two", visits: 3),
            history("Three", "example.com/three", visits: 3)
        ]
        let forwards = CommandRanker.rank(query: "example", tabs: [], history: entries)
        let backwards = CommandRanker.rank(query: "example", tabs: [], history: entries.reversed())
        #expect(forwards == backwards)
    }

    @Test("The list is capped, and the cap keeps the best rows")
    func limitKeepsTheStrongestRows() {
        let entries = (0..<20).map { history("Page \($0)", "example.com/page\($0)") }
        let ranked = CommandRanker.rank(
            query: "example",
            tabs: [tab("Example", "example.com")],
            history: entries,
            limit: 3
        )
        #expect(ranked.count == 3)
        #expect(ranked[0].kind == .openTab)
    }

    @Test("Every row carries a stable identity and something to show")
    func rowsAreRenderable() {
        let ranked = CommandRanker.rank(
            query: "example",
            tabs: [tab("Example", "example.com")],
            history: [history("Other", "example.org")]
        )
        #expect(Set(ranked.map(\.id)).count == ranked.count)
        for result in ranked {
            #expect(!result.title.isEmpty)
            #expect(!result.subtitle.isEmpty)
            #expect(NSImage(systemSymbolName: result.symbolName, accessibilityDescription: nil) != nil)
        }
    }

    @Test("A titleless history entry falls back to its address rather than an empty row")
    func untitledHistoryStillReads() {
        let ranked = CommandRanker.rank(
            query: "example",
            tabs: [],
            history: [history("", "example.com")]
        )
        #expect(ranked.first?.title == "example.com")
    }
}

private func leftClick() -> NSEvent {
    NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1
    )!
}

@Suite("Command bar")
@MainActor
struct CommandBarViewTests {
    private func results(_ count: Int) -> [CommandResult] {
        CommandRanker.rank(
            query: "example",
            tabs: [],
            history: (0..<count).map { history("Page \($0)", "example.com/page\($0)") },
            limit: count
        )
    }

    private func bar(height: CGFloat = 800) -> CommandBar {
        let bar = CommandBar()
        bar.frame = NSRect(x: 0, y: 0, width: 1_200, height: height)
        bar.layoutSubtreeIfNeeded()
        return bar
    }

    @Test("With nothing to show the panel is one row: the list is collapsed")
    func emptyResultsCollapseTheList() {
        let bar = bar()
        bar.setResults([])
        #expect(bar.visibleResults.isEmpty)
        #expect(bar.selectedIndex == nil)
    }

    @Test("Rows appear when there is something to show")
    func resultsPopulateTheList() {
        let bar = bar()
        bar.setResults(results(3))
        #expect(bar.visibleResults.count == 3)
    }

    @Test("Nothing is preselected: Return goes to what was typed until an arrow is pressed")
    func nothingIsPreselected() {
        let bar = bar()
        bar.setResults(results(3))
        #expect(bar.selectedIndex == nil)
    }

    @Test("Down walks the list and stops at the end rather than wrapping")
    func downArrowWalksAndStops() {
        let bar = bar()
        bar.setResults(results(3))
        bar.moveSelection(by: 1)
        #expect(bar.selectedIndex == 0)
        bar.moveSelection(by: 1)
        bar.moveSelection(by: 1)
        #expect(bar.selectedIndex == 2)
        bar.moveSelection(by: 1)
        #expect(bar.selectedIndex == 2)
    }

    @Test("Up off the first row returns to the query line")
    func upArrowReturnsToTheQuery() {
        let bar = bar()
        bar.setResults(results(3))
        bar.moveSelection(by: 1)
        bar.moveSelection(by: -1)
        #expect(bar.selectedIndex == nil)
    }

    @Test("Up from the query line selects the last row")
    func upArrowFromTheQueryWrapsToTheEnd() {
        let bar = bar()
        bar.setResults(results(3))
        bar.moveSelection(by: -1)
        #expect(bar.selectedIndex == 2)
    }

    @Test("Arrows do nothing when there is no list")
    func arrowsAreInertWithoutResults() {
        let bar = bar()
        bar.setResults([])
        bar.moveSelection(by: 1)
        bar.moveSelection(by: -1)
        #expect(bar.selectedIndex == nil)
    }

    @Test("A new list drops the old selection rather than carrying a stale one")
    func newResultsClearTheSelection() {
        let bar = bar()
        bar.setResults(results(3))
        bar.moveSelection(by: 1)
        bar.setResults(results(2))
        #expect(bar.selectedIndex == nil)
    }

    @Test("The list is clipped to what fits the window, and grows when it can")
    func rowCountFollowsTheWindowHeight() {
        let tall = CommandBar.maximumVisibleRows(inHeight: 900)
        let short = CommandBar.maximumVisibleRows(inHeight: 300)
        #expect(tall > short)
        #expect(short >= 0)
        // The window's own minimum height must still leave the panel usable.
        #expect(CommandBar.maximumVisibleRows(inHeight: 460) >= 4)

        let bar = bar(height: 460)
        bar.setResults(results(8))
        #expect(bar.visibleResults.count == min(8, CommandBar.maximumVisibleRows(inHeight: 460)))
    }

    @Test("A window too short for even one row still shows the query field")
    func aVeryShortWindowShowsNoRows() {
        #expect(CommandBar.maximumVisibleRows(inHeight: 120) == 0)
        let bar = bar(height: 120)
        bar.setResults(results(4))
        #expect(bar.visibleResults.isEmpty)
    }

    @Test("Selecting by index is bounds-checked, so a stale row cannot be chosen")
    func selectionIsBoundsChecked() {
        let bar = bar()
        bar.setResults(results(2))
        bar.select(5)
        #expect(bar.selectedIndex == nil)
        bar.select(1)
        #expect(bar.selectedIndex == 1)
        bar.select(nil)
        #expect(bar.selectedIndex == nil)
    }

    @Test("Return with no row selected resolves the typed text the way the omnibox does")
    func returnWithoutSelectionNavigates() {
        let bar = bar()
        var performed: CommandAction?
        bar.onRun = { performed = $0 }
        bar.open(text: "example.com")
        bar.submit()
        #expect(performed == .openURL(URL(string: "https://example.com")!))
    }

    @Test("Return with a row selected runs that row and nothing else")
    func returnWithSelectionRunsTheRow() {
        let bar = bar()
        var performed: CommandAction?
        bar.onRun = { performed = $0 }
        bar.open(text: "example.com")
        bar.setResults(results(3))
        bar.moveSelection(by: 1)
        let expected = bar.visibleResults[0].action
        bar.submit()
        #expect(performed == expected)
    }

    @Test("Running a row closes the bar, and closing clears what was typed")
    func runningClosesTheBar() {
        let bar = bar()
        bar.onRun = { _ in }
        bar.open(text: "example.com")
        #expect(bar.isOpen)
        bar.setResults(results(2))
        bar.submit()
        #expect(!bar.isOpen)
        #expect(bar.results.isEmpty)
    }

    @Test("Escape dismisses without running anything")
    func escapeDismisses() {
        let bar = bar()
        var performed: CommandAction?
        bar.onRun = { performed = $0 }
        bar.open(text: "example.com")
        bar.cancelOperation(nil)
        #expect(!bar.isOpen)
        #expect(performed == nil)
    }

    @Test("A click outside the panel dismisses; the bar covers the pane to catch it")
    func clickingOutsideDismisses() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 800))
        let bar = CommandBar()
        bar.install(in: host)
        host.layoutSubtreeIfNeeded()
        #expect(bar.superview === host)
        #expect(bar.frame.size == host.frame.size)

        bar.open()
        bar.mouseDown(with: leftClick())
        #expect(!bar.isOpen)
    }

    @Test("Empty text resolves to nothing, so Return on an empty bar is inert")
    func emptyReturnDoesNothing() {
        let bar = bar()
        var ran = false
        bar.onRun = { _ in ran = true }
        bar.open()
        bar.submit()
        #expect(!ran)
        #expect(bar.isOpen)
    }

    @Test("Toggling opens and closes the same bar rather than stacking panels")
    func toggleIsSymmetric() {
        let bar = bar()
        bar.toggle()
        #expect(bar.isOpen)
        bar.toggle()
        #expect(!bar.isOpen)
    }

    @Test("Opening with openInNewTab sets isNewTabMode and closing resets it")
    func openInNewTabMode() {
        let bar = bar()
        bar.open(openInNewTab: true)
        #expect(bar.isNewTabMode)
        bar.close()
        #expect(!bar.isNewTabMode)
    }

    @Test("Tab key on a selected row completes the row value into the query field")
    func tabKeyCompletesSelection() {
        let bar = bar()
        bar.open(text: "ex")
        bar.setResults(results(2))
        bar.select(0)
        let expected = bar.visibleResults[0].subtitle
        let handled = bar.control(
            NSControl(),
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.insertTab(_:))
        )
        #expect(handled)
        #expect(bar.queryText == expected)
    }
}

@Suite("Command bar sources")
struct CommandSourcesTests {
    private let tab = TabCandidate(id: UUID(), title: "Apple", address: "apple.com", url: URL(string: "https://apple.com/")!, isActive: false)
    private let history = HistoryCandidate(url: URL(string: "https://applenews.example/")!, title: "Apple News", key: "applenews.example", visitCount: 3)
    private let bookmark = BookmarkCandidate(url: URL(string: "https://apple.example/docs")!, title: "Apple Docs", key: "apple.example/docs")
    private let search = SearchCandidate(engineName: "DuckDuckGo", url: URL(string: "https://duckduckgo.com/?q=apple")!)

    @Test("Bookmarks are suggested, and a search row comes last")
    func bookmarksAndSearch() {
        let results = CommandRanker.rank(query: "apple", tabs: [tab], history: [history], bookmarks: [bookmark], search: search)
        #expect(results.contains { $0.kind == .bookmark && $0.title == "Apple Docs" })
        #expect(results.last?.kind == .search)
        #expect(results.last?.title == "Search DuckDuckGo for \u{201c}apple\u{201d}")
    }

    @Test("Each source can be switched off")
    func sourcesGate() {
        var sources = CommandSources()
        sources.openTabs = false
        sources.bookmarks = false
        sources.searchEngine = false
        let results = CommandRanker.rank(query: "apple", tabs: [tab], history: [history], bookmarks: [bookmark], search: search, sources: sources)
        #expect(results.map(\.kind) == [.history])
    }

    @Test("The top hit is the shortest address that starts with the query")
    func topHit() {
        let root = HistoryCandidate(url: URL(string: "https://apple.example/")!, title: "Apple", key: "apple.example", visitCount: 1)
        let deep = HistoryCandidate(url: URL(string: "https://apple.example/a/b")!, title: "Apple deep page with a long title", key: "apple.example/a/b", visitCount: 9)
        let results = CommandRanker.rank(query: "apple.ex", tabs: [], history: [deep, root], bookmarks: [], search: nil)
        #expect(results.first?.subtitle == "apple.example")
        var off = CommandSources()
        off.topHits = false
        let plain = CommandRanker.rank(query: "apple.ex", tabs: [], history: [deep, root], bookmarks: [], search: nil, sources: off)
        let promoted = results.first!.score
        let unpromoted = plain.first { $0.subtitle == "apple.example" }!.score
        #expect(promoted == unpromoted + CommandRanker.topHitBonus)
    }

    @Test("Spaces are ranked and switch space action is returned")
    func spacesRanking() {
        let spaceID = UUID()
        let space = SpaceCandidate(id: spaceID, name: "Development", isActive: false, tabCount: 5)
        let results = CommandRanker.rank(query: "dev", tabs: [], spaces: [space], history: [])
        #expect(results.contains { $0.kind == .space && $0.title == "Development" && $0.action == .switchToSpace(spaceID) })
        #expect(results.first?.shortcut == "Space")
        #expect(results.first?.subtitle == "Space • 5 tabs")
    }

    @Test("Active space is not offered as somewhere to switch to")
    func activeSpaceIsExcluded() {
        let space = SpaceCandidate(id: UUID(), name: "Work", isActive: true, tabCount: 3)
        let results = CommandRanker.rank(query: "work", tabs: [], spaces: [space], history: [])
        #expect(results.isEmpty)
    }

    @Test("Commands are ranked by title and keywords with shortcut badges")
    func commandsRanking() {
        let cmd = CommandCandidate(
            id: "split-side",
            title: "Split Side by Side",
            subtitle: "Tile two tabs vertically",
            symbolName: "rectangle.split.2x1",
            shortcut: "⌥⌘V",
            keywords: ["split", "dual"]
        )
        let byTitle = CommandRanker.rank(query: "split", tabs: [], commands: [cmd], history: [])
        #expect(byTitle.contains { $0.kind == .command && $0.id == "cmd:split-side" && $0.shortcut == "⌥⌘V" })

        let byKeyword = CommandRanker.rank(query: "dual", tabs: [], commands: [cmd], history: [])
        #expect(byKeyword.contains { $0.kind == .command && $0.id == "cmd:split-side" })
    }

    @Test("All catalog commands have valid SF symbols and non-empty titles")
    @MainActor
    func commandCatalogIntegrity() {
        let all = CommandCatalog.all
        #expect(!all.isEmpty)
        for cmd in all {
            #expect(!cmd.id.isEmpty)
            #expect(!cmd.title.isEmpty)
            #expect(!cmd.symbolName.isEmpty)
            let image = NSImage(systemSymbolName: cmd.symbolName, accessibilityDescription: nil)
            #expect(image != nil)
        }
    }

    @Test("Open tabs display their space name if provided")
    func tabsWithSpaceName() {
        let tabWithSpace = TabCandidate(
            id: UUID(),
            title: "GitHub Pull Requests",
            address: "github.com/pulls",
            url: URL(string: "https://github.com/pulls")!,
            isActive: false,
            spaceName: "Work"
        )
        let results = CommandRanker.rank(query: "github", tabs: [tabWithSpace], history: [])
        #expect(results.first?.subtitle == "Work • github.com/pulls")
        #expect(results.first?.shortcut == "Jump")
    }
}
