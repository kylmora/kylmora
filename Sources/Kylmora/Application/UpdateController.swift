import AppKit
import Foundation

/// Coordinates automatic background update checks, manual checks, in-app download
/// and relaunch workflow in the style of Sparkle.
@MainActor
final class UpdateController: NSObject, URLSessionDownloadDelegate {
    static let shared = UpdateController()

    enum State: Equatable {
        case idle
        case checking
        case updateAvailable(UpdateCheck.Release)
        case downloading(progress: Double, bytesWritten: Int64, totalBytes: Int64)
        case readyToInstall(fileURL: URL, version: String)
        case error(String)
    }

    private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }
    var onStateChange: ((State) -> Void)?

    private(set) var updateWindowController: UpdateWindowController?
    private var downloadSession: URLSession?
    private var currentDownloadTask: URLSessionDownloadTask?
    private var activeRelease: UpdateCheck.Release?
    private var downloadedFileURL: URL?
    private var backgroundTimer: Timer?

    /// Injectable provider for checking updates, allowing tests to run without network access.
    var checkOutcomeProvider: (String) async -> UpdateCheck.Outcome = { current in
        await UpdateCheck.run(current: current)
    }

    /// Injectable relaunch handler for unit tests.
    var relaunchHandler: ((URL) -> Void)?

    override init() {
        super.init()
    }

    // MARK: - Background Scheduling

    func startBackgroundChecking() {
        guard backgroundTimer == nil else { return }

        // Initial check after launch if enabled
        if Settings.shared.automaticallyCheckForUpdates {
            let lastCheck = Settings.shared.lastUpdateCheckDate
            let shouldCheckNow = lastCheck == nil || Date().timeIntervalSince(lastCheck!) >= 86400
            if shouldCheckNow {
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds grace period
                    guard let self, Settings.shared.automaticallyCheckForUpdates else { return }
                    self.checkForUpdates(userInitiated: false)
                }
            }
        }

        // Periodic check every 4 hours
        backgroundTimer = Timer.scheduledTimer(withTimeInterval: 14400, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self, Settings.shared.automaticallyCheckForUpdates else { return }
                let lastCheck = Settings.shared.lastUpdateCheckDate
                if lastCheck == nil || Date().timeIntervalSince(lastCheck!) >= 86400 {
                    self.checkForUpdates(userInitiated: false)
                }
            }
        }
    }

    func stopBackgroundChecking() {
        backgroundTimer?.invalidate()
        backgroundTimer = nil
    }

    // MARK: - Update Checking

    func checkForUpdates(userInitiated: Bool, in parentWindow: NSWindow? = nil) {
        guard state == .idle || isFailedState else { return }

        state = .checking

        Task { [weak self] in
            guard let self else { return }
            let current = AppInfo.version
            let outcome = await self.checkOutcomeProvider(current)
            self.handleCheckOutcome(outcome, userInitiated: userInitiated, in: parentWindow)
        }
    }

    private var isFailedState: Bool {
        if case .error = state { return true }
        return false
    }

    private func handleCheckOutcome(_ outcome: UpdateCheck.Outcome, userInitiated: Bool, in parentWindow: NSWindow?) {
        Settings.shared.lastUpdateCheckDate = Date()

        switch outcome {
        case .upToDate(let current):
            state = .idle
            if userInitiated {
                showUpToDateAlert(current: current, in: parentWindow)
            }

        case .unreachable(let reason):
            state = .error(reason)
            if userInitiated {
                showErrorAlert(reason: reason, in: parentWindow)
            }

        case .available(let version, let url, let notes):
            let release = UpdateCheck.Release(version: version, url: url, notes: notes)
            self.activeRelease = release
            state = .updateAvailable(release)

            // If background check and user chose to skip this version, ignore
            if !userInitiated, let skipped = Settings.shared.skippedUpdateVersion, skipped == version {
                state = .idle
                return
            }

            // If background check and auto-download is enabled, download automatically
            if !userInitiated && Settings.shared.automaticallyDownloadUpdates && release.updatePackageURL != nil {
                presentUpdateWindow(for: release)
                startDownload(for: release)
                return
            }

            presentUpdateWindow(for: release)
        }
    }

    // MARK: - Presentation

    func presentUpdateWindow(for release: UpdateCheck.Release) {
        if let existing = updateWindowController, existing.window?.isVisible == true {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        let windowController = UpdateWindowController(release: release, controller: self)
        self.updateWindowController = windowController
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showUpToDateAlert(current: String, in parentWindow: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "You\u{2019}re up to date!"
        alert.informativeText = "\(AppInfo.name) \(current) is currently the newest version available."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")

        if let parentWindow {
            alert.beginSheetModal(for: parentWindow)
        } else {
            alert.runModal()
        }
    }

    private func showErrorAlert(reason: String, in parentWindow: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "Update Check Failed"
        alert.informativeText = reason
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")

        if let parentWindow {
            alert.beginSheetModal(for: parentWindow)
        } else {
            alert.runModal()
        }
    }

    // MARK: - Downloading

    func startDownload(for release: UpdateCheck.Release) {
        guard let downloadURL = release.updatePackageURL else {
            if let webURL = release.url {
                NSWorkspace.shared.open(webURL)
            }
            return
        }

        self.activeRelease = release

        // Local test/file URL handling
        if downloadURL.isFileURL {
            self.downloadedFileURL = downloadURL
            self.state = .readyToInstall(fileURL: downloadURL, version: release.version)
            self.updateWindowController?.transition(to: .readyToInstall(fileURL: downloadURL))
            return
        }

        state = .downloading(progress: 0.0, bytesWritten: 0, totalBytes: 0)
        updateWindowController?.transition(to: .downloading(progress: 0.0, bytesWritten: 0, totalBytes: 0))

        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        self.downloadSession = session

        let task = session.downloadTask(with: downloadURL)
        self.currentDownloadTask = task
        task.resume()
    }

    func cancelDownload() {
        currentDownloadTask?.cancel()
        currentDownloadTask = nil
        downloadSession?.invalidateAndCancel()
        downloadSession = nil
        state = .idle
    }

    // MARK: - Installation & Relaunch

    func relaunchAndInstall() {
        guard case .readyToInstall(let fileURL, _) = state else { return }

        if let customHandler = relaunchHandler {
            customHandler(fileURL)
            return
        }

        let fileExtension = fileURL.pathExtension.lowercased()
        if fileExtension == "dmg" {
            // Open DMG installer and terminate current instance
            NSWorkspace.shared.open(fileURL)
            NSApp.terminate(nil)
        } else if fileExtension == "zip" {
            // Unpack or reveal and terminate
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            NSApp.terminate(nil)
        } else {
            NSWorkspace.shared.open(fileURL)
            NSApp.terminate(nil)
        }
    }

    // MARK: - URLSessionDownloadDelegate

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let updatesDirectory = AppPaths.supportDirectory.appending(path: "Updates")
        try? FileManager.default.createDirectory(at: updatesDirectory, withIntermediateDirectories: true)

        let suggestedFilename = downloadTask.response?.suggestedFilename ?? "Kylmora-Update"
        let destinationURL = updatesDirectory.appending(path: suggestedFilename)

        try? FileManager.default.removeItem(at: destinationURL)
        do {
            try FileManager.default.moveItem(at: location, to: destinationURL)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.downloadedFileURL = destinationURL
                let version = self.activeRelease?.version ?? AppInfo.version
                self.state = .readyToInstall(fileURL: destinationURL, version: version)
                self.updateWindowController?.transition(to: .readyToInstall(fileURL: destinationURL))
            }
        } catch {
            Task { @MainActor [weak self] in
                self?.state = .error("Failed to save downloaded update: \(error.localizedDescription)")
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0.0

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.state = .downloading(
                progress: progress,
                bytesWritten: totalBytesWritten,
                totalBytes: totalBytesExpectedToWrite
            )
            self.updateWindowController?.transition(
                to: .downloading(
                    progress: progress,
                    bytesWritten: totalBytesWritten,
                    totalBytes: totalBytesExpectedToWrite
                )
            )
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.state = .error(error.localizedDescription)
            self.updateWindowController?.transition(to: .prompt)
        }
    }
}
