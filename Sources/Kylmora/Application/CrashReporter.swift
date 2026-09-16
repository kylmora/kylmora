import AppKit
import Darwin
import Foundation

/// Writes a report when Kylmora dies, and asks what to do with it next time.
///
/// macOS writes its own crash logs, but they are in a folder most people
/// never open. This keeps a plain-text report of Kylmora's own -- when, which
/// signal, and the stack -- where Kylmora can find it, so the next launch can
/// say "Kylmora crashed last time" and, if the user wants, keep the report.
///
/// The signal handler does only what a signal handler may: it writes a
/// buffer composed at install time and the raw backtrace to a file opened
/// at install time. Nothing is allocated, nothing is locked.
enum CrashReporter {
    private static var pendingPath: String { AppPaths.supportDirectory.appending(path: "crash-pending.txt").path(percentEncoded: false) }
    private static var reportsDirectory: URL { AppPaths.supportDirectory.appending(path: "CrashReports", directoryHint: .isDirectory) }

    private nonisolated(unsafe) static var descriptor: Int32 = -1
    private nonisolated(unsafe) static var header: [UInt8] = []

    /// Installs the handlers. Called once, early.
    @MainActor
    static func install() {
        AppPaths.ensureSupportDirectory()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let text = "Kylmora \(version) crashed at \(Date.now.formatted(date: .abbreviated, time: .shortened)) (launched)\n"
        header = Array(text.utf8)
        descriptor = open(pendingPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        // The file exists from now on; an empty one at the next launch means
        // a clean exit, and it is removed then.
        for sig in [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP, SIGFPE] {
            signal(sig, handle)
        }
        NSSetUncaughtExceptionHandler { exception in
            let text = "Uncaught exception \(exception.name.rawValue): \(exception.reason ?? "")\n"
            write(CrashReporter.descriptor, Array(text.utf8), text.utf8.count)
            for line in exception.callStackSymbols {
                write(CrashReporter.descriptor, Array((line + "\n").utf8), line.utf8.count + 1)
            }
        }
    }

    private static let handle: @convention(c) (Int32) -> Void = { sig in
        let fd = CrashReporter.descriptor
        guard fd >= 0 else { return }
        CrashReporter.header.withUnsafeBufferPointer { _ = write(fd, $0.baseAddress, $0.count) }
        var name: [UInt8]
        switch sig {
        case SIGSEGV: name = Array("signal SIGSEGV\n".utf8)
        case SIGBUS: name = Array("signal SIGBUS\n".utf8)
        case SIGILL: name = Array("signal SIGILL\n".utf8)
        case SIGABRT: name = Array("signal SIGABRT\n".utf8)
        case SIGTRAP: name = Array("signal SIGTRAP\n".utf8)
        default: name = Array("signal SIGFPE\n".utf8)
        }
        name.withUnsafeBufferPointer { _ = write(fd, $0.baseAddress, $0.count) }
        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 128)
        let count = backtrace(&frames, Int32(frames.count))
        backtrace_symbols_fd(&frames, count, fd)
        signal(sig, SIG_DFL)
        raise(sig)
    }

    /// Marks a clean exit: the pending file is emptied so the next launch
    /// has nothing to ask about.
    static func markCleanExit() {
        if descriptor >= 0 { ftruncate(descriptor, 0) }
    }

    /// At launch: if the last run left a report, keep it, ask, or drop it.
    @MainActor
    static func reviewPendingReport(policy: CrashReportPolicy) {
        let pending = URL(fileURLWithPath: pendingPath)
        guard let data = try? Data(contentsOf: pending), !data.isEmpty else { return }
        // The file is reopened for this run above, so the old contents must
        // be read before install truncates it: callers review first.
        let report = String(decoding: data, as: UTF8.self)
        try? FileManager.default.removeItem(at: pending)
        switch policy {
        case .never:
            return
        case .always:
            keep(report)
        case .ask:
            let alert = NSAlert()
            alert.messageText = "Kylmora crashed the last time it ran."
            alert.informativeText = """
                Keep the crash report? It is a short text file in Kylmora's own folder, \
                and nothing is sent anywhere. Send It writes you an email draft with the \
                top of the report in it -- you read it and press Send, or don't.
                """
            alert.addButton(withTitle: "Keep Report")
            alert.addButton(withTitle: "Send It\u{2026}")
            alert.addButton(withTitle: "Delete")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                keep(report)
            case .alertSecondButtonReturn:
                // Kept as well as sent: the draft carries an excerpt, and the
                // file the user is shown is the whole thing, to attach if we
                // ask for it.
                let saved = keep(report)
                SupportContact.compose(.crash(SupportContact.excerpt(of: report)))
                if let saved { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
            default:
                return
            }
        }
    }

    /// Writes the report into Kylmora's own folder and returns where it went.
    @discardableResult
    private static func keep(_ report: String) -> URL? {
        try? FileManager.default.createDirectory(at: reportsDirectory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let destination = reportsDirectory.appending(path: "Kylmora-\(stamp).txt")
        do {
            try Data(report.utf8).write(to: destination)
            return destination
        } catch {
            return nil
        }
    }

    static var reportCount: Int {
        (try? FileManager.default.contentsOfDirectory(atPath: reportsDirectory.path(percentEncoded: false)))?.count ?? 0
    }
}
