import AppKit
import Foundation
import Testing
@testable import Kylmora

/// The arithmetic behind the Task Manager's three scopes.
///
/// A live browser is the worst place to check this: no two readings are the
/// same, so a total that is three times too big because tabs sharing a WebKit
/// process were counted three times looks exactly like a browser that is busy.
@Suite("Activity scopes")
@MainActor
struct ActivityScopeTests {
    private func usage(
        title: String,
        space: UUID,
        pid: pid_t?,
        memoryMB: UInt64,
        cpu: Double = 0,
        suspended: Bool = false,
        audible: Bool = false
    ) -> TabResourceUsage {
        TabResourceUsage(
            tabId: UUID(),
            title: title,
            url: URL(string: "https://\(title).example"),
            domain: "\(title).example",
            spaceName: "Space",
            spaceID: space,
            isSuspended: suspended,
            isPlayingAudio: audible,
            pid: pid,
            memoryBytes: memoryMB * 1024 * 1024,
            cpuPercentage: cpu,
            isMemoryHog: false,
            isCpuHog: false
        )
    }

    @Test("Tabs sharing one WebKit process are counted once, not once each")
    func sharedProcessesAreCountedOnce() {
        let space = UUID()
        // Three tabs of one space, all served by process 900: this is the
        // ordinary case, not an edge one, and adding the three readings
        // together would report 900 MB where 300 are in use.
        let usages = [
            usage(title: "a", space: space, pid: 900, memoryMB: 300),
            usage(title: "b", space: space, pid: 900, memoryMB: 300, cpu: 4),
            usage(title: "c", space: space, pid: 900, memoryMB: 300, cpu: 4)
        ]

        let rollup = ActivityMath.rollup(of: usages)
        #expect(rollup.tabCount == 3)
        #expect(rollup.processCount == 1)
        #expect(rollup.memoryBytes == 300 * 1024 * 1024)
        #expect(rollup.cpuPercentage == 0)
    }

    @Test("A sleeping tab is counted as a tab and as no memory")
    func sleepingTabsCostNothing() {
        let space = UUID()
        let usages = [
            usage(title: "awake", space: space, pid: 900, memoryMB: 200),
            usage(title: "asleep", space: space, pid: nil, memoryMB: 1, suspended: true),
            usage(title: "noisy", space: space, pid: 901, memoryMB: 100, audible: true)
        ]

        let rollup = ActivityMath.rollup(of: usages)
        #expect(rollup.tabCount == 3)
        #expect(rollup.activeTabCount == 2)
        #expect(rollup.suspendedTabCount == 1)
        #expect(rollup.audibleTabCount == 1)
        #expect(rollup.memoryBytes == 300 * 1024 * 1024)
        #expect(rollup.processCount == 2)
    }

    @Test("A scope covers exactly its own tabs")
    func scopeFiltersTabs() {
        let work = UUID()
        let home = UUID()
        let mine = usage(title: "mine", space: work, pid: 900, memoryMB: 100)
        let usages = [
            mine,
            usage(title: "other", space: work, pid: 901, memoryMB: 50),
            usage(title: "elsewhere", space: home, pid: 902, memoryMB: 70)
        ]

        #expect(ActivityMath.tabs(in: .everything, from: usages).count == 3)
        #expect(ActivityMath.tabs(in: .space(work), from: usages).count == 2)
        #expect(ActivityMath.tabs(in: .space(home), from: usages).count == 1)
        let single = ActivityMath.tabs(in: .tab(mine.tabId), from: usages)
        #expect(single.count == 1)
        #expect(single.first?.title == "mine")
    }

    @Test("Bars are ranked heaviest first and scaled against the biggest")
    func barsAreRankedAndScaled() {
        let space = UUID()
        let usages = [
            usage(title: "small", space: space, pid: 900, memoryMB: 100),
            usage(title: "huge", space: space, pid: 901, memoryMB: 400),
            usage(title: "asleep", space: space, pid: nil, memoryMB: 1, suspended: true)
        ]

        let bars = ActivityMath.tabBars(from: usages)
        // Sleeping tabs are left out: a bar chart of what is costing you
        // something should not be a third full of things that cost nothing.
        #expect(bars.count == 2)
        #expect(bars.first?.label == "huge.example")
        #expect(bars.first?.fraction == 1)
        #expect(abs((bars.last?.fraction ?? 0) - 0.25) < 0.0001)
    }

