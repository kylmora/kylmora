import Darwin
import Foundation

/// Self-measurement, so performance claims come from the running app rather
/// than from guesses.
///
/// Only the browser's own process can be measured from inside it: WebKit's
/// content, network and GPU processes are XPC services parented to `launchd`,
/// with no public API tying one back to the client that started it. Measuring
/// those is the job of `Tools/measure.sh`, which diffs the set of WebKit
/// processes before and after Kylmora runs.
enum Metrics {
    /// Physical footprint in bytes: the number Activity Monitor shows as
    /// "Memory", and the one the kernel uses for memory limits. Resident size
    /// counts shared framework pages and overstates a lightweight AppKit app
    /// substantially.
    static func physicalFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }

    /// Seconds from `exec` to now, read from the kernel's record of this
    /// process. Timing from `main` would miss dynamic linking and framework
    /// loading, which is most of a small app's launch.
    static func timeSinceProcessStart() -> TimeInterval? {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride

        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0 else { return nil }
        let started = info.kp_proc.p_starttime
        let startSeconds = Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
        return Date().timeIntervalSince1970 - startSeconds
    }

    /// Hidden preference that turns measurement logging on:
    /// `defaults write com.kylmora.Kylmora KylmoraMeasurementLogging -bool YES`.
    ///
    /// A preference rather than an environment variable because LaunchServices
    /// starts the app, and `open --env` does not reliably reach it.
    static var isLoggingEnabled: Bool {
        UserDefaults.standard.bool(forKey: "KylmoraMeasurementLogging")
    }

    /// Measurements go to a file rather than the unified log: a GUI app started
    /// by LaunchServices does not reliably surface `NSLog` output to
    /// `log show`, and a file needs no permissions to read back.
    static var logFile: URL { AppPaths.supportDirectory.appending(path: "measurements.log") }

    static func log(_ message: String) {
        guard isLoggingEnabled else { return }
        let stamp = ISO8601DateFormatter().string(from: .now)
        guard let line = "\(stamp) \(message)\n".data(using: .utf8) else { return }

        // Measurement is a diagnostic. Every failure here is swallowed on
        // purpose: losing a line must never affect the browser.
        AppPaths.ensureSupportDirectory()
        if let handle = try? FileHandle(forWritingTo: logFile) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            do { try line.write(to: logFile) } catch { return }
        }
    }

    /// Logs launch timing and footprint, so the numbers can be collected
    /// without shipping a measurement UI.
    static func reportLaunchIfRequested(stage: String) {
        let elapsed = timeSinceProcessStart().map { String(format: "%.3f", $0) } ?? "?"
        let footprint = physicalFootprint().map { String(format: "%.1f", Double($0) / 1_048_576) } ?? "?"
        log("\(stage) elapsed=\(elapsed)s footprint=\(footprint)MB")
    }
}
