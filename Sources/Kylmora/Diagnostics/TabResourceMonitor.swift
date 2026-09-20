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

    /// CPU and memory for the processes that are not pages: Kylmora itself and
    /// WebKit's GPU helper. Separate from `previousSamples` because those are
    /// keyed by a tab's content process and swept when tabs close.
    var helperSampler = ProcessSampler()

    /// What the graphs draw. Held by the monitor rather than by the window, so
    /// the line survives closing the Task Manager and opening it again.
    var totalCpuHistory = UsageHistory()
    var totalMemoryHistory = UsageHistory()
    var gpuHistory = UsageHistory()
    /// The last reading of Kylmora's cumulative GPU time, which is what a
    /// percentage is worked out against.
    private var lastGpuSample: (timestamp: TimeInterval, nanoseconds: UInt64)?
    var tabCpuHistory: [UUID: UsageHistory] = [:]
    var tabMemoryHistory: [UUID: UsageHistory] = [:]
    var spaceCpuHistory: [UUID: UsageHistory] = [:]
    var spaceMemoryHistory: [UUID: UsageHistory] = [:]
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
        var tabSpaceMap: [UUID: (name: String, id: UUID)] = [:]
        for space in session.spaces {
            for tab in space.tabs {
                tabSpaceMap[tab.id] = (space.name, space.id)
            }
        }

        for tab in session.allTabs {
            let home = tabSpaceMap[tab.id]
            let spaceName = home?.name ?? "Space"
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
                    spaceID: home?.id,
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
                spaceID: home?.id,
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

// MARK: - Whole-browser sampling and history

/// One pass over everything the browser is costing, at one moment.
///
/// Gathered in a single sweep rather than asked for column by column, because
/// CPU is a difference between two readings: sampling the same process twice in
/// one refresh makes the second reading a fraction of a second after the first
/// and reports a busy page as idle.
struct ResourceSnapshot {
    var tabs: [TabResourceUsage] = []
    /// Kylmora's own process -- the UI, the sidebar, everything that is not a
    /// page.
    var browserMemoryBytes: UInt64 = 0
    var browserCpuPercentage: Double = 0
    /// Every WebKit content process, counted once each however many tabs share
    /// it.
    var webContentMemoryBytes: UInt64 = 0
    var webContentCpuPercentage: Double = 0
    /// WebKit's one GPU helper, which every page's compositing goes through.
    var gpuProcessMemoryBytes: UInt64 = 0
    var gpuProcessCpuPercentage: Double = 0
    /// Kylmora's own share of the GPU, as a percentage of wall-clock time:
    /// the app, WebKit's GPU process and any page process that has drawn. Nil
    /// on a Mac whose driver publishes no per-process GPU time.
    var ownGpuPercentage: Double?
    /// How busy the machine's GPU is, 0-100, everything on it included. Context
    /// for the figure above -- a GPU at 90 per cent while Kylmora is at 3 is
    /// something else's doing.
    var machineGpuUtilisation: Double?

    var totalMemoryBytes: UInt64 { browserMemoryBytes + webContentMemoryBytes + gpuProcessMemoryBytes }
    var totalCpuPercentage: Double { browserCpuPercentage + webContentCpuPercentage + gpuProcessCpuPercentage }

    var activeTabCount: Int { tabs.count { !$0.isSuspended } }
    var suspendedTabCount: Int { tabs.count(where: \.isSuspended) }
}

extension TabResourceMonitor {
    /// Everything the Task Manager draws, and the history behind it.
    ///
    /// Recording happens here rather than in the view, so the graphs keep
    /// filling for as long as something is sampling -- and so two windows
    /// looking at the same browser see the same line rather than each building
    /// a history of its own.
    func snapshot(in session: BrowserSession) -> ResourceSnapshot {
        let now = ProcessInfo.processInfo.systemUptime
        var snapshot = ResourceSnapshot()
        snapshot.tabs = sampleAllTabs(in: session)

        // Counted once per process. Several tabs in one space share a WebKit
        // content process, and adding their identical readings together would
        // report three times the memory that is actually in use.
        var seen: Set<pid_t> = []
        for usage in snapshot.tabs where !usage.isSuspended {
            guard let pid = usage.pid else {
                snapshot.webContentMemoryBytes += usage.memoryBytes
                snapshot.webContentCpuPercentage += usage.cpuPercentage
                continue
            }
            guard seen.insert(pid).inserted else { continue }
            snapshot.webContentMemoryBytes += usage.memoryBytes
            snapshot.webContentCpuPercentage += usage.cpuPercentage
        }

        if let own = helperSampler.sample(pid: getpid(), now: now) {
            snapshot.browserMemoryBytes = Metrics.physicalFootprint() ?? own.memoryBytes
            snapshot.browserCpuPercentage = own.cpuPercentage
        } else {
            snapshot.browserMemoryBytes = Metrics.physicalFootprint() ?? 0
        }

        var helpers: Set<pid_t> = [getpid()]
        if let gpuPid = GPUMetrics.processIdentifier(in: session) {
            helpers.insert(gpuPid)
            if let reading = helperSampler.sample(pid: gpuPid, now: now) {
                snapshot.gpuProcessMemoryBytes = reading.memoryBytes
                snapshot.gpuProcessCpuPercentage = reading.cpuPercentage
            }
        }
        helperSampler.forgetEveryPidExcept(helpers)

        // Kylmora's own GPU time: this process, WebKit's GPU process, and every
        // page process. In practice the GPU process is the one that has any --
        // WebKit does all page drawing there -- which is exactly why this
        // figure cannot be split per space.
        var family = helpers
        for usage in snapshot.tabs {
            if let pid = usage.pid { family.insert(pid) }
        }
        snapshot.ownGpuPercentage = ownGpuPercentage(of: family, at: now)
        snapshot.machineGpuUtilisation = GPUMetrics.deviceUtilisation()

        record(snapshot)
        return snapshot
    }

    /// Kylmora's GPU time since the last sweep, as a share of the time that
    /// passed. Zero on the first reading, because a rate needs two points.
    private func ownGpuPercentage(of pids: Set<pid_t>, at now: TimeInterval) -> Double? {
        guard let total = GPUMetrics.accumulatedGPUTime(ofPids: pids) else { return nil }
        defer { lastGpuSample = (now, total) }
        guard let last = lastGpuSample else { return 0 }
        let elapsed = now - last.timestamp
        // A client that has gone takes its accumulated time with it, so the
        // total can fall. That is not negative GPU use; it is a reset.
        guard elapsed > 0.1, total >= last.nanoseconds else { return 0 }
        return Double(total - last.nanoseconds) / (elapsed * 1_000_000_000) * 100
    }

    private func record(_ snapshot: ResourceSnapshot) {
        totalCpuHistory.record(snapshot.totalCpuPercentage)
        totalMemoryHistory.record(UsageFormat.megabytes(snapshot.totalMemoryBytes))
        // The graph draws Kylmora's own share, not the machine's: a line that
        // rose because something else started rendering would say the browser
        // was doing it.
        if let gpu = snapshot.ownGpuPercentage {
            gpuHistory.record(gpu)
        }

        for usage in snapshot.tabs {
            tabCpuHistory[usage.tabId, default: UsageHistory()].record(usage.cpuPercentage)
            tabMemoryHistory[usage.tabId, default: UsageHistory()]
                .record(UsageFormat.megabytes(usage.memoryBytes))
        }
        // A closed tab's history is not worth keeping: reopening it starts a
        // new process, so the old line would describe something that no longer
        // exists. Dropping it here is also what stops the two dictionaries
        // growing for as long as the window is open.
        let living = Set(snapshot.tabs.map(\.tabId))
        tabCpuHistory = tabCpuHistory.filter { living.contains($0.key) }
        tabMemoryHistory = tabMemoryHistory.filter { living.contains($0.key) }

        // A space's line is the rollup's, not the sum of its tabs': tabs in
        // one space share a WebKit process, and adding their identical
        // readings together would draw a graph of several times the memory
        // that is actually in use.
        var bySpace: [UUID: [TabResourceUsage]] = [:]
        for usage in snapshot.tabs {
            guard let space = usage.spaceID else { continue }
            bySpace[space, default: []].append(usage)
        }
        for (space, usages) in bySpace {
            let rollup = ActivityMath.rollup(of: usages)
            spaceCpuHistory[space, default: UsageHistory()].record(rollup.cpuPercentage)
            spaceMemoryHistory[space, default: UsageHistory()]
                .record(UsageFormat.megabytes(rollup.memoryBytes))
        }
        let livingSpaces = Set(bySpace.keys)
        spaceCpuHistory = spaceCpuHistory.filter { livingSpaces.contains($0.key) }
        spaceMemoryHistory = spaceMemoryHistory.filter { livingSpaces.contains($0.key) }
    }

    func cpuHistory(forSpace id: UUID) -> UsageHistory { spaceCpuHistory[id] ?? UsageHistory() }
    func memoryHistory(forSpace id: UUID) -> UsageHistory { spaceMemoryHistory[id] ?? UsageHistory() }

    func cpuHistory(forTab id: UUID) -> UsageHistory { tabCpuHistory[id] ?? UsageHistory() }
    func memoryHistory(forTab id: UUID) -> UsageHistory { tabMemoryHistory[id] ?? UsageHistory() }
}
