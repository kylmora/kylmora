import AppKit
import Foundation
import Testing
@testable import Kylmora

@Suite("Folder nesting")
@MainActor
struct FolderTreeTests {
    private func folder(_ name: String, parent: TabGroup? = nil) -> TabGroup {
        TabGroup(name: name, parentID: parent?.id)
    }

    @Test("Depth counts ancestors and ordering is depth first")
    func depthAndOrder() {
        let root = folder("Root")
        let child = folder("Child", parent: root)
        let grandchild = folder("Grandchild", parent: child)
        let sibling = folder("Sibling")
        let groups = [root, child, grandchild, sibling]

        #expect(FolderTree.depth(of: root, in: groups) == 0)
        #expect(FolderTree.depth(of: grandchild, in: groups) == 2)
        #expect(FolderTree.ordered(groups).map(\.folder.name) == ["Root", "Child", "Grandchild", "Sibling"])
        #expect(FolderTree.ordered(groups).map(\.depth) == [0, 1, 2, 0])
        #expect(FolderTree.indent(forDepth: 2) == 28)
    }

    @Test("A cycle from a corrupt session is drawn as roots rather than hanging")
    func cyclesTerminate() {
        let a = folder("A")
        let b = folder("B")
        a.parentID = b.id
        b.parentID = a.id
        let groups = [a, b]

        #expect(FolderTree.depth(of: a, in: groups) == 1)
        #expect(FolderTree.ordered(groups).count == 2)
    }

    @Test("A folder whose parent was deleted becomes a root")
    func orphanBecomesRoot() {
        let orphan = TabGroup(name: "Orphan", parentID: UUID())
        #expect(FolderTree.ordered([orphan]).map(\.depth) == [0])
        #expect(FolderTree.isVisible(orphan, in: [orphan]))
    }

    @Test("The depth cap stops new subfolders at level four")
    func subfolderCap() {
        var chain: [TabGroup] = [folder("L0")]
        for level in 1..<FolderTree.maximumDepth {
            chain.append(folder("L\(level)", parent: chain[level - 1]))
        }
        #expect(FolderTree.canAcceptSubfolder(chain[3], in: chain))
        #expect(FolderTree.canAcceptSubfolder(chain[4], in: chain) == false)
    }

    @Test("A move that would push a subtree past the cap is refused")
    func nestingRespectsSubtreeHeight() {
        let deep = folder("Deep")
        let deeper = folder("Deeper", parent: deep)
        let l0 = folder("L0")
        let l1 = folder("L1", parent: l0)
        let l2 = folder("L2", parent: l1)
        let groups = [deep, deeper, l0, l1, l2]

        #expect(FolderTree.subtreeHeight(of: deep, in: groups) == 2)
        // Landing at level 3 with a two-level subtree fits; level 4 does not.
        #expect(FolderTree.canNest(deep, under: l2, in: groups))
        let l3 = folder("L3", parent: l2)
        #expect(FolderTree.canNest(deep, under: l3, in: groups + [l3]) == false)
    }

    @Test("A folder cannot be filed inside its own subtree")
    func nestingRefusesCycles() {
        let parent = folder("Parent")
        let child = folder("Child", parent: parent)
        let groups = [parent, child]

        #expect(FolderTree.canNest(parent, under: child, in: groups) == false)
        #expect(FolderTree.canNest(parent, under: parent, in: groups) == false)
        #expect(FolderTree.nest(parent, under: child, in: groups) == false)
        #expect(parent.parentID == nil)
    }

    @Test("Creating a subfolder reveals every collapsed ancestor")
    func revealAncestors() {
        let root = folder("Root")
        root.isCollapsed = true
        let child = folder("Child", parent: root)
        child.isCollapsed = true
        let grandchild = folder("Grandchild", parent: child)

        FolderTree.revealAncestors(of: grandchild, in: [root, child, grandchild])
        #expect(root.isCollapsed == false)
        #expect(child.isCollapsed == false)
    }
}

@Suite("Folder rows")
@MainActor
struct FolderRowPlanTests {
    private func url(_ string: String) -> URL { URL(string: string)! }

    private func tab(_ session: BrowserSession, _ address: String, in group: TabGroup?) -> Tab {
        let tab = session.newTab(url: url(address), select: false)
        tab.setGroupID(group?.id)
        return tab
    }