    @Test("A bar chart with one scope highlighted dims the others rather than hiding them")
    func highlightingDimsTheRest() {
        let space = UUID()
        let mine = usage(title: "mine", space: space, pid: 900, memoryMB: 100)
        let bars = ActivityMath.tabBars(
            from: [mine, usage(title: "other", space: space, pid: 901, memoryMB: 400)],
            highlighting: mine.tabId
        )
        #expect(bars.count == 2)
        #expect(bars.first { $0.id == mine.tabId }?.isDimmed == false)
        #expect(bars.first { $0.id != mine.tabId }?.isDimmed == true)
    }

    @Test("The memory slices add up to the whole and leave out what is not running")
    func memorySlicesAddUp() {
        var snapshot = ResourceSnapshot()
        snapshot.browserMemoryBytes = 200 * 1024 * 1024
        snapshot.webContentMemoryBytes = 600 * 1024 * 1024
        snapshot.gpuProcessMemoryBytes = 0

        let slices = ActivityMath.memorySlices(of: snapshot)
        // No GPU process, so no slice for one: a legend key reading "0 MB" is
        // a key for something that is not there.
        #expect(slices.count == 2)
        #expect(abs(slices.map(\.fraction).reduce(0, +) - 1) < 0.0001)
        #expect(slices.first?.label == "Kylmora")
        #expect(abs((slices.first?.fraction ?? 0) - 0.25) < 0.0001)
    }

    @Test("Only the spaces that have tabs get a bar")
    func emptySpacesAreLeftOut() {
        let session = BrowserSession(database: nil)
        let busy = session.addSpace(named: "Busy")
        session.selectSpace(busy)
        let quiet = session.addSpace(named: "Quiet")

        // Only the busy space's tabs were sampled. A space with nothing in it
        // is left out of the chart rather than drawn as a bar of zero: an empty
        // row that can never be anything else is a row that teaches nothing.
        let usages = busy.tabs.map { _ in
            usage(title: "page", space: busy.id, pid: 900, memoryMB: 120)
        }
        let bars = ActivityMath.spaceBars(from: usages, spaces: session.spaces)

        #expect(bars.contains { $0.id == busy.id })
        #expect(!bars.contains { $0.id == quiet.id })
    }
}

/// The window itself: it is live and unscreenshotable, so what is checked here
/// is that each scope produces the rows and the chrome it should.
@Suite("Task Manager window")
@MainActor
struct TaskManagerWindowTests {
    private func session() -> (BrowserSession, Space, Tab) {
        let session = BrowserSession(database: nil)
        let space = session.addSpace(named: "Work")
        session.selectSpace(space)
        let tab = session.newTab(url: URL(string: "https://kylmora.org")!)
        _ = session.newTab(url: URL(string: "https://github.com")!)
        return (session, space, tab)
    }

    @Test("The window opens on the whole browser and lists every tab")
    func opensOnEverything() {
        let (session, _, _) = self.session()
        let controller = TaskManagerViewController(session: session)
        controller.loadView()

        #expect(controller.numberOfRows(in: NSTableView()) == session.allTabs.count)
    }

    @Test("A space scope lists only that space's tabs")
    func spaceScopeFilters() {
        let session = BrowserSession(database: nil)
        let work = session.addSpace(named: "Work")
        session.selectSpace(work)
        _ = session.newTab(url: URL(string: "https://one.example")!)
        let home = session.addSpace(named: "Home")
        session.selectSpace(home)
        _ = session.newTab(url: URL(string: "https://two.example")!)
        _ = session.newTab(url: URL(string: "https://three.example")!)

        let controller = TaskManagerViewController(session: session)
        controller.loadView()
        let everything = controller.numberOfRows(in: NSTableView())

        controller.show(scope: .space(home.id))
        let inHome = controller.numberOfRows(in: NSTableView())

        #expect(inHome < everything)
        #expect(inHome == home.tabs.count)
    }

    @Test("Drilling into a page keeps its siblings listed, so there is a way back")
    func tabScopeKeepsSiblings() {
        let (session, space, tab) = self.session()
        let controller = TaskManagerViewController(session: session)
        controller.loadView()

        controller.show(scope: .tab(tab.id))
        #expect(controller.numberOfRows(in: NSTableView()) == space.tabs.count)
    }

