import Darwin
import Foundation
import IOKit
import WebKit

/// What can honestly be said about the GPU from inside a browser.
///
/// Less than about CPU and memory, and the shape of the API is the reason. A
/// page does not have a GPU process of its own: WebKit runs one
/// `com.apple.WebKit.GPU` for the whole browser, and every page's compositing,
/// canvas and video decoding goes through it. There is no per-page accounting
/// coming out of it, and no public call that would produce one.
///
/// What *can* be attributed is GPU time per process. Every Metal client on an
/// Apple GPU turns up in the IORegistry as an `AGXDeviceUserClient` carrying
/// the pid that opened it and an `AppUsage` list with the nanoseconds of GPU
/// time it has used. Adding up the clients belonging to Kylmora and its helpers
/// and dividing by wall-clock time gives Kylmora's own share of the GPU, which
/// is the number this card is actually about: whether the GPU being busy is
/// this browser's doing.
///
/// So: Kylmora's own share is the headline, the machine's total is context
/// beside it, and neither is ever split per space -- because the one process
/// doing the work serves every page in every space at once.
enum GPUMetrics {
    /// How busy the GPU is, 0-100, or nil where the driver does not say.
    ///
    /// Read from `IOAccelerator`'s `PerformanceStatistics`, the same dictionary
    /// Activity Monitor's GPU history reads. The key is spelled differently by
    /// different drivers -- Apple silicon, AMD and Intel each have their own --
    /// so several are tried and the busiest accelerator wins, which is the
    /// right answer on a Mac with both an integrated and a discrete GPU.
    static func deviceUtilisation() -> Double? {
        guard let matching = IOServiceMatching("IOAccelerator") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var busiest: Double?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var unmanaged: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let properties = unmanaged?.takeRetainedValue() as? [String: Any],
                  let statistics = properties["PerformanceStatistics"] as? [String: Any]
            else { continue }

            for key in ["Device Utilization %", "GPU Activity(%)", "GPU Core Utilization"] {
                guard let number = statistics[key] as? NSNumber else { continue }
                // "GPU Core Utilization" is nanoseconds-of-a-second busy on
                // some drivers, not a percentage; anything far past 100 is that
                // rather than a GPU working eight thousand percent hard.
                let value = number.doubleValue
                let percentage = value > 100 ? value / 10_000_000 : value
                busiest = max(busiest ?? 0, min(percentage, 100))
                break
            }
        }
        return busiest
    }

    /// GPU nanoseconds used so far by the given processes.
    ///
    /// Walked out of the IORegistry rather than asked of a framework, because
    /// no framework offers it. Nil where nothing could be read at all -- an
    /// Intel or AMD Mac, whose drivers publish no per-client `AppUsage` -- as
    /// opposed to zero, which means Kylmora has been given GPU time and has
    /// used none of it.
    static func accumulatedGPUTime(ofPids pids: Set<pid_t>) -> UInt64? {
        guard !pids.isEmpty, let matching = IOServiceMatching("IOAccelerator") else { return nil }
        var accelerators: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &accelerators) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(accelerators) }

        var found = false
        var total: UInt64 = 0
        while case let accelerator = IOIteratorNext(accelerators), accelerator != 0 {
            defer { IOObjectRelease(accelerator) }
            // The clients hang under the accelerator and are not registered
            // services of their own, so they are reached by walking the tree
            // rather than by matching on their class.
            var clients: io_iterator_t = 0
            guard IORegistryEntryCreateIterator(
                accelerator,
                kIOServicePlane,
                IOOptionBits(kIORegistryIterateRecursively),
                &clients
            ) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(clients) }

            while case let client = IOIteratorNext(clients), client != 0 {
                defer { IOObjectRelease(client) }
                // Two properties by name rather than the whole dictionary: this
                // runs every two seconds while the window is open, and the
                // whole dictionary of every client is a great deal of copying
                // to throw away.
                guard let creator = IORegistryEntryCreateCFProperty(
                    client, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0
                )?.takeRetainedValue() as? String,
                    let pid = pid(fromCreator: creator),
                    pids.contains(pid)
                else { continue }
                found = true
                guard let usage = IORegistryEntryCreateCFProperty(
                    client, "AppUsage" as CFString, kCFAllocatorDefault, 0
                )?.takeRetainedValue() as? [[String: Any]] else { continue }
                for entry in usage {
                    total += (entry["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0
                }
            }
        }
        return found ? total : nil
    }

    /// The pid out of `"pid 1234, Kylmora"`.
    static func pid(fromCreator creator: String) -> pid_t? {
        guard creator.hasPrefix("pid ") else { return nil }
        let digits = creator.dropFirst(4).prefix { $0.isNumber }
        return pid_t(digits)
    }

    /// The pid of WebKit's GPU process, asked of a live web view.
    ///
    /// `_gpuProcessIdentifier` is WebKit SPI, so it is asked for rather than
    /// called: a build of WebKit without it answers `responds(to:)` with false
    /// and the GPU card simply shows the device figure alone. Any web view will
    /// do -- there is one GPU process per browser, not per page -- so the first
    /// loaded tab that answers is the one used.
    @MainActor
    static func processIdentifier(in session: BrowserSession) -> pid_t? {
        let selector = Selector(("_gpuProcessIdentifier"))
        for tab in session.allTabs {
            guard let webView = tab.currentWebView, webView.responds(to: selector) else { continue }
            guard let pid = webView.value(forKey: "_gpuProcessIdentifier") as? pid_t, pid > 0 else { continue }
            return pid
        }
        return nil
    }
}

/// One process's CPU and memory, from `proc_pidinfo`.
///
/// Shared by the per-tab sampler, the GPU process reading and the browser's own
/// row, because all three want the same two numbers and the CPU one is only
/// meaningful as a difference between two readings -- which means the sampling
/// has to be done the same way everywhere, or the columns disagree.
struct ProcessSampler {
    struct Reading {
        var memoryBytes: UInt64
        /// Total CPU time the process has ever used, in nanoseconds.
        var cpuNanoseconds: UInt64
    }

    private var previous: [pid_t: (timestamp: TimeInterval, cpuNanoseconds: UInt64)] = [:]

    static func read(pid: pid_t) -> Reading? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        return Reading(
            memoryBytes: info.pti_resident_size,
            cpuNanoseconds: info.pti_total_user + info.pti_total_system
        )
    }

    /// Memory now, and CPU as a share of wall-clock time since this process was
    /// last asked. Zero the first time, because a percentage needs two points.
    mutating func sample(pid: pid_t, now: TimeInterval) -> (memoryBytes: UInt64, cpuPercentage: Double)? {
        guard let reading = Self.read(pid: pid) else { return nil }
        var percentage = 0.0
        if let last = previous[pid] {
            let elapsed = now - last.timestamp
            if elapsed > 0.1, reading.cpuNanoseconds >= last.cpuNanoseconds {
                let busySeconds = Double(reading.cpuNanoseconds - last.cpuNanoseconds) / 1_000_000_000
                percentage = busySeconds / elapsed * 100
            }
        }
        previous[pid] = (now, reading.cpuNanoseconds)
        return (reading.memoryBytes, percentage)
    }

    /// Drops the processes that are no longer around, so a browser that has
    /// opened and closed ten thousand tabs is not still holding their pids.
    mutating func forgetEveryPidExcept(_ kept: Set<pid_t>) {
        previous = previous.filter { kept.contains($0.key) }
    }
}
