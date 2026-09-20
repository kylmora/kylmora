import AppKit
import Foundation

/// What the Task Manager is currently talking about.
///
/// Three depths, because "the browser is using four gigabytes" is only ever the
/// first question. The second is which space -- people keep Work and Personal
/// open for days and one of them is always the expensive one -- and the third
/// is which page in it. The window answers all three with the same charts
/// rather than with three different screens, so what you learn reading one
/// scope you can read in the next.
enum ActivityScope: Equatable, Hashable {
    /// Every space, every tab, plus Kylmora's own process.
    case everything
    case space(UUID)
    case tab(UUID)
}

/// One scope's numbers, gathered from a snapshot.
///
/// Everything the cards and the stat grid show, worked out in one place: the
/// same arithmetic was otherwise going to be written once for the whole
/// browser, once per space and once per tab, and the three would disagree the
/// first time one of them was changed.
struct ActivityRollup: Equatable {
    var memoryBytes: UInt64 = 0
    var cpuPercentage: Double = 0
    var tabCount = 0
    var activeTabCount = 0
    var suspendedTabCount = 0
    var audibleTabCount = 0
    /// How many WebKit content processes the tabs in this scope are spread
    /// across. Rarely one per tab: tabs in one space share a process, which is
    /// why the memory column and the sum of its rows are not the same number.
    var processCount = 0
    var heaviestTitle: String?
}

/// One bar in a ranked chart: what it is, how big, and how big relative to the
/// biggest.
struct ActivityBar: Equatable {
    var id: UUID
    var label: String
    var value: Double
    /// What is written at the end of the bar.
    var caption: String
    /// 0-1 against the largest bar in the set, which is what makes a chart of
    /// five bars readable whether the top one is 90 MB or 9 GB.
    var fraction: Double
    var isDimmed = false
}

/// The arithmetic behind the window, kept out of the views.
///
/// Every function here is a pure one over a snapshot, so the rules that are
/// easy to get quietly wrong -- which tabs belong to a scope, what a shared
/// process does to a total -- are tested rather than eyeballed on a live
/// browser where no two readings are the same.
enum ActivityMath {
    /// The tabs a scope covers.
    static func tabs(in scope: ActivityScope, from usages: [TabResourceUsage]) -> [TabResourceUsage] {
        switch scope {
        case .everything:
            return usages
        case .space(let id):
            return usages.filter { $0.spaceID == id }
        case .tab(let id):
            return usages.filter { $0.tabId == id }
        }
    }

    /// The totals for a set of tabs.
    ///
    /// Memory and CPU are counted once per WebKit process, not once per tab. A
    /// space with eight tabs in one content process costs what that process
    /// costs; adding the eight identical readings together would report eight
    /// times the truth, which is the single most common way a task manager
    /// lies.
    static func rollup(of usages: [TabResourceUsage]) -> ActivityRollup {
        var rollup = ActivityRollup()
        var seen: Set<pid_t> = []
        var heaviest: UInt64 = 0

        for usage in usages {
            rollup.tabCount += 1
            if usage.isSuspended {
                rollup.suspendedTabCount += 1
            } else {
                rollup.activeTabCount += 1
            }
            if usage.isPlayingAudio { rollup.audibleTabCount += 1 }

            if usage.memoryBytes > heaviest {
                heaviest = usage.memoryBytes
                rollup.heaviestTitle = usage.title
            }

            guard !usage.isSuspended else { continue }
            guard let pid = usage.pid else {
                rollup.memoryBytes += usage.memoryBytes
                rollup.cpuPercentage += usage.cpuPercentage
                continue
            }
            guard seen.insert(pid).inserted else { continue }
            rollup.processCount += 1
            rollup.memoryBytes += usage.memoryBytes
            rollup.cpuPercentage += usage.cpuPercentage
        }
        return rollup
    }

    /// Spaces ranked by what they cost, heaviest first.
    ///
    /// The chart the whole window exists for: it is the one view in Kylmora
    /// that answers "which of the places I keep open is the expensive one",
    /// and it is a question a list of forty tabs cannot answer however well it
    /// is sorted.
    @MainActor
    static func spaceBars(
        from usages: [TabResourceUsage],
        spaces: [Space],
        limit: Int = 8,
        highlighting: UUID? = nil
    ) -> [ActivityBar] {
        let bars: [ActivityBar] = spaces.compactMap { space in
            let mine = usages.filter { $0.spaceID == space.id }
            guard !mine.isEmpty else { return nil }
            let rollup = rollup(of: mine)
            // A space whose tabs are all asleep costs nothing, and a row of
            // zero is a row that can never say anything else. Somebody with
            // eighteen spaces open -- which is what spaces are for -- would
            // otherwise get a chart of fifteen empty tracks with the one
            // answer buried at the top of it.
            guard rollup.memoryBytes > 0 else { return nil }
            return ActivityBar(
                id: space.id,
                label: space.name.isEmpty ? "Untitled Space" : space.name,
                value: Double(rollup.memoryBytes),
                caption: UsageFormat.memory(rollup.memoryBytes),
                fraction: 0,
                isDimmed: highlighting != nil && highlighting != space.id
            )
        }
        return scaled(Array(bars.sorted { $0.value > $1.value }.prefix(limit)))
    }

    /// Pages ranked by memory, heaviest first, at most `limit` of them.
    ///
    /// Capped because the point is the shape: five bars say "one page is doing
    /// this" or "it is spread evenly" at a glance, and forty say neither. The
    /// table underneath is where the long tail lives.
    static func tabBars(from usages: [TabResourceUsage], limit: Int = 6, highlighting: UUID? = nil) -> [ActivityBar] {
        let ranked = usages
            .filter { !$0.isSuspended }
            .sorted { $0.memoryBytes > $1.memoryBytes }
            .prefix(limit)
        let bars = ranked.map { usage in
            ActivityBar(
                id: usage.tabId,
                label: usage.domain.isEmpty ? usage.title : usage.domain,
                value: Double(usage.memoryBytes),
                caption: UsageFormat.memory(usage.memoryBytes),
                fraction: 0,
                isDimmed: highlighting != nil && highlighting != usage.tabId
            )
        }
        return scaled(bars)
    }

    /// Fills in each bar's share of the biggest one.
    private static func scaled(_ bars: [ActivityBar]) -> [ActivityBar] {
        guard let largest = bars.map(\.value).max(), largest > 0 else { return bars }
        return bars.map { bar in
            var scaled = bar
            scaled.fraction = bar.value / largest
            return scaled
        }
    }

    /// Where the browser's memory actually goes, as the slices of one bar.
    ///
    /// Three parts and no more: the app itself, the pages, and WebKit's GPU
    /// helper. It is the answer to the complaint every browser gets -- "why is
    /// it using so much" -- and the honest answer is usually "the pages are",
    /// which a single total can never say.
    static func memorySlices(of snapshot: ResourceSnapshot) -> [ActivityBar] {
        let parts: [(String, UInt64, UUID)] = [
            ("Kylmora", snapshot.browserMemoryBytes, UUID()),
            ("Pages", snapshot.webContentMemoryBytes, UUID()),
            ("GPU process", snapshot.gpuProcessMemoryBytes, UUID())
        ]
        let total = Double(snapshot.totalMemoryBytes)
        return parts.compactMap { name, bytes, id in
            guard bytes > 0 else { return nil }
            return ActivityBar(
                id: id,
                label: name,
                value: Double(bytes),
                caption: UsageFormat.memory(bytes),
                fraction: total > 0 ? Double(bytes) / total : 0
            )
        }
    }
}