    @Test("A collapsed folder hides its tabs")
    func collapseHidesTabs() {
        let session = TestSession.make().0
        let folder = TabGroup(name: "Work")
        let inside = tab(session, "https://a.example", in: folder)
        folder.isCollapsed = true

        let rows = FolderRowPlan.rows(
            groups: [folder],
            tabs: [inside],
            activeTabID: nil
        )
        #expect(rows.count == 1)
        #expect(rows.first == .folder(folder, depth: 0, showsEscapedTab: false))
    }

    @Test("The selected tab escapes its collapsed folder and keeps its indent")
    func activeTabEscapes() {
        let session = TestSession.make().0
        let folder = TabGroup(name: "Work")
        let first = tab(session, "https://a.example", in: folder)
        let second = tab(session, "https://b.example", in: folder)
        folder.isCollapsed = true

        let rows = FolderRowPlan.rows(groups: [folder], tabs: [first, second], activeTabID: second.id)
        #expect(rows.count == 2)
        #expect(rows[0] == .folder(folder, depth: 0, showsEscapedTab: true))
        #expect(rows[1] == .tab(second, depth: 1, isEscaping: true))
    }

    @Test("Nested collapse shows the escaping tab exactly once, under the outermost folder")
    func escapeIsEmittedOnce() {
        let session = TestSession.make().0
        let outer = TabGroup(name: "Outer")
        let inner = TabGroup(name: "Inner", parentID: outer.id)
        outer.isCollapsed = true
        inner.isCollapsed = true
        let deep = tab(session, "https://deep.example", in: inner)

        let rows = FolderRowPlan.rows(groups: [outer, inner], tabs: [deep], activeTabID: deep.id)
        #expect(rows.count == 2)
        #expect(rows[0] == .folder(outer, depth: 0, showsEscapedTab: true))
        #expect(rows[1] == .tab(deep, depth: 2, isEscaping: true))
    }

    @Test("An open folder lists its tabs and ungrouped tabs come last")
    func expandedOrder() {
        let session = TestSession.make().0
        let folder = TabGroup(name: "Work")
        let loose = session.activeSpace.tabs[0]
        let inside = tab(session, "https://a.example", in: folder)

        let rows = FolderRowPlan.rows(groups: [folder], tabs: [loose, inside], activeTabID: nil)
        #expect(rows == [
            .folder(folder, depth: 0, showsEscapedTab: false),
            .tab(inside, depth: 1, isEscaping: false),
            .tab(loose, depth: 0, isEscaping: false)
        ])
    }
}

@Suite("Folder drop zones")
@MainActor
struct FolderDropZoneTests {
    private func session() -> BrowserSession { TestSession.make().0 }

    @Test("The top fifth of a header always means into the folder")
    func topStripIsAlwaysInto() {
        let browser = session()
        let dragged = browser.activeSpace.tabs[0]
        let folder = TabGroup(name: "Work")

        for collapsed in [true, false] {
            folder.isCollapsed = collapsed
            let target = FolderDropZone.target(
                fractionFromTop: 0.05,
                folder: folder,
                tabCount: 9,
                payload: .tab(dragged),
                groups: [folder]
            )
            #expect(target == .intoFolderAtStart(folder.id))
            #expect(target.highlightsFolder)
        }
    }

    @Test("The bottom fifth is a sibling only when the folder is open and not nearly empty")
    func bottomStripIsAsymmetric() {
        let browser = session()
        let dragged = browser.activeSpace.tabs[0]
        let folder = TabGroup(name: "Work")

        let open = FolderDropZone.target(
            fractionFromTop: 0.95, folder: folder, tabCount: 4,
            payload: .tab(dragged), groups: [folder]
        )
        #expect(open == .afterFolder(folder.id))
        #expect(open.highlightsFolder == false)

        folder.isCollapsed = true
        let collapsed = FolderDropZone.target(
            fractionFromTop: 0.95, folder: folder, tabCount: 4,
            payload: .tab(dragged), groups: [folder]
        )
        #expect(collapsed == .intoFolderAtEnd(folder.id))

        folder.isCollapsed = false
        let nearlyEmpty = FolderDropZone.target(
            fractionFromTop: 0.95, folder: folder, tabCount: 1,
            payload: .tab(dragged), groups: [folder]
        )
        #expect(nearlyEmpty == .intoFolderAtEnd(folder.id))
    }

    @Test("The middle of the header is into the folder")
    func middleIsInto() {
        let browser = session()
        let dragged = browser.activeSpace.tabs[0]
        let folder = TabGroup(name: "Work")
        let target = FolderDropZone.target(
            fractionFromTop: 0.5, folder: folder, tabCount: 4,
            payload: .tab(dragged), groups: [folder]
        )
        #expect(target == .intoFolderAtEnd(folder.id))
    }

