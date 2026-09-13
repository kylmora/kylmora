import AppKit
import Testing
import WebKit
@testable import Kylmora

// The placement and routing rules are pure, so they are exercised with values:
// no window, no screen, no session. The strip and the session's adoption are
// driven directly, which is what the UI layer is for.

@Suite("Little Arc placement")
struct LittleArcPlacementTests {
    /// A 16-inch MacBook Pro's visible area: 1512 wide, 946 tall.
    private let screen = NSRect(x: 0, y: 0, width: 1512, height: 946)

    @Test("The window opens at its own size, centred, and a little above centre")
    func centredAboveCentre() {
        let frame = LittleArcPlacement.frame(in: screen)
        #expect(frame.size == LittleArcMetrics.size)
        #expect(abs(frame.midX - screen.midX) <= 1)
        // Above centre, but not near the top: the nudge is a nudge.
        #expect(frame.midY > screen.midY)
        #expect(frame.midY < screen.midY + LittleArcMetrics.size.height * 0.25)
    }

    @Test("Every edge of the window keeps its margin from the screen")
    func keepsItsMargin() {
        let frame = LittleArcPlacement.frame(in: screen)
        #expect(frame.minX >= screen.minX + LittleArcMetrics.screenMargin)
        #expect(frame.maxX <= screen.maxX - LittleArcMetrics.screenMargin)
        #expect(frame.minY >= screen.minY + LittleArcMetrics.screenMargin)
        #expect(frame.maxY <= screen.maxY - LittleArcMetrics.screenMargin)
    }

    @Test("A screen smaller than the default shrinks the window instead of spilling off it")
    func smallScreen() {
        let small = NSRect(x: 0, y: 0, width: 520, height: 380)
        let frame = LittleArcPlacement.frame(in: small)
        #expect(frame.width <= small.width - LittleArcMetrics.screenMargin * 2)
        #expect(frame.height <= small.height - LittleArcMetrics.screenMargin * 2)
        #expect(frame.minX >= 0 && frame.maxX <= small.maxX)
        #expect(frame.minY >= 0 && frame.maxY <= small.maxY)
    }

    @Test("A screen too small even for the margins still gets a window that fits it")
    func tinyScreen() {
        let tiny = NSRect(x: 100, y: 50, width: 40, height: 30)
        let frame = LittleArcPlacement.frame(in: tiny)
        #expect(frame.width > 0 && frame.height > 0)
        #expect(frame.minX >= tiny.minX && frame.maxX <= tiny.maxX)
        #expect(frame.minY >= tiny.minY && frame.maxY <= tiny.maxY)
    }

    @Test("A display placed left of the main one is used, not pushed onto the main one")
    func negativeOriginScreen() {
        let second = NSRect(x: -1920, y: 0, width: 1512, height: 946)
        let frame = LittleArcPlacement.frame(in: second)
        #expect(abs(frame.midX - second.midX) <= 1)
        #expect(frame.minX >= second.minX + LittleArcMetrics.screenMargin)
        #expect(frame.maxX <= second.maxX - LittleArcMetrics.screenMargin)
    }

    @Test("A window never opens larger than the minimum it is allowed to be shrunk to")
    func minimumIsSmallerThanDefault() {
        #expect(LittleArcMetrics.minimumSize.width < LittleArcMetrics.size.width)
        #expect(LittleArcMetrics.minimumSize.height < LittleArcMetrics.size.height)
    }
}

@Suite("Where a link from another app goes")
struct LittleArcRoutingTests {
    @Test("The preference decides when nothing is held")
    func preferenceDecides() {
        #expect(LittleArcRouting.destination(for: .tab, shiftHeld: false) == .tab)
        #expect(LittleArcRouting.destination(for: .littleArc, shiftHeld: false) == .littleArc)
        #expect(LittleArcRouting.destination(for: .glance, shiftHeld: false) == .glance)
    }

    @Test("Shift overrides the preference, whatever it says")
    func shiftAlwaysATab() {
        for presentation in ExternalLinkPresentation.allCases {
            #expect(LittleArcRouting.destination(for: presentation, shiftHeld: true) == .tab)
        }
    }

    @Test("Every presentation has a name, because every one is a row in Settings")
    func presentationsAreNamed() {
        #expect(ExternalLinkPresentation.allCases.count == 3)
        #expect(ExternalLinkPresentation.allCases.allSatisfy { !$0.title.isEmpty })
    }
}

