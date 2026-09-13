import AppKit
import Combine
import WebKit
import UniformTypeIdentifiers

/// Owns every download: the policy that turns a navigation into one, the
/// `WKDownloadDelegate` behind the transfer, and the list the user sees.
///
/// A singleton because a download outlives the tab that started it. WebKit
/// keeps the transfer running after the web view goes away, and a file that
/// finishes into Downloads has to appear somewhere the user can still find it,
/// so the list cannot belong to a tab or a space.
///
/// Everything here is main-actor: `WKDownload`, its delegate callbacks and the
/// list view all are, so there is nothing to hop between and no shared mutable
/// state to guard.
@MainActor
final class DownloadManager {
    static let shared = DownloadManager()

    enum Change {
        /// Rows were added or removed.
        case list
        /// One row's state changed.
        case download(Download)
    }

    let changes = PassthroughSubject<Change, Never>()

    /// Newest first, which is the order the list shows and the order the cap
    /// trims from the wrong end of.
    private(set) var downloads: [Download] = []

    /// True while anything is transferring. The list view polls only then.
    var hasActiveDownloads: Bool { downloads.contains { $0.state == .running } }

    /// Where the list hangs from: the sidebar's Downloads button. Set by the
    /// sidebar, because the manager must not have to know about the chrome,
    /// and a closure rather than a view because the footer rebuilds its
    /// buttons whenever its actions are set.
    var listAnchor: (() -> NSView?)?

    private let store: DownloadStore
    private var delegate: DownloadDelegate?
    /// Held between openings, so the list keeps its scroll position and the
    /// manager has one thing to talk to rather than a window and a view.
    private var listPopover: NSPopover?
    private var listContent: DownloadsPopover?
    private var saveTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    /// Matches the session's write delay: a burst of state changes collapses
    /// into one file write.
    private static let saveDelay = Duration.seconds(1)