    @Test("A scope whose space has gone falls back to the whole browser")
    func vanishedScopeFallsBack() {
        let session = BrowserSession(database: nil)
        let doomed = session.addSpace(named: "Temporary")
        session.selectSpace(doomed)
        _ = session.newTab(url: URL(string: "https://one.example")!)

        let controller = TaskManagerViewController(session: session)
        controller.loadView()
        controller.show(scope: .space(doomed.id))
        #expect(controller.currentScope == .space(doomed.id))

        session.removeSpace(doomed)
        controller.refreshMetrics()
        #expect(controller.currentScope == .everything)
    }
}

/// Small things that make a window read as finished.
@Suite("Activity wording")
struct ActivityWordingTests {
    @Test("One of something is not written as a plural")
    func countsArePluralisedProperly() {
        #expect(UsageFormat.count(1, "tab") == "1 tab")
        #expect(UsageFormat.count(0, "tab") == "0 tabs")
        #expect(UsageFormat.count(3, "tab") == "3 tabs")
        #expect(
            UsageFormat.count(1, "WebKit process", plural: "WebKit processes") == "1 WebKit process"
        )
        #expect(
            UsageFormat.count(2, "WebKit process", plural: "WebKit processes") == "2 WebKit processes"
        )
    }
}

/// The Task Manager's pane in Settings.
@Suite("Task Manager settings pane")
@MainActor
struct TaskManagerSettingsPaneTests {
    private func settings() -> Settings {
        Settings(defaults: UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!)
    }

    @Test("The pane is in the rail, in the System group, with a symbol of its own")
    func paneIsRegistered() {
        let pane = SettingsWindowController.Pane.taskManager
        #expect(pane.title == "Task Manager")
        #expect(pane.group == .system)
        #expect(NSImage(systemSymbolName: pane.symbolName, accessibilityDescription: nil) != nil)
        // The words somebody actually types when the fan comes on.
        #expect(pane.matches("memory"))
        #expect(pane.matches("cpu"))
        #expect(pane.matches("gpu"))
        #expect(SettingsSpineView().row(for: pane) != nil)
    }

    @Test("The switch shows the setting, and writing it moves the switch")
    func switchReflectsAndWritesTheSetting() {
        let settings = settings()
        let controller = TaskManagerSettingsViewController(session: TestSession.make().0, settings: settings)
        controller.loadView()

        // On by default: the button is how most people will ever find this.
        #expect(settings.showsTaskManagerInSidebar)

        settings.showsTaskManagerInSidebar = false
        controller.viewWillAppear()
        #expect(!settings.showsTaskManagerInSidebar)
    }

    @Test("The pane carries the live Task Manager, not a picture of one")
    func paneEmbedsTheRealThing() {
        let session = BrowserSession(database: nil)
        let space = session.addSpace(named: "Work")
        session.selectSpace(space)
        _ = session.newTab(url: URL(string: "https://kylmora.org")!)

        let controller = TaskManagerSettingsViewController(session: session, settings: settings())
        controller.loadView()

        let activity = controller.children.compactMap { $0 as? TaskManagerViewController }.first
        #expect(activity != nil)
        #expect(activity?.currentScope == .everything)
        #expect((activity?.numberOfRows(in: NSTableView()) ?? 0) >= 1)
    }

    @Test("The embedded one has no rail of its own -- the Settings window already has one")
    func embeddedHasNoRail() {
        let controller = TaskManagerViewController(
            session: TestSession.make().0, presentation: .embedded
        )
        controller.loadView()
        #expect(!containsRail(controller.view))
        // It gets a scrolling row of chips instead, and no pop-up: the numbers
        // on the chips are half the answer, and a pop-up hides them.
        #expect(first(ActivityScopeBar.self, under: controller.view) != nil)
        #expect(first(NSPopUpButton.self, under: controller.view) == nil)

        let window = TaskManagerViewController(session: TestSession.make().0)
        window.loadView()
        #expect(containsRail(window.view))
    }

    @Test("Every space gets a chip, and choosing one is reported")
    func chipsCoverTheSpacesAndReportChoices() {
        let session = BrowserSession(database: nil)
        let work = session.addSpace(named: "Work")
        session.selectSpace(work)

        let bar = ActivityScopeBar()
        var chosen: ActivityScope?
        bar.onSelect = { chosen = $0 }
        bar.show(
            [
                .init(scope: .everything, title: "Whole Browser", symbol: "rectangle.3.group.fill", tint: .systemBlue),
                .init(scope: .space(work.id), title: "Work", detail: "120 MB", tint: .systemGreen)
            ],
            selected: .everything
        )
        bar.frame = NSRect(x: 0, y: 0, width: 400, height: ActivityScopeBar.height)
        bar.layoutSubtreeIfNeeded()

        let chips = every(SettingsPlateView.self, under: bar).filter { $0.accessibilityRole() == .button }
        #expect(chips.count == 2)
        #expect(chips.first?.accessibilityValue() as? String == "selected")
        #expect(chips.last?.accessibilityLabel() == "Work — 120 MB")

        _ = chips.last?.accessibilityPerformPress()
        #expect(chosen == .space(work.id))
    }

