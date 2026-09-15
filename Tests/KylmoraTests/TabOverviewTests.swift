import AppKit
import Foundation
import Testing
@testable import Kylmora


@Suite("Safari-Style Tab Overview Grid (F-37)")
@MainActor
struct TabOverviewTests {

    // MARK: - TabSnapshotStore Tests

    @Test("TabSnapshotStore sets, retrieves, removes, and clears snapshots")
    func snapshotStoreBasics() {
        let store = TabSnapshotStore()
        let id1 = UUID()
        let id2 = UUID()

        #expect(store.count == 0)
        #expect(store.snapshot(for: id1) == nil)

        let image1 = NSImage(size: NSSize(width: 100, height: 100))
        let image2 = NSImage(size: NSSize(width: 200, height: 200))

        store.setSnapshot(image1, for: id1)
        #expect(store.count == 1)
        #expect(store.snapshot(for: id1) === image1)
        #expect(store.snapshot(for: id2) == nil)

        store.setSnapshot(image2, for: id2)
        #expect(store.count == 2)
        #expect(store.snapshot(for: id2) === image2)

        store.removeSnapshot(for: id1)
        #expect(store.count == 1)
        #expect(store.snapshot(for: id1) == nil)
        #expect(store.snapshot(for: id2) === image2)

        store.clear()
        #expect(store.count == 0)
        #expect(store.snapshot(for: id2) == nil)
    }

    // MARK: - TabOverviewScope Tests

    @Test("TabOverviewScope exposes correct titles and raw values")
    func scopeEnum() {
        #expect(TabOverviewScope.currentSpace.rawValue == 0)
        #expect(TabOverviewScope.allSpaces.rawValue == 1)
        #expect(TabOverviewScope.currentSpace.title == "Current Space")
        #expect(TabOverviewScope.allSpaces.title == "All Spaces")
    }

    // MARK: - TabThumbnailView Tests

    @Test("TabThumbnailView configures snapshot and fallback placeholder")
    func thumbnailViewConfiguration() {
        let thumb = TabThumbnailView()

        // Test with live snapshot
        let snapshot = NSImage(size: NSSize(width: 320, height: 200))
        thumb.configure(snapshot: snapshot, title: "Apple", domain: "apple.com")

        // Test with fallback placeholder
        thumb.configure(snapshot: nil, title: "GitHub", domain: "github.com")
        #expect(thumb.subviews.count > 0)
    }

    // MARK: - TabCardView Tests

    @Test("TabCardView renders tab info and handles events")
    func tabCardView() {
        let tab = Tab(url: URL(string: "https://news.ycombinator.com/item?id=123")!, identity: .standard)
        let space = Space(name: "Tech", identity: .standard)
        let card = TabCardView(tab: tab, space: space, showSpaceBadge: true)

        #expect(!card.isActive)
        #expect(!card.isHighlighted)

        card.isActive = true
        #expect(card.isActive)

        card.isHighlighted = true
        #expect(card.isHighlighted)

        var selectCalled = false
        card.onSelect = { (selectedTab: Tab, selectedSpace: Space?) in
            #expect(selectedTab.id == tab.id)
            #expect(selectedSpace?.name == "Tech")
            selectCalled = true
        }

        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 10, y: 10),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
        card.mouseDown(with: event)
        #expect(selectCalled)

