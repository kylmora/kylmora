import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    /// The browser deliberately owns a single main window. Spaces and tabs are
    /// switched inside it rather than by spawning new windows.
    private var session: BrowserSession?
    private var syncCoordinator: SyncCoordinator?
    private var mainWindowController: BrowserWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var bookmarksMenu: StoredItemsMenu?
    private var historyMenu: StoredItemsMenu?
    /// The View menu's Tabs, Pinned Sites and Spaces lists.
    private var listMenus: [WindowListMenu] = []
    private var suspender: TabSuspender?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppPaths.ensureSupportDirectory()
        // Before any window exists, so the first one is never drawn in the
        // wrong appearance and then corrected.
        Settings.shared.applyAppearance()

        // History and bookmarks are a convenience, not a prerequisite. If the
        // database cannot be opened, the browser still browses.
        let database = try? BrowserDatabase(path: AppPaths.databaseFile)
        if database == nil {
            NSLog("Kylmora: history and bookmarks are unavailable; could not open \(AppPaths.databaseFile.path())")
        }

        let session = BrowserSession(database: database)
        self.session = session

        let syncCoordinator = SyncCoordinator(session: session, database: database)
        self.syncCoordinator = syncCoordinator
        syncCoordinator.start()

        let bookmarksMenu = StoredItemsMenu(kind: .bookmarks, session: session)
        let historyMenu = StoredItemsMenu(kind: .history, session: session)
        self.bookmarksMenu = bookmarksMenu
        self.historyMenu = historyMenu
        let listMenus = [WindowListMenu.Kind.tabs, .pinnedSites, .spaces].map {
            WindowListMenu(kind: $0, session: session)
        }
        self.listMenus = listMenus
        NSApp.mainMenu = MainMenu.build(
            bookmarks: bookmarksMenu,
            history: historyMenu,
            tabs: listMenus[0],
            pinnedSites: listMenus[1],
            spaces: listMenus[2]
        )

        let controller = BrowserWindowController(session: session)
        mainWindowController = controller
        controller.showWindow(nil)

        let suspender = TabSuspender(session: session)
        suspender.start()
        self.suspender = suspender

        // Live folders poll on their own timers from here on. Started after
        // the window exists, so the first results land in a sidebar that can
        // show them.
        Task { await session.liveFolders.start() }
        // Filter lists: cached compilations come back at once, anything
        // missing is fetched and applied to open pages as it arrives.
        ContentBlocker.shared.start()
        SiteSettings.shared.addChangeObserver { ContentBlocker.shared.siteSettingsChanged() }
        // The Privacy pane's schedules, honoured at launch: a crash
        // report from last time, cookies that were due to go, history past
        // its retention.
        CrashReporter.reviewPendingReport(policy: Settings.shared.crashReportPolicy)
        CrashReporter.install()
        session.deleteCookiesIfDue()
        session.pruneHistory()
        DownloadManager.shared.pruneCompleted(atLaunch: true)
        // Picture-in-picture reports come from the page and need the tab
        // that owns the web view.
        SitePolicy.shared.tabResolver = { [weak session] webView in
            session?.allTabs.first { $0.currentWebView === webView }
        }
        installEscapeGuard(session: session)
        // Extensions need the window to exist: the engine asks for it first.
        if #available(macOS 15.4, *) {
            ExtensionManager.shared.start(session: session, window: controller)
        }

        // Web Applications (SSBs)
        WebAppManager.shared.session = session
        WebAppManager.shared.onOpenInBrowser = { [weak self] url in
            self?.mainWindowController?.showWindow(nil)
            self?.session?.newTab(url: url)
        }
        _ = WebAppManager.shared.handleCommandLineArguments(CommandLine.arguments)

        NSApp.activate(ignoringOtherApps: true)
        Metrics.reportLaunchIfRequested(stage: "window-shown")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// "Show warning before quitting": a quit with pages open asks first.
    /// One tab on a start page is nothing to lose, so it does not.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard Settings.shared.warnsBeforeQuitting, let session else { return .terminateNow }
        let open = session.allTabs.count
        guard open > 1 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit Kylmora?"
        alert.informativeText = "\(open) tabs are open. They come back next time if restoring is on."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    /// The debounced save would be lost on quit, so write synchronously here.
    func applicationWillTerminate(_ notification: Notification) {
        CrashReporter.markCleanExit()
        session?.saveNow()
    }

    /// Also save when the browser goes to the background, which covers a crash
    /// or a force quit that never reaches `applicationWillTerminate`.
    func applicationDidResignActive(_ notification: Notification) {
        session?.saveNow()
    }

    /// Menu items carry the preference they select, so one action serves all
    /// three and adding a fourth would need no new method.
    @objc func setAppearance(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let preference = AppearancePreference.fromMenuTag(item.tag) else { return }
        Settings.shared.appearance = preference
        Settings.shared.applyAppearance()
    }

    @objc func showDownloads(_ sender: Any?) {
        DownloadManager.shared.showList()
    }

    @objc func showSettings(_ sender: Any?) {
        settingsWindow()?.showWindow(sender, on: .general)
    }

    func showSettings(_ sender: Any?, on pane: SettingsWindowController.Pane) {
        settingsWindow()?.showWindow(sender, on: pane)
    }

    /// File > Import From Browser: opens Settings on the Import pane, so the
    /// switch-from-Safari/Chrome flow is one menu away, not buried in a pane.
    @objc func importFromBrowser(_ sender: Any?) {
        showSettings(sender, on: .importData)
    }

    /// Opens Settings directly to the Sync preference pane.
    @objc func showSyncSettings(_ sender: Any?) {
        showSettings(sender, on: .sync)
    }

    /// Opens Settings on the Spaces pane, with the space the window is showing
    /// already loaded in the editor. Reached from the space menu in the
    /// sidebar.
    /// The About pane, in place of the system's bare panel: it has the
    /// logo and version too, and the update check besides.
    @objc func showAbout(_ sender: Any?) {
        showSettings(sender, on: .about)
    }

    @objc func showSpaceSettings(_ sender: Any?) {
        guard let controller = settingsWindow() else { return }
        if let space = session?.activeSpace {
            controller.showSpace(space, sender: sender)
        } else {
            controller.showWindow(sender, on: .spaces)
        }
    }

    /// The Settings window needs the session for the Spaces pane, so it
    /// cannot be built before `applicationDidFinishLaunching`.
    private func settingsWindow() -> SettingsWindowController? {
        if let settingsWindowController { return settingsWindowController }
        guard let session else { return nil }
        let controller = SettingsWindowController(session: session, syncCoordinator: syncCoordinator)
        controller.currentPageURL = { [weak session] in session?.activeTab?.url }
        settingsWindowController = controller
        return controller
    }

    // MARK: - Sync & Backup Actions

    @objc func syncNow(_ sender: Any?) {
        guard let syncCoordinator else { return }
        Task {
            try? await syncCoordinator.syncNow()
        }
    }

    @objc func exportBackup(_ sender: Any?) {
        guard let window = mainWindowController?.window else { return }
        let panel = NSSavePanel()
        panel.title = "Export Kylmora Backup"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        panel.nameFieldStringValue = "Kylmora-Backup-\(formatter.string(from: .now)).json"
        panel.allowedContentTypes = [.json]

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let syncCoordinator = self?.syncCoordinator else { return }
            Task { @MainActor in
                try? await syncCoordinator.exportBackup(to: url)
            }
        }
    }

    @objc func importBackup(_ sender: Any?) {
        guard let window = mainWindowController?.window else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Kylmora Backup"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let syncCoordinator = self?.syncCoordinator else { return }
            let alert = NSAlert()
            alert.messageText = "Import Backup"
            alert.informativeText = "Do you want to merge this backup with your existing spaces and tabs, or replace everything?"
            alert.addButton(withTitle: "Merge")
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")

            alert.beginSheetModal(for: window) { button in
                let mode: SyncMergePolicy.MergeMode
                switch button {
                case .alertFirstButtonReturn: mode = .merge
                case .alertSecondButtonReturn: mode = .replace
                default: return
                }
                Task { @MainActor in
                    try? await syncCoordinator.importBackup(from: url, mode: mode)
                }
            }
        }
    }

    @objc func importArcSidebar(_ sender: Any?) {
        guard let window = mainWindowController?.window else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Arc Sidebar (StorableSidebar.json)"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        let defaultArcDir = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Arc", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: defaultArcDir.path(percentEncoded: false)) {
            panel.directoryURL = defaultArcDir
        }

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let syncCoordinator = self?.syncCoordinator else { return }
            Task { @MainActor in
                try? await syncCoordinator.importArcSidebar(from: url)
            }
        }
    }

    /// Links opened from other applications, and from `open -a Kylmora <url>`.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let session else { return }
        for url in urls {
            if WebAppManager.shared.handleURLScheme(url) {
                continue
            }
            if let controller = mainWindowController {
                controller.openExternal(url)
            } else {
                NSApp.activate(ignoringOtherApps: true)
                session.newTab(url: url, origin: .external)
            }
        }
    }

    /// "Prevent ESC from exiting full screen": the key is swallowed while a
    /// page is in element full screen, and only then.
    private var escapeMonitor: Any?

    private func installEscapeGuard(session: BrowserSession) {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak session] event in
            // A `Bool` crosses the isolation check; the event itself stays put.
            let swallow = MainActor.assumeIsolated { () -> Bool in
                guard event.keyCode == 53, Settings.shared.preventsEscapeExitingFullScreen,
                      let webView = session?.activeTab?.currentWebView else { return false }
                if #available(macOS 13.0, *) { return webView.fullscreenState == .inFullscreen }
                return false
            }
            return swallow ? nil : event
        }
    }

    /// Re-open the single main window when the user clicks the Dock icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            mainWindowController?.showWindow(nil)
        }
        return true
    }

    /// The tick beside the selected appearance. `NSMenuItemValidation` reaches
    /// the delegate because the menu items have no explicit target and the
    /// delegate is in the responder chain.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(setAppearance(_:)),
              let preference = AppearancePreference.fromMenuTag(menuItem.tag) else {
            return true
        }
        menuItem.state = Settings.shared.appearance == preference ? .on : .off
        return true
    }
}