    @Test("View coordinates map to the same answer in both flipped senses")
    func coordinateConversion() {
        let browser = session()
        let dragged = browser.activeSpace.tabs[0]
        let folder = TabGroup(name: "Work")
        let bounds = NSRect(x: 0, y: 0, width: 200, height: 40)

        let flipped = FolderDropZone.target(
            at: NSPoint(x: 10, y: 4), in: bounds, isFlipped: true,
            folder: folder, tabCount: 4, payload: .tab(dragged), groups: [folder]
        )
        let unflipped = FolderDropZone.target(
            at: NSPoint(x: 10, y: 36), in: bounds, isFlipped: false,
            folder: folder, tabCount: 4, payload: .tab(dragged), groups: [folder]
        )
        #expect(flipped == .intoFolderAtStart(folder.id))
        #expect(unflipped == .intoFolderAtStart(folder.id))
    }

    @Test("A folder that cannot take the payload still lets the drag past it")
    func refusalFallsThroughToSibling() {
        let live = TabGroup(name: "Pull Requests", isLive: true)
        let browser = session()
        let dragged = browser.activeSpace.tabs[0]

        #expect(FolderDropZone.accepts(.tab(dragged), folder: live, groups: [live]) == false)
        let onTop = FolderDropZone.target(
            fractionFromTop: 0.05, folder: live, tabCount: 4,
            payload: .tab(dragged), groups: [live]
        )
        #expect(onTop == .rejected)
        let onBottom = FolderDropZone.target(
            fractionFromTop: 0.95, folder: live, tabCount: 4,
            payload: .tab(dragged), groups: [live]
        )
        #expect(onBottom == .afterFolder(live.id))
    }

    @Test("A folder drop obeys the same depth cap as the menu item")
    func folderDropRespectsCap() {
        var chain: [TabGroup] = [TabGroup(name: "L0")]
        for level in 1..<FolderTree.maximumDepth {
            chain.append(TabGroup(name: "L\(level)", parentID: chain[level - 1].id))
        }
        let dragged = TabGroup(name: "Dragged")
        let groups = chain + [dragged]

        #expect(FolderDropZone.accepts(.folder(dragged), folder: chain[3], groups: groups))
        #expect(FolderDropZone.accepts(.folder(dragged), folder: chain[4], groups: groups) == false)
        let target = FolderDropZone.target(
            fractionFromTop: 0.5, folder: chain[4], tabCount: 0,
            payload: .folder(dragged), groups: groups
        )
        #expect(target == .rejected)
    }
}

@Suite("Live folder reconciliation")
struct LiveFolderStateTests {
    private func item(_ id: String, _ address: String = "https://example.com/1") -> LiveFolderItem {
        LiveFolderItem(id: id, title: id, url: URL(string: address)!, subtitle: nil, date: .now)
    }

    @Test("New items are additions and vanished ones are stale")
    func planAddsAndPrunes() {
        var state = LiveFolderState()
        let gone = UUID()
        state.trackedTabs = ["a": gone, "b": UUID()]

        let plan = state.plan(for: [item("b"), item("c")])
        #expect(plan.additions.map(\.id) == ["c"])
        #expect(plan.staleTabIDs == [gone])
    }

    @Test("A tab the user put in the folder is never pruned")
    func untrackedTabsSurvive() {
        var state = LiveFolderState()
        let providerTab = UUID()
        let userTab = UUID()
        state.trackedTabs = ["a": providerTab]

        let plan = state.plan(for: [])
        #expect(plan.staleTabIDs == [providerTab])
        #expect(plan.staleTabIDs.contains(userTab) == false)
        #expect(state.isTracked(tabID: userTab) == false)
    }

    @Test("A failed fetch changes no membership at all")
    func issueNeverPrunes() {
        var state = LiveFolderState()
        let tracked = UUID()
        state.trackedTabs = ["a": tracked]
        let before = state.trackedTabs

        state.noteIssue(.sourceUnavailable(status: 500))
        #expect(state.trackedTabs == before)
        #expect(state.lastIssue == .sourceUnavailable(status: 500))
        #expect(state.consecutiveFailures == 1)
    }