@Suite("The Little Arc setting")
@MainActor
struct LittleArcSettingsTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!
    }

    @Test("A fresh install opens links from other apps in a tab")
    func defaultsToATab() {
        #expect(Settings(defaults: defaults()).externalLinkPresentation == .tab)
    }

    @Test("The Glance checkbox this replaced is carried over rather than lost")
    func migratesTheOldCheckbox() {
        let store = defaults()
        store.set(true, forKey: "opensExternalLinksInGlance")
        #expect(Settings(defaults: store).externalLinkPresentation == .glance)
    }

    @Test("The carry-over happens once, and a later change of mind stands")
    func migratesOnce() {
        let store = defaults()
        store.set(true, forKey: "opensExternalLinksInGlance")
        #expect(Settings(defaults: store).externalLinkPresentation == .glance)

        Settings(defaults: store).externalLinkPresentation = .littleArc
        store.set(false, forKey: "opensExternalLinksInGlance")
        #expect(Settings(defaults: store).externalLinkPresentation == .littleArc)
    }

    @Test("The choice round-trips")
    func roundTrips() {
        let store = defaults()
        Settings(defaults: store).externalLinkPresentation = .littleArc
        #expect(Settings(defaults: store).externalLinkPresentation == .littleArc)
    }

    @Test("An unreadable value falls back to a tab rather than to nothing")
    func unreadableValueFallsBack() {
        let store = defaults()
        store.set("something else", forKey: "externalLinkPresentation")
        #expect(Settings(defaults: store).externalLinkPresentation == .tab)
    }
}

@Suite("Little Arc top bar")
@MainActor
struct LittleArcTopBarTests {
    private let owner = UUID()
    private let other = UUID()

    private func choices() -> [LittleArcTopBar.SpaceChoice] {
        [
            LittleArcTopBar.SpaceChoice(id: owner, title: "Personal", image: nil, isOwner: true),
            LittleArcTopBar.SpaceChoice(id: other, title: "Work", image: nil, isOwner: false)
        ]
    }

    @Test("The strip shows what the page is, and offers every space")
    func showsThePageAndSpaces() {
        let bar = LittleArcTopBar()
        bar.show(title: "Example Domain", address: "example.com/a/b", spaces: choices())
        #expect(bar.titleLabel.stringValue == "Example Domain")
        #expect(bar.addressLabel.stringValue == "example.com/a/b")
        #expect(bar.choices.count == 2)
        #expect(bar.moveButton.isEnabled)
    }

    @Test("The space the page is already in is the one marked as kept")
    func ownerIsMarked() {
        let bar = LittleArcTopBar()
        bar.show(title: "Example", address: "example.com", spaces: choices())
        #expect(bar.ownerSpaceID == owner)
    }

    @Test("Choosing a space reports it, and a space never offered is refused")
    func choiceIsReported() {
        let bar = LittleArcTopBar()
        var moved: [UUID] = []
        bar.onMove = { moved.append($0) }
        bar.show(title: "Example", address: "example.com", spaces: choices())

        bar.move(to: other)
        #expect(moved == [other])
        // A space removed from the browser while the window was open must not
        // be keepable.
        bar.move(to: UUID())
        #expect(moved == [other])
    }

    @Test("With no spaces there is nothing to move the page to")
    func noSpaces() {
        let bar = LittleArcTopBar()
        bar.show(title: "Example", address: "example.com", spaces: [])
        #expect(bar.ownerSpaceID == nil)
        #expect(bar.moveButton.isEnabled == false)
    }

    @Test("Reload becomes stop while the page is loading, in symbol and label together")
    func reloadBecomesStop() {
        let bar = LittleArcTopBar()
        bar.setLoading(true)
        #expect(bar.reloadButton.accessibilityLabel() == "Stop Loading")
        #expect(bar.reloadButton.toolTip == "Stop Loading")
        bar.setLoading(false)
        #expect(bar.reloadButton.accessibilityLabel() == "Reload")
        #expect(bar.reloadButton.toolTip == "Reload")
    }

    @Test("Space menu items carry ⌘1..⌘9 shortcuts for fast routing")
    func spaceShortcutsAttached() {
        let bar = LittleArcTopBar()
        bar.show(title: "Example", address: "example.com", spaces: choices())
        let items = bar.moveButton.menu?.items ?? []
        let spaceItems = items.filter { $0.representedObject != nil }
        #expect(spaceItems.count == 2)
        #expect(spaceItems[0].keyEquivalent == "1")
        #expect(spaceItems[0].keyEquivalentModifierMask == [.command])
        #expect(spaceItems[1].keyEquivalent == "2")
        #expect(spaceItems[1].keyEquivalentModifierMask == [.command])
    }