    init(store: DownloadStore = DownloadStore()) {
        self.store = store
        downloads = store.load().map(Download.init(record:))
        delegate = DownloadDelegate(manager: self)

        // The debounced write would be lost on quit. Observed here rather
        // than added as a line in `AppDelegate` so the whole feature stays
        // self-contained, and through Combine because the sink is delivered
        // on the posting thread, which for this notification is the main
        // one, with no unchecked escape hatch.
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.saveNow() }
            .store(in: &cancellables)
    }

    // MARK: - Navigation policy

    /// Whether a response should be downloaded instead of displayed.
    ///
    /// Two cases, and WebKit answers neither on its own for an embedded web
    /// view. `canShowMIMEType` is false for anything the engine cannot render —
    /// a zip, an installer, a binary. `Content-Disposition: attachment` is the
    /// server saying "save this" about something WebKit *could* render, which
    /// is how a PDF or a CSV is offered for download.
    func policy(for navigationResponse: WKNavigationResponse) -> WKNavigationResponsePolicy {
        if !navigationResponse.canShowMIMEType { return .download }

        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment") {
            return .download
        }
        return .allow
    }

    /// Whether a navigation should be downloaded before it ever starts. True
    /// for `<a download>`, which WebKit surfaces as `shouldPerformDownload`.
    func policy(for navigationAction: WKNavigationAction) -> WKNavigationActionPolicy {
        navigationAction.shouldPerformDownload ? .download : .allow
    }

    /// Takes ownership of a download WebKit has just created. Assigning the
    /// delegate is what starts the transfer talking to us; until then WebKit
    /// holds its callbacks.
    func adopt(_ download: WKDownload) {
        download.delegate = delegate
    }

    // MARK: - User actions

    func cancel(_ download: Download) {
        guard let webKitDownload = download.webKitDownload else { return }
        Task { [weak self] in
            // WebKit hands back resume data here rather than through the
            // failure callback, so cancelling is the one path that can leave a
            // download resumable on purpose.
            let resumeData = await webKitDownload.cancel()
            download.markCancelled(resumeData: resumeData)
            self?.changed(download)
        }
    }

    /// Resumes where the transfer stopped when WebKit gave us the data to do
    /// so, and otherwise starts the same URL again from the beginning.
    ///
    /// Both need a live `WKWebView`: `resumeDownload(fromResumeData:)` and
    /// `startDownload(using:)` are methods on the web view, not on `WKDownload`.
    func retry(_ download: Download) {
        guard let host = download.host else { return }
        let resumeData = download.resumeData

        Task { [weak self] in
            let webKitDownload: WKDownload
            if let resumeData {
                webKitDownload = await host.resumeDownload(fromResumeData: resumeData)
            } else {
                webKitDownload = await host.startDownload(using: URLRequest(url: download.sourceURL))
            }
            // The row must know its new transfer before the delegate is
            // attached: the destination callback arrives as soon as it is, and
            // that callback finds the row by identity.
            download.restart(with: webKitDownload, host: host, resuming: resumeData != nil)
            webKitDownload.delegate = self?.delegate
            self?.changed(download)
        }
    }

    func remove(_ download: Download) {
        cancel(download)
        downloads.removeAll { $0 === download }
        changes.send(.list)
        scheduleSave()
    }

    /// Clears finished, failed and cancelled rows; anything still transferring
    /// stays, because removing it would be a silent cancel.
    func clearCompleted() {
        downloads.removeAll { $0.state != .running }
        changes.send(.list)
        scheduleSave()
    }

    /// Opens the downloads list beside the sidebar's Downloads button, building
    /// the popover the first time.
    ///
    /// The manager owns the popover rather than the other way round so that the
    /// menu command, the button and the automatic reveal below are one call,
    /// and so the integration surface is a closure rather than a stored
    /// property and an action.
    func showList(activating: Bool = true) {
        guard let target = listTarget() else { return }
        let content = listContent ?? DownloadsPopover(manager: self)
        listContent = content
        // A row can have finished while the list was closed, so it reloads on
        // the way in rather than trusting what it was showing last time -- and
        // its view is loaded first, so the reload lands on a built table rather
        // than racing the one `viewDidLoad` runs.
        content.loadViewIfNeeded()
        content.reload()

        let popover = listPopover ?? NSPopover()
        popover.contentViewController = content
        // Semitransient, not transient: Show in Finder and Open hand the user
        // to another app, and having the list vanish behind them would lose
        // the place they were reading. A click back into the page closes it.
        popover.behavior = .semitransient
        popover.delegate = content
        listPopover = popover
        popover.show(relativeTo: target.rect, of: target.view, preferredEdge: .maxX)

        // A download that appeared on its own must not take the keyboard off
        // the page it was started from; a button the user pressed by hand may.
        if activating { popover.contentViewController?.view.window?.makeKey() }
    }

    /// The button the list hangs from, or the edge it lives on when the sidebar
    /// is out of the way. A fallback rather than a second window: the list is
    /// always attached to something the user can see, never floating free.
    private func listTarget() -> (view: NSView, rect: NSRect)? {
        // In the window, not merely in the view tree: compact mode parks the
        // sidebar outside the window's bounds, and a popover hung off a button
        // that is out there would land wherever AppKit clamps it -- which is the
        // floating list this exists to avoid.
        if let button = listAnchor?(), let window = button.window,
           let host = window.contentView,
           !button.isHiddenOrHasHiddenAncestor,
           host.bounds.intersects(button.convert(button.bounds, to: host)) {
            return (button, button.bounds)
        }
        guard let window = NSApp?.keyWindow ?? NSApp?.mainWindow,
              let content = window.contentView
        else { return nil }
        // Where the footer would be, in the strip the button lives in.
        let footer = Style.Metrics.footerHeight
        let y = content.isFlipped ? content.bounds.height - footer : 0
        return (content, NSRect(x: 0, y: y, width: 1, height: footer))
    }

    func revealInFinder(_ download: Download) {
        NSWorkspace.shared.activateFileViewerSelecting([download.destination])
    }

    func open(_ download: Download) {
        NSWorkspace.shared.open(download.destination)
    }

    // MARK: - Delegate callbacks

    /// Chooses where a transfer writes, and creates the row for it.
    ///
    /// Returning nil makes WebKit fail the download, which is the correct
    /// outcome when no safe path can be produced: there is no fallback location
    /// a page should be able to push a file into.
    fileprivate func destination(
        for webKitDownload: WKDownload,
        response: URLResponse,
        suggestedFilename: String
    ) -> URL? {
        // A resumed transfer must continue into the partial file it already
        // wrote, so the existing row's destination wins over a fresh name. A
        // row that is starting over instead needs a new one, because the old
        // path may now hold the bytes of the attempt that failed.
        if let existing = row(for: webKitDownload) {
            if existing.isResuming { return existing.destination }
            guard let directory = DownloadDestination.downloadsDirectory(),
                  let resolution = DownloadDestination.resolve(suggested: suggestedFilename, in: directory)
            else { return nil }
            existing.relocate(to: resolution.url)
            changed(existing)
            return resolution.url
        }

        let source = webKitDownload.originalRequest?.url ?? response.url
        guard let source else {
            record(failure: "Could not tell where this file came from", source: response.url, name: suggestedFilename)
            return nil
        }

        let destination: URL
        if Settings.shared.downloadLocation == .ask {
            // "Ask for each download": the save panel's answer is the
            // destination, name and all; a cancelled panel is a cancelled
            // download, which WebKit reports when nil comes back.
            guard let chosen = askWhereToSave(suggestedFilename: suggestedFilename) else { return nil }
            destination = chosen
        } else {
            guard let directory = DownloadDestination.downloadsDirectory() else {
                record(failure: "Could not open the Downloads folder", source: response.url, name: suggestedFilename)
                return nil
            }
            guard let resolution = DownloadDestination.resolve(suggested: suggestedFilename, in: directory) else {
                record(failure: "Could not find a safe name for this file", source: source, name: suggestedFilename)
                return nil
            }
            destination = resolution.url
        }

        let download = Download(
            sourceURL: source,
            destination: destination,
            download: webKitDownload,
            host: webKitDownload.webView
        )
        insert(download)
        return destination
    }

    private func askWhereToSave(suggestedFilename: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = DownloadDestination.sanitized(suggestedFilename)
        panel.canCreateDirectories = true
        panel.directoryURL = DownloadDestination.downloadsDirectory()
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        // The panel's file is created empty by the panel; WebKit needs the
        // path free.
        try? FileManager.default.removeItem(at: url)
        return url
    }

    /// Rows that the removal setting says should go, at launch.
    func pruneCompleted(atLaunch: Bool) {
        let policy = Settings.shared.downloadRemoval
        let before = downloads.count
        downloads.removeAll { $0.state != .running && policy.removes(finishedAt: $0.finishedAt, atLaunch: atLaunch) }
        if downloads.count != before {
            changes.send(.list)
            scheduleSave()
        }
    }

    /// Types that are safe to open unasked: what the file is, not what the
    /// page said it was.
    static func isSafeToOpen(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        // A shell script is text and a disk image is an archive, as far as
        // the type tree is concerned. Anything that runs, mounts or installs
        // is out before the safe kinds are considered.
        let dangerous: [UTType] = [.executable, .script, .diskImage, .bundle, .package, .application]
        if dangerous.contains(where: { type.conforms(to: $0) }) { return false }
        if type.identifier.hasPrefix("com.apple.installer") { return false }
        return [UTType.image, .movie, .audio, .pdf, .text, .archive].contains { type.conforms(to: $0) }
    }

    /// WebKit follows a redirect only if we allow it. Allowing it is what
    /// Safari does and what every CDN-backed download link needs; the response
    /// that finally arrives still goes through `destination` above, so the
    /// filename is re-derived rather than inherited from the first hop.
    fileprivate func allowRedirect(for webKitDownload: WKDownload) -> WKDownload.RedirectPolicy {
        .allow
    }

    fileprivate func didFinish(_ webKitDownload: WKDownload) {
        guard let download = row(for: webKitDownload) else { return }
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: download.destination.path(percentEncoded: false)
        )
        download.finish(byteCount: (attributes?[.size] as? NSNumber)?.int64Value)
        quarantine(download.destination, source: download.sourceURL)
        changed(download)

        let settings = Settings.shared
        if settings.opensSafeFilesAfterDownloading, Self.isSafeToOpen(download.destination) {
            NSWorkspace.shared.open(download.destination)
        }
        if settings.downloadRemoval == .uponSuccess {
            // The file stays; only the row goes.
            downloads.removeAll { $0 === download }
            changes.send(.list)
            scheduleSave()
        }
    }

    fileprivate func didFail(_ webKitDownload: WKDownload, error: any Error, resumeData: Data?) {
        guard let download = row(for: webKitDownload) else { return }
        // A cancel we asked for has already been recorded, with the resume data
        // WebKit gave the cancel call. Do not overwrite it with a failure.
        guard download.state == .running else { return }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            download.markCancelled(resumeData: resumeData)
        } else {
            download.fail(nsError.localizedDescription, resumeData: resumeData)
        }
        changed(download)
    }

    // MARK: - Bookkeeping

    private func row(for webKitDownload: WKDownload) -> Download? {
        downloads.first { $0.webKitDownload === webKitDownload }
    }

    private func insert(_ download: Download) {
        downloads.insert(download, at: 0)
        downloads = Array(downloads.prefix(DownloadStore.limit))
        changes.send(.list)
        scheduleSave()

        // A download that produced no visible response at all is the behaviour
        // this feature replaces, so the list comes forward when one starts.
        // Without taking key focus: the user clicked a link on a page, and
        // moving the keyboard off that page is not what they asked for.
        showList(activating: false)
    }

    /// Puts a download that never started into the list anyway. A link that
    /// silently does nothing is exactly the behaviour this feature replaces.
    private func record(failure message: String, source: URL?, name: String) {
        let directory = DownloadDestination.downloadsDirectory() ?? URL(filePath: NSTemporaryDirectory())
        insert(Download(record: DownloadRecord(
            id: UUID(),
            sourceURL: source ?? URL(string: "about:blank")!,
            destination: directory.appending(path: DownloadDestination.sanitized(name)),
            state: .failed(message),
            startedAt: .now,
            finishedAt: .now,
            byteCount: nil
        )))
    }

    private func changed(_ download: Download) {
        changes.send(.download(download))
        scheduleSave()
    }

    /// Names Kylmora and the originating URL in the file's quarantine record, so
    /// Gatekeeper's prompt can say where the file came from.
    ///
    /// WebKit already applies the bare `com.apple.quarantine` attribute — this
    /// merges into what is there rather than replacing it, which is the pattern
    /// DuckDuckGo's browser uses for the same reason. It is written even when
    /// the attribute is missing, because a downloaded file carrying no
    /// quarantine at all is the one case where Gatekeeper would not ask.
    private func quarantine(_ url: URL, source: URL) {
        let existing = (try? url.resourceValues(forKeys: [.quarantinePropertiesKey]))?.quarantineProperties ?? [:]
        var properties = existing
        properties[kLSQuarantineTypeKey as String] = kLSQuarantineTypeWebDownload
        properties[kLSQuarantineAgentNameKey as String] = "Kylmora"
        properties[kLSQuarantineAgentBundleIdentifierKey as String] = AppPaths.bundleIdentifier
        properties[kLSQuarantineDataURLKey as String] = source.absoluteString

        var values = URLResourceValues()
        values.quarantineProperties = properties
        var target = url
        try? target.setResourceValues(values)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        try? store.save(downloads.map { $0.record() })
    }
}