    @Test("A dismissed item is not offered again while the source still lists it")
    func dismissalSuppressesReadding() {
        var state = LiveFolderState()
        let tab = UUID()
        state.trackedTabs = ["a": tab]

        state.dismiss(tabID: tab)
        #expect(state.dismissedItems == ["a"])
        #expect(state.plan(for: [item("a")]).additions.isEmpty)
    }

    @Test("An empty response cannot wipe dismissals")
    func emptyResponseKeepsDismissals() {
        var state = LiveFolderState()
        state.dismissedItems = ["a"]

        #expect(state.plan(for: []).expiredDismissals.isEmpty)
        #expect(state.plan(for: [item("b")]).expiredDismissals == ["a"])
    }

    @Test("Applying a plan records what was opened and forgets what was closed")
    func applyUpdatesTracking() {
        var state = LiveFolderState()
        let stale = UUID()
        state.trackedTabs = ["a": stale]
        let plan = state.plan(for: [item("b")])
        let opened = UUID()

        state.apply(plan, openedTabs: ["b": opened])
        #expect(state.trackedTabs == ["b": opened])
        #expect(state.lastIssue == nil)
        #expect(state.consecutiveFailures == 0)
        #expect(state.lastFetched != nil)
    }

    @Test("An item that could not be opened is offered again next time")
    func unopenedItemsAreRetried() {
        var state = LiveFolderState()
        let plan = state.plan(for: [item("b")])
        state.apply(plan, openedTabs: [:])
        #expect(state.plan(for: [item("b")]).additions.map(\.id) == ["b"])
    }

    @Test("Failures back off and a stated retry delay wins")
    func schedulingBacksOff() {
        var state = LiveFolderState()
        state.interval = 600
        let now = Date()
        state.lastFetched = now

        #expect(state.nextFetchDelay(now: now) == 600)

        state.consecutiveFailures = 2
        #expect(state.nextFetchDelay(now: now) == 600 + 2400)

        state.lastIssue = .rateLimited(retryAfter: 900)
        #expect(state.nextFetchDelay(now: now) == 900)
    }

    @Test("A folder that has never fetched fetches immediately")
    func firstFetchIsImmediate() {
        let state = LiveFolderState()
        #expect(state.nextFetchDelay() == 0)
    }

    @Test("State survives a round trip through JSON")
    func codableRoundTrip() throws {
        var state = LiveFolderState()
        state.trackedTabs = ["a": UUID()]
        state.dismissedItems = ["b"]
        state.lastIssue = .rateLimited(retryAfter: 30)
        let record = LiveFolderRecord(
            id: UUID(),
            source: .rss(RSSLiveFolderProvider.Configuration(feedURL: URL(string: "https://example.com/feed")!)),
            state: state
        )

        let data = try JSONEncoder().encode([record])
        let decoded = try JSONDecoder().decode([LiveFolderRecord].self, from: data)
        #expect(decoded == [record])
    }
}

@Suite("Feed parsing")
struct FeedParserTests {
    @Test("RSS 2.0 entries become items")
    func parsesRSS() {
        let feed = """
        <?xml version="1.0"?>
        <rss version="2.0"><channel>
        <title>Example Feed</title>
        <item>
          <title>First</title>
          <link>https://example.com/1</link>
          <guid>tag:1</guid>
          <pubDate>Mon, 02 Jan 2006 15:04:05 +0000</pubDate>
        </item>
        </channel></rss>
        """
        let parsed = FeedParser.parse(feed)
        #expect(parsed?.title == "Example Feed")
        #expect(parsed?.entries.count == 1)
        #expect(parsed?.entries.first?.id == "tag:1")
        #expect(parsed?.entries.first?.url.absoluteString == "https://example.com/1")
    }

    @Test("Atom entries use the alternate link")
    func parsesAtom() {
        let feed = """
        <?xml version="1.0"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
        <title>Atom Feed</title>
        <entry>
          <title>Second</title>
          <link rel="edit" href="https://example.com/edit"/>
          <link rel="alternate" href="https://example.com/2"/>
          <id>urn:2</id>
          <updated>2024-03-01T10:00:00Z</updated>
        </entry>
        </feed>
        """
        let parsed = FeedParser.parse(feed)
        #expect(parsed?.entries.first?.url.absoluteString == "https://example.com/2")
        #expect(parsed?.entries.first?.title == "Second")
    }

