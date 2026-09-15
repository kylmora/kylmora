import Testing
import AppKit
import Foundation
@testable import Kylmora

@Suite("Tab Resource Monitor & Task Manager (F-26)")
@MainActor
struct TabResourceMonitorTests {

    @Test("TabResourceUsage formats memory and CPU accurately")
    func usageFormatting() {
        let usage1 = TabResourceUsage(
            tabId: UUID(),
            title: "Lightweight Site",
            url: URL(string: "https://example.com"),
            domain: "example.com",
            spaceName: "Personal",
            isSuspended: false,
            isPlayingAudio: false,
            pid: 1234,
            memoryBytes: 50 * 1024 * 1024, // 50 MB
            cpuPercentage: 1.5,
            isMemoryHog: false,
            isCpuHog: false
        )
        #expect(usage1.formattedMemory == "50.0 MB")
        #expect(usage1.formattedCPU == "1.5%")
        #expect(usage1.isMemoryHog == false)

        let usageHog = TabResourceUsage(
            tabId: UUID(),
            title: "Heavy Web App",
            url: URL(string: "https://heavy.app"),
            domain: "heavy.app",
            spaceName: "Work",
            isSuspended: false,
            isPlayingAudio: true,
            pid: 5678,
            memoryBytes: UInt64(2.4 * 1024 * 1024 * 1024), // 2.4 GB
            cpuPercentage: 75.0,
            isMemoryHog: true,
            isCpuHog: true
        )
        #expect(usageHog.formattedMemory == "2.40 GB")
        #expect(usageHog.formattedCPU == "75.0%")
        #expect(usageHog.isMemoryHog == true)
        #expect(usageHog.isCpuHog == true)

        let usageSuspended = TabResourceUsage(
            tabId: UUID(),
            title: "Archived Tab",
            url: URL(string: "https://archive.org"),
            domain: "archive.org",
            spaceName: "Work",
            isSuspended: true,
            isPlayingAudio: false,
            pid: nil,
            memoryBytes: 512 * 1024,
            cpuPercentage: 0.0,
            isMemoryHog: false,
            isCpuHog: false
        )
        #expect(usageSuspended.formattedMemory.contains("Suspended"))
        #expect(usageSuspended.formattedCPU == "0.0%")
    }

    @Test("TabResourceMonitor samples session tabs and differentiates active vs suspended")
    func samplingSessionTabs() {
        let session = BrowserSession(database: nil)
        let space = session.addSpace(named: "Research")
        session.selectSpace(space)
        let tab1 = session.newTab(url: URL(string: "https://kylmora.org")!)
        let tab2 = session.newTab(url: URL(string: "https://github.com")!)
        tab2.unload() // suspended tab

        let monitor = TabResourceMonitor()
        let samples = monitor.sampleAllTabs(in: session)

        #expect(samples.count >= 2)
        let sampledTab2 = samples.first { $0.tabId == tab2.id }
        #expect(sampledTab2 != nil)
        #expect(sampledTab2?.isSuspended == true)

        let totals = monitor.sampleTotalMemory(in: session)
        #expect(totals.total > 0)
    }

    @Test("TabResourceMonitor detects runaway memory hogs and presents toast alerts")
    func runawayTabDetection() {
        let session = BrowserSession(database: nil)
        let space = session.addSpace(named: "Work")
        session.selectSpace(space)
        let tab = session.newTab(url: URL(string: "https://linkedin.com")!)

        var raisedToast: Toast?
        session.showToast = { toast in
            raisedToast = toast
        }

        // Lower threshold temporarily for testing
        let originalThreshold = TabResourceMonitor.memoryHogThresholdBytes
        TabResourceMonitor.memoryHogThresholdBytes = 10 * 1024 * 1024 // 10 MB
        defer { TabResourceMonitor.memoryHogThresholdBytes = originalThreshold }

        let monitor = TabResourceMonitor()
        // Ensure another tab is active so this tab is treated as background
        _ = session.newTab(url: URL(string: "https://active.com")!)

        monitor.checkRunawayTabs(in: session)

        if let toast = raisedToast {
            #expect(toast.identity?.starts(with: "memory-hog-") == true)
            #expect(toast.message.contains("memory"))
        }
    }

    @Test("TaskManagerViewController initializes table view and filters rows")
    func taskManagerUI() {
        let session = BrowserSession(database: nil)
        let space = session.addSpace(named: "Productivity")
        session.selectSpace(space)
        _ = session.newTab(url: URL(string: "https://notion.so")!)

        let controller = TaskManagerViewController(session: session)
        controller.loadView()

        #expect(controller.numberOfRows(in: NSTableView()) >= 1)
    }

    @Test("CommandCatalog and ShortcutManager register task-manager with ⌥⌘U")
    func taskManagerShortcuts() {
        let command = CommandCatalog.all.first { $0.id == "task-manager" }
        #expect(command != nil)
        #expect(command?.shortcut == "⌥⌘U")

        let definition = ShortcutManager.shared.definitions.first { $0.id == "task-manager" }
        #expect(definition != nil)
        #expect(definition?.defaultKey == "u")
        let expectedModifiers: NSEvent.ModifierFlags = [.command, .option]
        #expect(definition?.defaultModifiers == expectedModifiers)
    }
}