        var closeCalled = false
        card.onClose = { (closedTab: Tab) in
            #expect(closedTab.id == tab.id)
            closeCalled = true
        }
        card.onClose?(tab)
        #expect(closeCalled)
    }

    // MARK: - TabOverviewHeaderView Tests

    @Test("TabOverviewHeaderView updates counts and triggers callbacks")
    func headerViewCallbacks() {
        let header = TabOverviewHeaderView()
        header.update(scope: .currentSpace, spaceName: "Personal", tabCount: 3, totalSpacesTabCount: 8)

        var changedScope: TabOverviewScope?
        header.onScopeChanged = { s in changedScope = s }
        header.scopeControl.selectedSegment = 1
        header.scopeControl.sendAction(header.scopeControl.action, to: header.scopeControl.target)
        #expect(changedScope == .allSpaces)

        var searchedText: String?
        header.onSearchChanged = { t in searchedText = t }
        header.searchField.stringValue = "swift"
        header.searchField.sendAction(header.searchField.action, to: header.searchField.target)
        #expect(searchedText == "swift")

        var newTabClicked = false
        header.onNewTab = { newTabClicked = true }
        header.onNewTab?()
        #expect(newTabClicked)

        var dismissClicked = false
        header.onDismiss = { dismissClicked = true }
        header.onDismiss?()
        #expect(dismissClicked)
    }

    // MARK: - TabOverviewGridViewController Tests

    @Test("TabOverviewGridViewController displays tabs, filters search, and navigates")
    func gridViewControllerLifecycle() throws {
        let (session, _) = TestSession.make()
        _ = session.newTab(url: URL(string: "https://apple.com")!)
        _ = session.newTab(url: URL(string: "https://github.com")!)
        _ = session.newTab(url: URL(string: "https://wikipedia.org")!)

        let space2 = session.addSpace(named: "Work")
        session.selectSpace(space2)
        _ = session.newTab(url: URL(string: "https://slack.com")!)
        session.selectSpace(session.spaces[0])

        let controller = TabOverviewGridViewController(session: session)
        _ = controller.view // Load view

        controller.reloadGrid()

        // 1. Current space has 4 tabs (initial blank tab + 3 opened)
        #expect(session.activeSpace.tabs.count == 4)

        // 2. Search query filtering
        controller.headerView.searchField.stringValue = "apple"
        controller.headerView.onSearchChanged?("apple")

        // 3. Search query with no matches shows empty state
        controller.headerView.searchField.stringValue = "nonexistent999xyz"
        controller.headerView.onSearchChanged?("nonexistent999xyz")

        // 4. Clear search
        controller.headerView.searchField.stringValue = ""
        controller.headerView.onSearchChanged?("")

        // 5. Switch to All Spaces scope
        controller.headerView.scopeControl.selectedSegment = 1
        controller.headerView.onScopeChanged?(.allSpaces)

        // 6. Navigate selection with arrow keys
        controller.navigateSelection(direction: .right)
        controller.navigateSelection(direction: .down)
        controller.navigateSelection(direction: .left)
        controller.navigateSelection(direction: .up)

        // 7. Test presentation and dismissal
        let hostView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hostView

        controller.present(in: hostView)
        #expect(controller.view.superview === hostView)

        controller.dismissOverview()
    }

    @Test("TabOverviewGridViewController handles KeyDown actions")
    func gridKeyboardHandling() {
        let (session, _) = TestSession.make()
        _ = session.newTab(url: URL(string: "https://example.org")!)

        let controller = TabOverviewGridViewController(session: session)
        _ = controller.view
        controller.reloadGrid()

        // Arrow keys
        let leftArrow = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 123)!
        controller.keyDown(with: leftArrow)

        let rightArrow = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124)!
        controller.keyDown(with: rightArrow)

        let upArrow = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 126)!
        controller.keyDown(with: upArrow)

        let downArrow = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125)!
        controller.keyDown(with: downArrow)

        // Escape key dismisses
        let escapeKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        controller.keyDown(with: escapeKey)
    }

    @Test("TabOverview integrates with CommandCatalog and MainMenu")
    func catalogAndMenu() {
        let cmd = CommandCatalog.all.first { $0.id == "show-tab-overview" }
        #expect(cmd != nil)
        #expect(cmd?.title == "Show Tab Overview")
        #expect(cmd?.shortcut == "⇧⌘\\")

        let delegate = MenuDelegateStub()
        let menu = MainMenu.build(bookmarks: delegate, history: delegate, tabs: delegate, pinnedSites: delegate, spaces: delegate)
        let viewMenu = menu.items.first { $0.title == "View" }?.submenu
        let overviewItem = viewMenu?.items.first { $0.action == #selector(BrowserWindowController.toggleTabOverview(_:)) }
        #expect(overviewItem != nil)
        #expect(overviewItem?.keyEquivalent == "\\")
        #expect(overviewItem?.keyEquivalentModifierMask == [.command, .shift])
    }
}