    @Test("More chips than fit leave something to scroll to")
    func aFullRowIsScrollable() {
        let bar = ActivityScopeBar()
        let items = (0..<12).map { index in
            ActivityScopeBar.Item(
                scope: .space(UUID()),
                title: "Space \(index)",
                detail: "120 MB",
                tint: .systemBlue
            )
        }
        bar.show(items, selected: items[0].scope)
        // Narrower than a dozen chips by a long way.
        bar.frame = NSRect(x: 0, y: 0, width: 420, height: ActivityScopeBar.height)
        bar.layoutSubtreeIfNeeded()

        // The row has to be wider than the bar, or the chips past the edge are
        // simply clipped and the scroller has nothing to do -- which is what a
        // stack view pinned to its clip view quietly does.
        #expect(bar.contentWidth > bar.bounds.width)
        let document = first(NSScrollView.self, under: bar)?.documentView
        #expect((document?.frame.width ?? 0) > bar.bounds.width)
    }

    private func first<T: NSView>(_ type: T.Type, under view: NSView) -> T? {
        every(type, under: view).first
    }

    private func every<T: NSView>(_ type: T.Type, under view: NSView) -> [T] {
        var found: [T] = []
        if let match = view as? T { found.append(match) }
        for child in view.subviews { found.append(contentsOf: every(type, under: child)) }
        return found
    }

    private func containsRail(_ view: NSView) -> Bool {
        if view is ActivityRailView { return true }
        return view.subviews.contains { containsRail($0) }
    }
}

/// The scope bar as it is actually built: inside the pane, inside a window.
///
/// The row not scrolling survived a unit test of the bar on its own, because
/// the bug only appears once something else decides the bar's width -- which is
/// every case that matters.
@Suite("Scope bar inside the pane")
@MainActor
struct ScopeBarInPaneTests {
    @Test("A dozen spaces overflow the pane, and the overflow is reachable")
    func theRowScrollsInsideThePane() {
        let session = BrowserSession(database: nil)
        for index in 0..<12 {
            let space = session.addSpace(named: "Space number \(index)")
            session.selectSpace(space)
        }

        let controller = TaskManagerSettingsViewController(
            session: session,
            settings: Settings(defaults: UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!)
        )
        controller.loadView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 900),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView?.addSubview(controller.view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 660, height: 900)
        controller.view.layoutSubtreeIfNeeded()

        guard let bar = ScopeBarInPaneTests.find(ActivityScopeBar.self, under: controller.view) else {
            Issue.record("no scope bar on the pane")
            return
        }
        bar.layoutSubtreeIfNeeded()

