import Foundation
import AppKit
import Darwin

/// Monitors per-tab CPU and memory consumption using Darwin process APIs (`proc_pidinfo`),
/// and automatically flags memory-hogging and runaway sites.
@MainActor
final class TabResourceMonitor: NSObject {
    static let shared = TabResourceMonitor()

    /// Memory threshold above which a tab is flagged as a memory hog (default: 800 MB).
    static var memoryHogThresholdBytes: UInt64 = 800 * 1024 * 1024
    /// CPU threshold above which a tab is flagged as a CPU hog (default: 50.0%).
    static var cpuHogThresholdPercentage: Double = 50.0

    private struct CPUSample {
        var timestamp: TimeInterval
        var totalCpuNanoseconds: UInt64
    }

    private var previousSamples: [pid_t: CPUSample] = [:]
    private var alertedHogTabs: Set<UUID> = []
    private var backgroundSweepTimer: Timer?

    override init() {
        super.init()
    }

    /// Starts periodic background checking for runaway tabs.
    func startBackgroundMonitoring(session: BrowserSession) {
        backgroundSweepTimer?.invalidate()
        backgroundSweepTimer = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: true) { [weak self, weak session] _ in
            MainActor.assumeIsolated {
                guard let self, let session else { return }
                self.checkRunawayTabs(in: session)
            }
        }
    }

    /// Samples all tabs currently managed by the session.
    func sampleAllTabs(in session: BrowserSession) -> [TabResourceUsage] {
        let now = ProcessInfo.processInfo.systemUptime
        var results: [TabResourceUsage] = []

        // Precompute space mappings
        var tabSpaceMap: [UUID: String] = [:]
        for space in session.spaces {
            for tab in space.tabs {
                tabSpaceMap[tab.id] = space.name
            }
        }

        for tab in session.allTabs {
            let spaceName = tabSpaceMap[tab.id] ?? "Space"
            let isSuspended = !tab.isLoaded
            let isPlayingAudio = tab.isPlayingAudio
            let domain = tab.url.host ?? ""
            let title = tab.displayTitle

            if isSuspended {
                results.append(TabResourceUsage(
                    tabId: tab.id,
                    title: title,
                    url: tab.url,
                    domain: domain,
                    spaceName: spaceName,
                    isSuspended: true,
                    isPlayingAudio: isPlayingAudio,
                    pid: nil,
                    memoryBytes: 512 * 1024, // ~0.5 MB resident metadata
                    cpuPercentage: 0.0,
                    isMemoryHog: false,
                    isCpuHog: false
                ))
                continue
            }

            var pid: pid_t? = nil
            var memoryBytes: UInt64 = 64 * 1024 * 1024 // Baseline 64 MB
            var cpuPercentage: Double = 0.0

            if let webView = tab.currentWebView {
                if let processId = (webView as AnyObject).value(forKey: "_webProcessIdentifier") as? pid_t, processId > 0 {
                    pid = processId
                    var taskInfo = proc_taskinfo()
                    let size = Int32(MemoryLayout<proc_taskinfo>.size)
                    let status = proc_pidinfo(processId, PROC_PIDTASKINFO, 0, &taskInfo, size)

                    if status == size {
                        memoryBytes = taskInfo.pti_resident_size
                        let currentCpuNano = taskInfo.pti_total_user + taskInfo.pti_total_system

                        if let prev = previousSamples[processId] {
                            let deltaSeconds = now - prev.timestamp
                            if deltaSeconds > 0.1 && currentCpuNano >= prev.totalCpuNanoseconds {
                                let deltaNano = currentCpuNano - prev.totalCpuNanoseconds
                                let deltaCpuSeconds = Double(deltaNano) / 1_000_000_000.0
                                cpuPercentage = (deltaCpuSeconds / deltaSeconds) * 100.0
                            }
                        }

                        previousSamples[processId] = CPUSample(timestamp: now, totalCpuNanoseconds: currentCpuNano)
                    }
                }
            }

            let isMemoryHog = memoryBytes >= Self.memoryHogThresholdBytes
            let isCpuHog = cpuPercentage >= Self.cpuHogThresholdPercentage

            results.append(TabResourceUsage(
                tabId: tab.id,
                title: title,
                url: tab.url,
                domain: domain,
                spaceName: spaceName,
                isSuspended: false,
                isPlayingAudio: isPlayingAudio,
                pid: pid,
                memoryBytes: memoryBytes,
                cpuPercentage: cpuPercentage,
                isMemoryHog: isMemoryHog,
                isCpuHog: isCpuHog
            ))
        }

        return results
    }

    /// Returns the browser process memory and total WebKit content process memory.
    func sampleTotalMemory(in session: BrowserSession) -> (browser: UInt64, webContent: UInt64, total: UInt64) {
        let browser = Metrics.physicalFootprint() ?? 0
        let usages = sampleAllTabs(in: session)

        // Deduplicate WebKit processes by PID so shared processes aren't counted twice
        var seenPIDs: Set<pid_t> = []
        var webContent: UInt64 = 0

        for usage in usages where !usage.isSuspended {
            if let pid = usage.pid {
                if !seenPIDs.contains(pid) {
                    seenPIDs.insert(pid)
                    webContent += usage.memoryBytes
                }
            } else {
                webContent += usage.memoryBytes
            }
        }

        return (browser, webContent, browser + webContent)
    }

    /// Checks for runaway background tabs and raises a warning toast if a site is consuming excessive memory.
    func checkRunawayTabs(in session: BrowserSession) {
        let usages = sampleAllTabs(in: session)
        let activeTabId = session.activeTab?.id

        for usage in usages where usage.isMemoryHog && usage.tabId != activeTabId {
            guard !alertedHogTabs.contains(usage.tabId) else { continue }
            alertedHogTabs.insert(usage.tabId)

            let mb = Double(usage.memoryBytes) / (1024 * 1024)
            let formatted = mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
            let site = usage.domain.isEmpty ? usage.title : usage.domain

            session.showToast?(Toast(
                symbolName: "exclamationmark.triangle.fill",
                message: "“\(site)” is using \(formatted) of memory",
                identity: "memory-hog-\(usage.tabId.uuidString)"
            ))
        }
    }
}