    @Test("Entries a browser must not open are dropped")
    func rejectsDangerousSchemes() {
        let feed = """
        <rss version="2.0"><channel><title>T</title>
        <item><title>Bad</title><link>javascript:alert(1)</link>
        <pubDate>Mon, 02 Jan 2006 15:04:05 +0000</pubDate></item>
        <item><title>Also bad</title><link>file:///etc/passwd</link>
        <pubDate>Mon, 02 Jan 2006 15:04:05 +0000</pubDate></item>
        <item><title>Fine</title><link>https://example.com/ok</link>
        <pubDate>Mon, 02 Jan 2006 15:04:05 +0000</pubDate></item>
        </channel></rss>
        """
        let parsed = FeedParser.parse(feed)
        #expect(parsed?.entries.map(\.title) == ["Fine"])
    }

    @Test("An entry with no date is dropped rather than dated now")
    func requiresADate() {
        let feed = """
        <rss version="2.0"><channel><title>T</title>
        <item><title>Undated</title><link>https://example.com/x</link></item>
        </channel></rss>
        """
        #expect(FeedParser.parse(feed)?.entries.isEmpty == true)
    }

    @Test("A document that is not a feed is refused")
    func refusesNonFeeds() {
        #expect(FeedParser.parse("<html><body>nope</body></html>") == nil)
    }
}

@Suite("Live folder providers")
struct LiveFolderProviderTests {
    @Test("GitHub short-circuits when no filter is selected, without a request")
    func githubNoFilter() async {
        let provider = GitHubLiveFolderProvider(
            configuration: .init(login: "octocat", assignedMe: false)
        )
        let outcome = await provider.fetchItems(using: LiveFolderFetcher())
        #expect(outcome == .blocked(.noFilterSelected))
    }

    @Test("GitHub without an account is unconfigured, not broken")
    func githubNoAccount() async {
        let provider = GitHubLiveFolderProvider(configuration: .init(login: "   "))
        let outcome = await provider.fetchItems(using: LiveFolderFetcher())
        #expect(outcome == .blocked(.notConfigured))
    }

    @Test("A feed URL that is not http(s) never reaches the network")
    func rssRejectsBadScheme() async {
        let provider = RSSLiveFolderProvider(
            configuration: .init(feedURL: URL(string: "file:///etc/passwd")!)
        )
        let outcome = await provider.fetchItems(using: LiveFolderFetcher())
        #expect(outcome == .blocked(.notConfigured))
    }

    @Test("Toggling an option produces a new configuration")
    func optionsAreImmutable() {
        let provider = GitHubLiveFolderProvider(configuration: .init(login: "octocat"))
        let updated = provider.applying(LiveFolderOptionChange(key: "authorMe", value: .bool(true)))
        #expect(provider.configuration.authorMe == false)
        guard case .github(let configuration) = updated.source else {
            Issue.record("expected a GitHub source")
            return
        }
        #expect(configuration.authorMe)
    }

    @Test("Excluding a repository is a toggle keyed by its name")
    func repositoryExclusion() {
        let provider = GitHubLiveFolderProvider(
            configuration: .init(login: "octocat", knownRepositories: ["a/b"])
        )
        let updated = provider.applying(LiveFolderOptionChange(key: "repo:a/b", value: .bool(false)))
        guard case .github(let configuration) = updated.source else {
            Issue.record("expected a GitHub source")
            return
        }
        #expect(configuration.excludedRepositories == ["a/b"])
    }

    @Test("A GitHub fetch teaches the configuration which repositories exist")
    func learnsRepositories() {
        let provider = GitHubLiveFolderProvider(configuration: .init(login: "octocat"))
        let items = [
            LiveFolderItem(
                id: "octo/repo#1", title: "PR",
                url: URL(string: "https://github.com/octo/repo/pull/1")!,
                subtitle: "octocat", date: nil
            )
        ]
        guard case .github(let configuration) = provider.learning(from: items).source else {
            Issue.record("expected a GitHub source")
            return
        }
        #expect(configuration.knownRepositories == ["octo/repo"])
    }

    @Test("An RSS folder is named after its feed once it has one")
    func rssMetadata() {
        var configuration = RSSLiveFolderProvider.Configuration(
            feedURL: URL(string: "https://news.example.com/feed.xml")!
        )
        #expect(RSSLiveFolderProvider(configuration: configuration).metadata.name == "news.example.com")
        configuration.feedTitle = "Example News"
        #expect(RSSLiveFolderProvider(configuration: configuration).metadata.name == "Example News")
    }
}