    @Test("The strip is as tall as the browser window's own bar")
    func matchesTheTopBar() {
        let bar = LittleArcTopBar()
        bar.frame = NSRect(x: 0, y: 0, width: 720, height: Style.Metrics.topBarHeight)
        bar.layoutSubtreeIfNeeded()
        let height = bar.constraints
            .first { $0.firstAttribute == .height }?
            .constant
        #expect(height == Style.Metrics.topBarHeight)
    }
}

@Suite("Keeping a Little Arc page")
@MainActor
struct LittleArcSessionTests {
    private func url(_ string: String) -> URL { URL(string: string)! }

    @Test("A page kept where it was loaded keeps the live page: no reload, no lost scroll")
    func keepsTheLivePage() {
        let session = TestSession.make().0
        let space = session.activeSpace
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())

        let tab = session.adoptLittleArcPage(
            webView,
            loadedAs: space.identity,
            url: url("https://example.com/read"),
            into: space
        )

        #expect(tab.currentWebView === webView)
        #expect(space.tabs.last === tab)
        #expect(session.activeTab === tab)
    }

    @Test("A page kept in another space opens again there, under that space's cookies")
    func carriesAcrossSpaces() {
        let session = TestSession.make().0
        let origin = session.activeSpace
        let destination = session.addSpace(named: "Work")
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())

        let tab = session.adoptLittleArcPage(
            webView,
            loadedAs: origin.identity,
            url: url("https://example.com/read"),
            into: destination
        )

        // Not adopted: a web view is bound to its data store, so the page is
        // loaded fresh rather than carrying the wrong space's logins with it.
        #expect(tab.currentWebView !== webView)
        #expect(tab.url == url("https://example.com/read"))
        #expect(tab.identity == destination.identity)
        #expect(destination.tabs.last === tab)
    }

    @Test("Keeping a page shows the user where it went")
    func showsTheDestination() {
        let session = TestSession.make().0
        let origin = session.activeSpace
        let destination = session.addSpace(named: "Work")

        session.adoptLittleArcPage(
            WKWebView(frame: .zero, configuration: WKWebViewConfiguration()),
            loadedAs: origin.identity,
            url: url("https://example.com/read"),
            into: destination
        )

        #expect(session.activeSpaceID == destination.id)
        #expect(session.activeTab?.url == url("https://example.com/read"))
    }
}

@Suite("Quitting with a Little Arc open")
struct QuitWarningTests {
    @Test("One tab on a start page is nothing to lose, so nothing is asked")
    func silentWhenNothingToLose() {
        #expect(QuitWarning.message(tabs: 1, littleArcs: 0) == nil)
        #expect(QuitWarning.message(tabs: 0, littleArcs: 0) == nil)
    }

    @Test("Tabs are named, and said to come back")
    func tabsAreNamed() {
        #expect(QuitWarning.message(tabs: 4, littleArcs: 0)?.contains("4 tabs") == true)
    }

    @Test("A little window is named too, because its page is not coming back")
    func littleArcIsNamed() {
        let one = QuitWarning.message(tabs: 1, littleArcs: 1)
        #expect(one?.contains("Little Arc window") == true)
        #expect(one?.contains("not kept") == true)

        let several = QuitWarning.message(tabs: 3, littleArcs: 2)
        #expect(several?.contains("3 tabs") == true)
        #expect(several?.contains("2 Little Arc windows") == true)
    }

    @Test("Every window is counted, not just the one in front")
    func countsEveryWindow() {
        let message = QuitWarning.message(tabs: 1, littleArcs: 5)
        #expect(message?.contains("5 Little Arc windows") == true)
    }
}

@Suite("The Little Arc coordinator")
@MainActor
struct LittleArcCoordinatorTests {
    @Test("A link that is not a page never gets a little window")
    func refusesOtherSchemes() {
        let session = TestSession.make().0
        let arcs = LittleArcCoordinator(session: session)

        arcs.open(url: URL(string: "javascript:alert(1)")!, in: session.activeSpace)
        arcs.open(url: URL(string: "data:text/html,hi")!, in: session.activeSpace)
        arcs.open(url: URL(string: "blob:https://example.com/1")!, in: session.activeSpace)

        #expect(arcs.openCount == 0)
        #expect(arcs.openPageURLs.isEmpty)
    }
}
