import AppKit
import Foundation
import Testing
@testable import Kylmora

/// The Task Manager's graphs: the window is live and unscreenshotable, so the
/// two things that would be wrong without anyone noticing -- where the top of
/// the graph lands, and where the line goes -- are checked here instead.
@Suite("Usage graphs")
@MainActor
struct ResourceGraphTests {
    @Test("A history keeps the last two minutes and nothing older")
    func historyIsCapped() {
        var history = UsageHistory()
        for value in 0..<200 { history.record(Double(value)) }

        #expect(history.samples.count == UsageHistory.capacity)
        #expect(history.latest == 199)
        // The early readings are gone, so an hour-long window does not grow
        // without bound behind a card that only ever shows sixty points.
        #expect(history.peak == 199)
        #expect(history.samples.first == Double(200 - UsageHistory.capacity))
    }

    @Test("A negative reading is clamped rather than plotted below the floor")
    func negativeReadingsAreClamped() {
        var history = UsageHistory()
        history.record(-4)
        #expect(history.latest == 0)
    }

    @Test("The ceiling is a round number, and never below the card's floor")
    func ceilingIsReadable() {
        // An idle browser does not scale its own noise to full height.
        #expect(UsageGraph.ceiling(forPeak: 3, floor: 100) == 100)
        #expect(UsageGraph.ceiling(forPeak: 0, floor: 100) == 100)
        // Past the floor it climbs in steps a person can read off the card.
        #expect(UsageGraph.ceiling(forPeak: 150, floor: 100) == 200)
        #expect(UsageGraph.ceiling(forPeak: 260, floor: 100) == 500)
        #expect(UsageGraph.ceiling(forPeak: 1_400, floor: 512) == 2_000)
    }

    @Test("The line fills from the right, so a fresh graph is not stretched")
    func pointsFillFromTheRight() {
        let rect = CGRect(x: 0, y: 0, width: 120, height: 40)
        var history = UsageHistory()
        history.record(50)
        history.record(100)

        let points = UsageGraph.points(for: history.samples, in: rect, ceiling: 100)
        #expect(points.count == 2)
        // The newest sample is at the trailing edge; the older one is one
        // sample's width behind it, not half the card away.
        #expect(abs(points[1].x - rect.maxX) < 0.001)
        #expect(points[0].x < points[1].x)
        #expect(points[0].x > rect.width * 0.9)
        // ...and the values are heights: half the ceiling is half the card.
        #expect(abs(points[0].y - rect.height / 2) < 0.001)
        #expect(abs(points[1].y - rect.height) < 0.001)
    }

    @Test("A reading over the ceiling is clipped to the top rather than drawn off the card")
    func pointsAreClipped() {
        let rect = CGRect(x: 0, y: 0, width: 60, height: 20)
        let points = UsageGraph.points(for: [400], in: rect, ceiling: 100)
        #expect(points.first?.y == rect.maxY)
    }

    @Test("An empty history draws nothing at all")
    func emptyHistoryHasNoLine() {
        #expect(UsageGraph.points(for: [], in: CGRect(x: 0, y: 0, width: 10, height: 10), ceiling: 100).isEmpty)
        #expect(UsageHistory().isEmpty)
    }

    @Test("A total and a row agree about what a gigabyte is called")
    func memoryFormatting() {
        #expect(UsageFormat.memory(50 * 1024 * 1024) == "50 MB")
        #expect(UsageFormat.memory(UInt64(2.5 * 1024 * 1024 * 1024)) == "2.50 GB")
        #expect(UsageFormat.percentage(12.34) == "12.3%")
    }
}

/// The whole-browser sweep behind the three cards.
@Suite("Browser-wide resource snapshot")
@MainActor
struct ResourceSnapshotTests {
    @Test("A snapshot counts the browser, the pages and the suspended tabs")
    func snapshotCountsEverything() {
        let session = BrowserSession(database: nil)
        let space = session.addSpace(named: "Work")
        session.selectSpace(space)
        _ = session.newTab(url: URL(string: "https://kylmora.org")!)
        let sleeping = session.newTab(url: URL(string: "https://github.com")!)
        sleeping.unload()

        let monitor = TabResourceMonitor()
        let snapshot = monitor.snapshot(in: session)

        #expect(snapshot.tabs.count >= 2)
        #expect(snapshot.suspendedTabCount >= 1)
        #expect(snapshot.activeTabCount == snapshot.tabs.count - snapshot.suspendedTabCount)
        // Kylmora's own footprint is always part of the total: a browser with
        // every tab asleep still costs something, and a card that said zero
        // would be lying.
        #expect(snapshot.browserMemoryBytes > 0)
        #expect(snapshot.totalMemoryBytes >= snapshot.browserMemoryBytes)
        #expect(snapshot.totalCpuPercentage >= 0)
    }

    @Test("Sampling records history for the browser and for each tab")
    func historyIsRecordedPerTab() {
        let session = BrowserSession(database: nil)
        let space = session.addSpace(named: "Reading")
        session.selectSpace(space)
        let tab = session.newTab(url: URL(string: "https://example.com")!)

        let monitor = TabResourceMonitor()
        _ = monitor.snapshot(in: session)
        _ = monitor.snapshot(in: session)

        #expect(monitor.totalMemoryHistory.samples.count == 2)
        #expect(monitor.totalCpuHistory.samples.count == 2)
        #expect(monitor.cpuHistory(forTab: tab.id).samples.count == 2)
        #expect(monitor.memoryHistory(forTab: tab.id).latest > 0)
    }