@Suite("Live folder fetching")
struct LiveFolderFetcherTests {
    @Test("A declared charset beats the transport header")
    func honoursDeclaredCharset() {
        let body = "<?xml version=\"1.0\" encoding=\"iso-8859-1\"?><rss><title>caf\u{e9}</title></rss>"
        let data = body.data(using: .isoLatin1)!
        let text = LiveFolderFetcher.decode(data, response: nil)
        #expect(text.contains("café"))
    }

    @Test("A byte-order mark wins outright")
    func honoursBOM() {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append("héllo".data(using: .utf8)!)
        #expect(LiveFolderFetcher.decode(data, response: nil) == "héllo")
    }

    @Test("Undeclared bytes decode as UTF-8")
    func defaultsToUTF8() {
        let data = "plain".data(using: .utf8)!
        #expect(LiveFolderFetcher.decode(data, response: nil) == "plain")
    }

    @Test("Transport failures become displayable states, and a rate limit blocks retries")
    func failureMapping() {
        #expect(LiveFolderIssue.from(.notFound) == .sourceUnavailable(status: 404))
        #expect(LiveFolderIssue.from(.tooLarge) == .malformedResponse)
        let limited = LiveFolderIssue.from(.rateLimited(retryAfter: 60))
        #expect(limited.allowsImmediateRetry == false)
        #expect(LiveFolderIssue.network("offline").allowsImmediateRetry)
    }
}

@Suite("Folder presentation")
@MainActor
struct FolderPresentationTests {
    @Test("A folder with an emoji draws the emoji, and one without draws the plate")
    func iconSelection() {
        let plain = TabGroup(name: "Work")
        #expect(plain.icon == .automatic)

        let emoji = TabGroup(name: "Work", emoji: "🔬")
        #expect(emoji.icon == .emoji("🔬"))

        let symbol = TabGroup(name: "Work", symbolName: "hammer")
        #expect(symbol.icon == .symbol("hammer"))
    }

    @Test("Every icon renders at the 28-point well")
    func iconSize() {
        for icon in [FolderIcon.automatic, .emoji("🔬"), .symbol("hammer"), .symbol("not.a.real.symbol")] {
            let image = icon.image(tint: .systemBlue)
            #expect(image.size.width == FolderIcon.side)
            #expect(image.size.height == FolderIcon.side)
        }
    }

    @Test("The popup matches titles, hosts and paths")
    func popupSearchText() {
        let item = FolderTabsItem(
            tabID: UUID(),
            url: URL(string: "https://news.example.com/world/story")!,
            title: "A Headline",
            lastActiveAt: .now,
            folderName: "Reading",
            webView: nil,
            isPrivate: false
        )
        #expect(item.searchText.contains("headline"))
        #expect(item.searchText.contains("news.example.com"))
        #expect(item.searchText.contains("/world/story"))
    }

    @Test("The options menu is the manager's two items plus the provider's own")
    func optionsMenu() {
        let manager = LiveFolderManager(store: LiveFolderStore(fileURL: FileManager.default
            .temporaryDirectory.appending(path: "kylmora-live-\(UUID().uuidString).json")))
        let folderID = UUID()
        manager.add(
            folderID: folderID,
            source: .rss(RSSLiveFolderProvider.Configuration(feedURL: URL(string: "file:///nope")!))
        )
        let keys = manager.options(for: folderID).compactMap { option -> String? in
            switch option {
            case .action(let key, _), .toggle(let key, _, _), .choice(let key, _, _, _): return key
            case .submenu, .separator: return nil
            }
        }
        #expect(keys.prefix(2) == ["refresh", "interval"])
        #expect(keys.contains("maxItems"))
        manager.remove(folderID: folderID)
        manager.stop()
    }
}

@Suite("Dropping tabs into and out of folders")
@MainActor
struct TabDropPlanTests {
    private func url(_ string: String) -> URL { URL(string: string)! }

    /// The sidebar's rows, the way the sidebar itself builds them.
    private func rows(_ session: BrowserSession) -> [TabDropPlan.Row] {
        let space = session.activeSpace
        return FolderRowPlan.rows(groups: space.groups, tabs: space.tabs, activeTabID: space.activeTabID).map {
            switch $0 {
            case .folder(let folder, let depth, _): return .folder(folder, depth: depth)
            case .tab(let tab, let depth, let isEscaping): return .tab(tab, depth: depth, isEscaping: isEscaping)
            }
        } + [.other(depth: 0)]
    }