        let document = ScopeBarInPaneTests.find(NSScrollView.self, under: bar)?.documentView
        #expect(bar.contentWidth > bar.bounds.width, "13 chips fit in \(bar.bounds.width)pt?")
        #expect(
            (document?.frame.width ?? 0) > bar.bounds.width + 1,
            "document \(document?.frame.width ?? 0) vs bar \(bar.bounds.width)"
        )
    }

    @Test("Refreshing the numbers does not drag the row back to the chosen chip")
    func refreshingKeepsTheScrollPosition() {
        let bar = ActivityScopeBar()
        let items = (0..<14).map { index in
            ActivityScopeBar.Item(
                scope: .space(UUID()),
                title: "Space number \(index)",
                detail: "120 MB",
                tint: .systemBlue
            )
        }
        bar.show(items, selected: items[0].scope)
        bar.frame = NSRect(x: 0, y: 0, width: 420, height: ActivityScopeBar.height)
        bar.layoutSubtreeIfNeeded()

        guard let scroll = ScopeBarInPaneTests.find(NSScrollView.self, under: bar) else {
            Issue.record("no scroller in the bar")
            return
        }
        scroll.contentView.scroll(to: NSPoint(x: 200, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(scroll.contentView.bounds.origin.x == 200)

        // The numbers change every two seconds; where the reader scrolled to
        // does not. This is what made the row look like it could not scroll:
        // every scroll was undone before the hand left the trackpad.
        var refreshed = items
        refreshed[3].detail = "999 MB"
        bar.show(refreshed, selected: items[0].scope)
        #expect(scroll.contentView.bounds.origin.x == 200)

        // Choosing a different chip is another matter: that one is brought
        // into view.
        bar.show(refreshed, selected: items[13].scope)
        #expect(scroll.contentView.bounds.origin.x > 200)
    }

    @Test("The arrows appear only where there is something to reach")
    func arrowsFollowThePosition() {
        let bar = ActivityScopeBar()
        let items = (0..<14).map { index in
            ActivityScopeBar.Item(
                scope: .space(UUID()),
                title: "Space number \(index)",
                detail: "120 MB",
                tint: .systemBlue
            )
        }
        bar.show(items, selected: items[0].scope)
        bar.frame = NSRect(x: 0, y: 0, width: 420, height: ActivityScopeBar.height)
        bar.layoutSubtreeIfNeeded()

        func arrow(_ label: String) -> NSView? {
            ScopeBarInPaneTests.everyView(under: bar)
                .first { ($0 as? IconButton)?.accessibilityLabel() == label }?
                .superview
        }
        // At the start there is nothing behind you and plenty ahead.
        #expect(arrow("Earlier spaces")?.isHidden == true)
        #expect(arrow("Later spaces")?.isHidden == false)

        guard let scroll = ScopeBarInPaneTests.find(NSScrollView.self, under: bar) else {
            Issue.record("no scroller in the bar")
            return
        }
        let room = (scroll.documentView?.frame.width ?? 0) - scroll.contentView.bounds.width
        scroll.contentView.scroll(to: NSPoint(x: room, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        bar.layoutSubtreeIfNeeded()

        // ...and at the far end, the other way round.
        #expect(arrow("Earlier spaces")?.isHidden == false)
        #expect(arrow("Later spaces")?.isHidden == true)
    }

    @Test("One chip looks chosen and the rest look alike")
    func onlyTheChosenChipStandsOut() {
        let bar = ActivityScopeBar()
        let items = (0..<6).map { index in
            ActivityScopeBar.Item(
                scope: .space(UUID()),
                title: "Space \(index)",
                detail: "12 MB",
                tint: .systemPink
            )
        }
        bar.show(items, selected: items[2].scope)
        bar.frame = NSRect(x: 0, y: 0, width: 900, height: ActivityScopeBar.height)
        bar.layoutSubtreeIfNeeded()

        let plates = ScopeBarInPaneTests.everyView(under: bar)
            .compactMap { $0 as? SettingsPlateView }
            .filter { $0.accessibilityRole() == .button }
        #expect(plates.count == items.count)

        // The chips that are not chosen are all painted the same. They were
        // not: a chip that had been under the pointer kept its hover -- the
        // row slides out from under a still pointer every time it scrolls --
        // so a row ended up with two or three chips lit and no way to tell
        // which one was actually selected.
        //
        // Compared as colours rather than as objects: the semantic colours are
        // computed properties, so two chips painted the same way still hold
        // two different `NSColor` instances.
        func swatches() -> [String] {
            var resolved: [String] = []
            NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
                resolved = plates.map { plate in
                    guard let rgb = plate.fill?.usingColorSpace(.sRGB) else { return "none" }
                    return String(
                        format: "%.3f %.3f %.3f %.3f",
                        rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent
                    )
                }
            }
            return resolved
        }

        let fills = swatches()
        #expect(fills.count == items.count)
        let unselected = Set(fills.enumerated().compactMap { $0.offset == 2 ? nil : $0.element })
        #expect(unselected.count == 1, "unselected chips are painted \(unselected.count) different ways")
        #expect(fills[2] != unselected.first)

        // Re-showing with new numbers, which happens every two seconds, must
        // not change any of that.
        var refreshed = items
        refreshed[4].detail = "999 MB"
        bar.show(refreshed, selected: items[2].scope)
        let after = swatches()
        #expect(Set(after.enumerated().compactMap { $0.offset == 2 ? nil : $0.element }).count == 1)
        #expect(after[2] == fills[2])
    }

    static func everyView(under view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { everyView(under: $0) }
    }

    static func find<T: NSView>(_ type: T.Type, under view: NSView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews {
            if let found = find(type, under: child) { return found }
        }
        return nil
    }
}