/// Holds the WebKit conformance off `DownloadManager` itself, so the manager
/// stays a plain Swift class rather than an `NSObject` subclass — the same
/// split `Tab` uses for its navigation delegate.
///
/// One delegate serves every download: `WKDownload.delegate` is weak, so
/// something has to own it, and one object owned by the manager is less
/// bookkeeping than one per transfer.
private final class DownloadDelegate: NSObject, WKDownloadDelegate {
    private weak var manager: DownloadManager?

    init(manager: DownloadManager) {
        self.manager = manager
    }

    @MainActor
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping @MainActor (URL?) -> Void
    ) {
        completionHandler(manager?.destination(
            for: download, response: response, suggestedFilename: suggestedFilename
        ))
    }

    @MainActor
    func download(
        _ download: WKDownload,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        decisionHandler: @escaping @MainActor (WKDownload.RedirectPolicy) -> Void
    ) {
        decisionHandler(manager?.allowRedirect(for: download) ?? .cancel)
    }

    /// Left to the system.
    ///
    /// WebKit rejects the protection space outright when this method is absent,
    /// which fails a download behind HTTP authentication *and* one behind a
    /// server-trust challenge the system would have accepted. Default handling
    /// evaluates the certificate the way the rest of the OS does and consults
    /// the shared credential storage; it does not invent a credential, and it
    /// does not put a login sheet in front of the user on a page's behalf.
    @MainActor
    func download(
        _ download: WKDownload,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        completionHandler(.performDefaultHandling, nil)
    }

    @MainActor
    func downloadDidFinish(_ download: WKDownload) {
        manager?.didFinish(download)
    }

    @MainActor
    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        manager?.didFail(download, error: error, resumeData: resumeData)
    }
}
