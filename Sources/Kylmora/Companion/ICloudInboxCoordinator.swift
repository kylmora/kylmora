import AppKit
import Combine
import Foundation

/// Monitors the iCloud Drive or local inbox folder for links dropped by iPhone / iPad Shortcuts (F-35).
@MainActor
final class ICloudInboxCoordinator: ObservableObject {
    static let shared = ICloudInboxCoordinator()

    @Published private(set) var isMonitoring: Bool = false
    @Published private(set) var processedCount: Int = 0
    @Published private(set) var lastReceivedLink: IPhoneLink?

    var inboxDirectory: URL {
        AppPaths.iCloudInboxDirectory
    }

    private weak var session: BrowserSession?
    private weak var windowController: BrowserWindowController?

    private var directorySource: DispatchSourceFileSystemObject?
    private var directoryFileDescriptor: CInt = -1
    private var pollTimer: Timer?
    private var isProcessing: Bool = false
    private var settingsObserver: Any?

    private init() {
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .iCloudInboxSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleSettingsChange()
            }
        }
    }

    /// Starts monitoring the iCloud Inbox folder.
    func start(session: BrowserSession, windowController: BrowserWindowController? = nil) {
        self.session = session
        self.windowController = windowController

        ensureInboxStructure()

        guard Settings.shared.iCloudInboxEnabled else {
            stop()
            return
        }

        startMonitoring()
        processInboxNow()
    }

    /// Stops monitoring the folder.
    func stop() {
        stopMonitoring()
    }

    private func handleSettingsChange() {
        if Settings.shared.iCloudInboxEnabled {
            if !isMonitoring, let session {
                start(session: session, windowController: windowController)
            }
        } else {
            stop()
        }
    }

    private func ensureInboxStructure() {
        let dir = inboxDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Drop helpful README in the root Kylmora folder
        let parentDir = dir.deletingLastPathComponent()
        let readmeURL = parentDir.appending(path: "iPhone-ShareSheet-Setup.txt")
        if !FileManager.default.fileExists(atPath: readmeURL.path(percentEncoded: false)) {
            let guide = AppleShortcutHelper.generateShortcutInstructions()
            try? guide.write(to: readmeURL, atomically: true, encoding: .utf8)
        }
    }

    private func startMonitoring() {
        stopMonitoring()

        let dir = inboxDirectory
        let path = dir.path(percentEncoded: false)
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // No directory to watch yet: poll, but not often.
            startPolling(every: 30)
            isMonitoring = true
            return
        }

        directoryFileDescriptor = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .link],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.processInboxNow()
            }
        }

        source.setCancelHandler { [fd] in
            close(fd)
        }

        directorySource = source
        source.resume()
        // The directory source is the real signal. The poll is a safety net
        // for a file iCloud materialises without a change event, so it runs
        // once a minute with room to coalesce, not every five seconds.
        startPolling(every: 60)
        isMonitoring = true
    }

    private func startPolling(every seconds: TimeInterval) {
        pollTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.processInboxNow()
            }
        }
        timer.tolerance = seconds / 4
        pollTimer = timer
    }

    private func stopMonitoring() {
        pollTimer?.invalidate()
        pollTimer = nil

        if let source = directorySource {
            source.cancel()
            directorySource = nil
            directoryFileDescriptor = -1
        } else if directoryFileDescriptor >= 0 {
            close(directoryFileDescriptor)
            directoryFileDescriptor = -1
        }

        isMonitoring = false
    }

    /// Manually or automatically checks the inbox folder and ingests pending links.
    func processInboxNow() {
        guard !isProcessing, let session else { return }
        isProcessing = true
        defer { isProcessing = false }

        let dir = inboxDirectory
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        // Sort oldest first
        let sorted = items.sorted {
            let d1 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let d2 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return d1 < d2
        }

        for fileURL in sorted {
            let ext = fileURL.pathExtension.lowercased()
            guard ext == "json" || ext == "txt" || ext == "url" || ext == "link" else {
                continue
            }

            // Skip readme or guide files if dropped inside inbox
            if fileURL.lastPathComponent.lowercased().contains("readme") {
                continue
            }

            guard let data = try? Data(contentsOf: fileURL) else {
                continue
            }

            var link: IPhoneLink?
            if ext == "json" {
                link = IPhoneLink.parse(jsonData: data)
            } else {
                if let str = String(data: data, encoding: .utf8) {
                    link = IPhoneLink.parse(text: str)
                }
            }

            if let link {
                // Delete file immediately so it's never processed twice
                try? FileManager.default.removeItem(at: fileURL)

                IPhoneLinkReceiver.shared.receive(
                    link: link,
                    session: session,
                    windowController: windowController
                )

                processedCount += 1
                lastReceivedLink = link
            }
        }
    }

    /// Reveals the iCloud Inbox folder in Finder.
    func revealInboxInFinder() {
        ensureInboxStructure()
        NSWorkspace.shared.activateFileViewerSelecting([inboxDirectory])
    }
}