    /// One folder holding two tabs, then two loose tabs. Rows: header, a, b,
    /// loose1, loose2, New Tab.
    private func session() -> (BrowserSession, TabGroup, [Tab]) {
        let session = TestSession.make().0
        let a = session.newTab(url: url("https://a.example"))
        let b = session.newTab(url: url("https://b.example"))
        let loose1 = session.newTab(url: url("https://c.example"))
        let loose2 = session.newTab(url: url("https://d.example"))
        session.closeTab(session.activeSpace.tabs[0])
        let folder = session.createGroup(named: "Work", containing: [a, b])
        return (session, folder, [a, b, loose1, loose2])
    }

    @Test("Above a folder's child lands in that folder, beside the child")
    func aboveChildFilesIntoFolder() {
        let (session, folder, tabs) = session()
        let space = session.activeSpace
        let plan = TabDropPlan.between(rows: rows(session), row: 2, tabs: space.tabs, groups: space.groups)
        #expect(plan == TabDropPlan.Destination(groupID: folder.id, tabIndex: space.index(of: tabs[1])!))
    }

    @Test("Above a loose tab pulls the tab out to the top level")
    func aboveLooseTabLeavesFolder() {
        let (session, _, tabs) = session()
        let space = session.activeSpace
        let plan = TabDropPlan.between(rows: rows(session), row: 3, tabs: space.tabs, groups: space.groups)
        #expect(plan == TabDropPlan.Destination(groupID: nil, tabIndex: space.index(of: tabs[2])!))
    }

    @Test("Above the New Tab row, and past the end, is the top level at the end")
    func endIsTopLevel() {
        let (session, _, _) = session()
        let space = session.activeSpace
        let all = rows(session)
        #expect(TabDropPlan.between(rows: all, row: all.count - 1, tabs: space.tabs, groups: space.groups)
                == TabDropPlan.Destination(groupID: nil, tabIndex: space.tabs.count))
        #expect(TabDropPlan.between(rows: all, row: all.count, tabs: space.tabs, groups: space.groups)
                == TabDropPlan.Destination(groupID: nil, tabIndex: space.tabs.count))
    }

    @Test("Above a folder header is the header's own level")
    func aboveHeaderIsParentLevel() {
        let (session, _, _) = session()
        let space = session.activeSpace
        let plan = TabDropPlan.between(rows: rows(session), row: 0, tabs: space.tabs, groups: space.groups)
        #expect(plan?.groupID == nil)
        #expect(plan?.tabIndex == 0)
    }

    @Test("Onto a header files at the start or the end of the folder's own tabs")
    func ontoHeader() {
        let (session, folder, tabs) = session()
        let space = session.activeSpace
        let start = TabDropPlan.onto(folder: folder, target: .intoFolderAtStart(folder.id), tabs: space.tabs, groups: space.groups)
        #expect(start == TabDropPlan.Destination(groupID: folder.id, tabIndex: space.index(of: tabs[0])!))
        let end = TabDropPlan.onto(folder: folder, target: .intoFolderAtEnd(folder.id), tabs: space.tabs, groups: space.groups)
        #expect(end == TabDropPlan.Destination(groupID: folder.id, tabIndex: space.index(of: tabs[1])! + 1))
    }

    @Test("After a folder is past its whole subtree, at the parent's level")
    func afterFolderSkipsSubtree() {
        let (session, folder, tabs) = session()
        let space = session.activeSpace
        let after = TabDropPlan.onto(folder: folder, target: .afterFolder(folder.id), tabs: space.tabs, groups: space.groups)
        #expect(after == TabDropPlan.Destination(groupID: nil, tabIndex: space.index(of: tabs[1])! + 1))
        // The row a sibling drop is drawn above: the first loose tab.
        #expect(TabDropPlan.rowAfterBlock(of: 0, rows: rows(session)) == 3)
    }

    @Test("A live folder's children cannot be dropped between")
    func liveFolderRefuses() {
        let session = TestSession.make().0
        let tab = session.newTab(url: url("https://a.example"))
        let live = TabGroup(name: "Feed", isLive: true)
        session.activeSpace.addGroup(live)
        tab.setGroupID(live.id)
        let all: [TabDropPlan.Row] = [.folder(live, depth: 0), .tab(tab, depth: 1, isEscaping: false), .other(depth: 0)]
        let space = session.activeSpace
        #expect(TabDropPlan.between(rows: all, row: 1, tabs: space.tabs, groups: space.groups) == nil)
        #expect(TabDropPlan.onto(folder: live, target: .rejected, tabs: space.tabs, groups: space.groups) == nil)
    }

    @Test("A drop, applied, moves the tab into the folder and back out")
    func appliedMovesFolders() {
        let (session, folder, tabs) = session()
        let space = session.activeSpace
        let loose = tabs[2]
        // In: above the folder's first child.
        var plan = TabDropPlan.between(rows: rows(session), row: 1, tabs: space.tabs, groups: space.groups)!
        session.moveTab(from: space.index(of: loose)!, to: plan.tabIndex)
        session.move(loose, to: space.group(withID: plan.groupID!))
        #expect(loose.groupID == folder.id)
        #expect(space.tabs(in: folder).first === loose)

        // Out: at the end.
        let all = rows(session)
        plan = TabDropPlan.between(rows: all, row: all.count, tabs: space.tabs, groups: space.groups)!
        session.moveTab(from: space.index(of: loose)!, to: plan.tabIndex)
        session.move(loose, to: nil)
        #expect(loose.groupID == nil)
        #expect(space.tabs.last === loose)
    }
}