    @Test("A closed tab's history is dropped rather than kept for ever")
    func historyForgetsClosedTabs() {
        let session = BrowserSession(database: nil)
        let space = session.addSpace(named: "Scratch")
        session.selectSpace(space)
        let keeper = session.newTab(url: URL(string: "https://one.example")!)
        let doomed = session.newTab(url: URL(string: "https://two.example")!)

        let monitor = TabResourceMonitor()
        _ = monitor.snapshot(in: session)
        #expect(!monitor.cpuHistory(forTab: doomed.id).isEmpty)

        _ = session.closeTab(doomed)
        _ = monitor.snapshot(in: session)

        #expect(monitor.cpuHistory(forTab: doomed.id).isEmpty)
        #expect(!monitor.cpuHistory(forTab: keeper.id).isEmpty)
    }

    @Test("The GPU readings are percentages or nothing, never nonsense")
    func gpuReadingsArePercentages() {
        // Whether a driver publishes either of these at all depends on the
        // machine, so the test is about the range rather than about there
        // being a number.
        if let utilisation = GPUMetrics.deviceUtilisation() {
            #expect(utilisation >= 0)
            #expect(utilisation <= 100)
        }

        let session = BrowserSession(database: nil)
        let space = session.addSpace(named: "Work")
        session.selectSpace(space)
        _ = session.newTab(url: URL(string: "https://kylmora.org")!)

        let monitor = TabResourceMonitor()
        _ = monitor.snapshot(in: session)
        let snapshot = monitor.snapshot(in: session)

        // Kylmora's own share is a separate reading from the machine's, and it
        // is the one the card and the graph are about: a card that rose because
        // something else started rendering would blame the browser for it.
        if let own = snapshot.ownGpuPercentage {
            #expect(own >= 0)
        }
        #expect(snapshot.ownGpuPercentage != nil || snapshot.machineGpuUtilisation != nil
            || GPUMetrics.accumulatedGPUTime(ofPids: [getpid()]) == nil)
    }

    @Test("A GPU client names the process that opened it")
    func clientNamesAreParsed() {
        #expect(GPUMetrics.pid(fromCreator: "pid 1234, Kylmora") == 1234)
        #expect(GPUMetrics.pid(fromCreator: "pid 7, com.apple.WebKit") == 7)
        // Anything that is not a pid line is not a pid, rather than a zero that
        // would quietly match a process nobody meant.
        #expect(GPUMetrics.pid(fromCreator: "WindowServer") == nil)
        #expect(GPUMetrics.pid(fromCreator: "pid , none") == nil)
    }

    @Test("GPU time is read for this process, or not published at all")
    func ownGpuTimeIsReadable() {
        // On Apple silicon this process is a Metal client the moment AppKit
        // draws, so there is a reading; on hardware whose driver publishes no
        // per-client usage there is none. Both are fine -- a number that is
        // neither nil nor sane is not.
        if let nanoseconds = GPUMetrics.accumulatedGPUTime(ofPids: [getpid()]) {
            #expect(nanoseconds >= 0)
        }
        // A pid nothing owns has no GPU time to report.
        #expect(GPUMetrics.accumulatedGPUTime(ofPids: []) == nil)
    }
}

/// The way in from the sidebar.
@Suite("Task Manager button")
@MainActor
struct ActivityButtonTests {
    @Test("The sidebar footer carries Downloads, Task Manager and Archive")
    func footerHasActivityButton() {
        let session = TestSession.make().0
        let sidebar = SidebarViewController(session: session)
        sidebar.view.frame = NSRect(x: 0, y: 0, width: Style.Metrics.sidebarWidth, height: 800)
        sidebar.view.layoutSubtreeIfNeeded()

        let labels = labelsOfButtons(under: sidebar.view)
        #expect(labels.contains("Downloads"))
        #expect(labels.contains("Task Manager"))
        #expect(labels.contains("Archive"))
    }

    @Test("Switching it off takes the button out of the footer, and back on puts it back")
    func theButtonFollowsTheSetting() {
        let original = Settings.shared.showsTaskManagerInSidebar
        defer { Settings.shared.showsTaskManagerInSidebar = original }

        let session = TestSession.make().0
        let sidebar = SidebarViewController(session: session)
        sidebar.view.frame = NSRect(x: 0, y: 0, width: Style.Metrics.sidebarWidth, height: 800)
        sidebar.view.layoutSubtreeIfNeeded()

        Settings.shared.showsTaskManagerInSidebar = false
        // The setting is announced rather than polled, and the observer is on
        // the main queue: the notification has to be delivered before the
        // footer can have heard it.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(!labelsOfButtons(under: sidebar.view).contains("Task Manager"))
        // Downloads and Archive are not what this switch is about.
        #expect(labelsOfButtons(under: sidebar.view).contains("Downloads"))
        #expect(labelsOfButtons(under: sidebar.view).contains("Archive"))

        Settings.shared.showsTaskManagerInSidebar = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(labelsOfButtons(under: sidebar.view).contains("Task Manager"))
    }

    @Test("A sidebar built while the setting is off never carries the button")
    func aFreshSidebarHonoursTheSetting() {
        let original = Settings.shared.showsTaskManagerInSidebar
        defer { Settings.shared.showsTaskManagerInSidebar = original }
        Settings.shared.showsTaskManagerInSidebar = false

        let sidebar = SidebarViewController(session: TestSession.make().0)
        sidebar.view.frame = NSRect(x: 0, y: 0, width: Style.Metrics.sidebarWidth, height: 800)
        sidebar.view.layoutSubtreeIfNeeded()

        #expect(!labelsOfButtons(under: sidebar.view).contains("Task Manager"))
    }

    private func labelsOfButtons(under view: NSView) -> Set<String> {
        var found: Set<String> = []
        if view is IconButton, let label = view.accessibilityLabel() {
            found.insert(label)
        }
        for subview in view.subviews {
            found.formUnion(labelsOfButtons(under: subview))
        }
        return found
    }
}