@Suite("Folder plates")
@MainActor
struct FolderPlatePlanTests {
    private func tab(_ name: String) -> Tab {
        Tab(url: URL(string: "https://\(name).example")!, identity: .standard)
    }

    @Test("A folder and its children share one plate, top to bottom")
    func oneBlock() {
        let folder = TabGroup(name: "Work")
        let rows: [TabDropPlan.Row] = [
            .folder(folder, depth: 0),
            .tab(tab("a"), depth: 1, isEscaping: false),
            .tab(tab("b"), depth: 1, isEscaping: false),
            .tab(tab("loose"), depth: 0, isEscaping: false),
            .other(depth: 0)
        ]
        let pieces = FolderPlatePlan.pieces(for: rows)
        #expect(pieces == [
            [FolderPlatePlan.Piece(depth: 0, segment: .top, groupID: folder.id)],
            [FolderPlatePlan.Piece(depth: 0, segment: .middle, groupID: folder.id)],
            [FolderPlatePlan.Piece(depth: 0, segment: .bottom, groupID: folder.id)],
            [],
            []
        ])
    }

    @Test("A collapsed or empty folder is a plate one row tall")
    func singleRowPlate() {
        let folder = TabGroup(name: "Work", isCollapsed: true)
        let rows: [TabDropPlan.Row] = [.folder(folder, depth: 0), .other(depth: 0)]
        #expect(FolderPlatePlan.pieces(for: rows) == [[FolderPlatePlan.Piece(depth: 0, segment: .single, groupID: folder.id)], []])
    }

    @Test("A nested folder draws its own plate on top of its parent's")
    func nestedPlates() {
        let outer = TabGroup(name: "Outer")
        let inner = TabGroup(name: "Inner", parentID: outer.id)
        let rows: [TabDropPlan.Row] = [
            .folder(outer, depth: 0),
            .tab(tab("a"), depth: 1, isEscaping: false),
            .folder(inner, depth: 1),
            .tab(tab("b"), depth: 2, isEscaping: false),
            .other(depth: 0)
        ]
        let pieces = FolderPlatePlan.pieces(for: rows)
        #expect(pieces[0] == [FolderPlatePlan.Piece(depth: 0, segment: .top, groupID: outer.id)])
        #expect(pieces[1] == [FolderPlatePlan.Piece(depth: 0, segment: .middle, groupID: outer.id)])
        #expect(pieces[2] == [
            FolderPlatePlan.Piece(depth: 0, segment: .middle, groupID: outer.id),
            FolderPlatePlan.Piece(depth: 1, segment: .top, groupID: inner.id)
        ])
        #expect(pieces[3] == [
            FolderPlatePlan.Piece(depth: 0, segment: .bottom, groupID: outer.id),
            FolderPlatePlan.Piece(depth: 1, segment: .bottom, groupID: inner.id)
        ])
        #expect(pieces[4].isEmpty)
    }

    @Test("The plate ends at the last row of the list when the folder is last")
    func folderAtEnd() {
        let folder = TabGroup(name: "Work")
        let rows: [TabDropPlan.Row] = [.folder(folder, depth: 0), .tab(tab("a"), depth: 1, isEscaping: false)]
        #expect(FolderPlatePlan.pieces(for: rows) == [
            [FolderPlatePlan.Piece(depth: 0, segment: .top, groupID: folder.id)],
            [FolderPlatePlan.Piece(depth: 0, segment: .bottom, groupID: folder.id)]
        ])
    }
}
