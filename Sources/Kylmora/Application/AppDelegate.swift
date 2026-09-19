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

    func applicationWillFinishLaunching(_ notification: Notification) {
        Metrics.reportLaunchIfRequested(stage: "app-code-begins")
    }

    /// Closes the system colour panel if macOS restored it.
    ///
    /// Kylmora picks colours in its own card now, but a copy of Kylmora that
    /// once opened `NSColorPanel` has it in its saved window state, and AppKit
    /// puts it back on screen at every launch afterwards -- a floating system
    /// window nothing in the app opened and nothing in the app closes.
    ///
    /// Restoration runs after this delegate is told the app launched, so the
    /// sweep is repeated: now, on the next pass of the run loop, and a second
    /// later. It only ever closes a panel that already exists, so an app that
    /// never had one does nothing at all.
    private func dismissRestoredColorPanel() {
        closeColorPanelIfRestored()
        DispatchQueue.main.async { [weak self] in self?.closeColorPanelIfRestored() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.closeColorPanelIfRestored()
        }
    }

    private func closeColorPanelIfRestored() {
        guard NSColorPanel.sharedColorPanelExists else { return }
        let panel = NSColorPanel.shared
        panel.isRestorable = false
        panel.close()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Metrics.reportLaunchIfRequested(stage: "did-finish-launching")
        AppPaths.ensureSupportDirectory()
        // Before any window exists, so the first one is never drawn in the
        // wrong appearance and then corrected.
        Settings.shared.applyAppearance()
        dismissRestoredColorPanel()

        // History and bookmarks are a convenience, not a prerequisite. If the
        // database cannot be opened, the browser still browses.
        let database = try? BrowserDatabase(path: AppPaths.databaseFile)
        if database == nil {
            NSLog("Kylmora: history and bookmarks are unavailable; could not open \(AppPaths.databaseFile.path())")
        }

        Metrics.reportLaunchIfRequested(stage: "database-open")
        let session = BrowserSession(database: database)
        self.session = session
        Metrics.reportLaunchIfRequested(stage: "session-restored")

        let syncCoordinator = SyncCoordinator(session: session, database: database)
        self.syncCoordinator = syncCoordinator

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

        Metrics.reportLaunchIfRequested(stage: "menus-built")
        let controller = BrowserWindowController(session: session)
        Metrics.reportLaunchIfRequested(stage: "window-built")
        mainWindowController = controller
        controller.showWindow(nil)
        Metrics.reportLaunchIfRequested(stage: "window-ordered")

        let suspender = TabSuspender(session: session)
        self.suspender = suspender
        // Filter lists: cached compilations come back at once, anything
        // missing is fetched and applied to open pages as it arrives.
        ContentBlocker.shared.start()
        SiteSettings.shared.addChangeObserver { ContentBlocker.shared.siteSettingsChanged() }
        NetworkConfigManager.shared.start()
        RAMCacheManager.shared.applyCacheConfiguration()
        // The Privacy pane's schedules, honoured at launch: a crash
        // report from last time, cookies that were due to go, history past
        // its retention.
        CrashReporter.install()
        // Picture-in-picture reports come from the page and need the tab
        // that owns the web view.
        SitePolicy.shared.tabResolver = { [weak session] webView in
            session?.allTabs.first { $0.currentWebView === webView }
        }
        // Web notifications: the system centre hands back an identifier and
        // nothing else, so Kylmora has to be able to find the tab again and
        // let the page's own handler run. Starting the centre also takes over
        // the system delegate, without which a notification posted while
        // Kylmora is frontmost is never shown at all.
        WebNotificationCentre.shared.start()
        WebNotificationCentre.shared.focusTab = { [weak session] tabID in
            session?.revealTab(id: tabID)
        }
        WebNotificationCentre.shared.dispatchEvent = { [weak session] record, type in
            guard let tabID = record.tabID,
                  let tab = session?.allTabs.first(where: { $0.id == tabID }),
                  let webView = tab.currentWebView else { return }
            let id = WebNotificationCentre.javaScriptString(record.id)
            let event = WebNotificationCentre.javaScriptString(type)
            webView.evaluateJavaScript(
                "window.__kylmoraNotificationEvent && window.__kylmoraNotificationEvent(\(id), \(event))"
            ) { _, _ in }
        }
        DownloadManager.shared.spaceResolver = { [weak session] download in
            guard let session else { return nil }
            if let webView = download.webView,
               let tab = session.allTabs.first(where: { $0.currentWebView === webView }) {
                return session.spaces.first(where: { $0.tabs.contains(where: { $0 === tab }) })
            }
            return session.activeSpace
        }
        installEscapeGuard(session: session)
        // Extensions need the window to exist: the engine asks for it first.
        if #available(macOS 15.4, *) {
            ExtensionManager.shared.start(session: session, window: controller)
        }
        BrowserLockManager.shared.start()

        NotificationCenter.default.addObserver(
            forName: .developMenuSettingDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rebuildMainMenu()
            }
        }

        // Web Applications (SSBs)
        WebAppManager.shared.session = session
        WebAppManager.shared.onOpenInBrowser = { [weak self] url in
            self?.mainWindowController?.showWindow(nil)
            self?.session?.newTab(url: url)
        }
        _ = WebAppManager.shared.handleCommandLineArguments(CommandLine.arguments)

        NSApplication.shared.activate(ignoringOtherApps: true)
        Metrics.reportLaunchIfRequested(stage: "window-shown")

        // Everything the first frame does not need waits for it: timers,
        // sync, live folders, housekeeping and the update check start once
        // the window has had a moment to draw.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.finishLaunching(session: session, controller: controller, syncCoordinator: syncCoordinator, suspender: suspender)
        }
    }

    func rebuildMainMenu() {
        guard let bookmarksMenu, let historyMenu, listMenus.count >= 3 else { return }
        NSApp.mainMenu = MainMenu.build(
            bookmarks: bookmarksMenu,
            history: historyMenu,
            tabs: listMenus[0],
            pinnedSites: listMenus[1],
            spaces: listMenus[2]
        )
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// "Show warning before quitting": a quit with pages open asks first.
    ///
    /// One tab on a start page is nothing to lose, so it does not. A Little Arc
    /// window does not come back, so it is named too -- the warning would be a
    /// lie if it counted only tabs while quietly dropping a page the user had
    /// open.
    private var isPerformingQuitCleanup = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isPerformingQuitCleanup { return .terminateLater }

        if Settings.shared.warnsBeforeQuitting,
           let session,
           let message = QuitWarning.message(
               tabs: session.allTabs.count,
               littleArcs: mainWindowController?.openLittleArcCount ?? 0
           ) {
            let alert = NSAlert()
            alert.messageText = "Quit Kylmora?"
            alert.informativeText = message
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }

        if Settings.shared.clearWebsiteDataOnQuit {
            isPerformingQuitCleanup = true
            let identities = session?.storedIdentities ?? [.standard]
            let allowlist = Settings.shared.websiteDataQuitAllowlist
            Task {
                await WebsiteData.clearDataOnQuit(allowlist: allowlist, for: identities)
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }

        return .terminateNow
    }

    /// The debounced save would be lost on quit, so write synchronously here.
    func applicationWillTerminate(_ notification: Notification) {
        CrashReporter.markCleanExit()
        session?.saveNow()
        // A native messaging host is a program Kylmora started; quitting the
        // browser has to stop it too, or a password manager's helper outlives
        // the browser that asked for it.
        if #available(macOS 15.4, *) {
            NativeMessagingService.shared.disconnectAll()
        }
        if Settings.shared.clearDiskCacheOnQuit || RAMCacheManager.shared.isRAMOnly {
            RAMCacheManager.shared.clearDiskCacheDirectory()
        }
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

    // MARK: - Help > getting in touch
    //
    // Kylmora has no telemetry and no crash service. Everything we learn about
    // a bug, someone chose to tell us, so the route has to be short and it has
    // to be in the menu people already open when they are stuck.

    /// Help > Report a Problem: the sheet, which sends straight to kylmora.com
    /// with the version, the system and the kind of Mac shown before it goes.
    /// No mail client required; the sheet offers mail as a second button for
    /// anyone who wants the message in their own Sent folder.
    @objc func reportAProblem(_ sender: Any?) {
        showFeedback(kind: .bug)
    }

    /// Help > Suggest a Feature: the same sheet, asking what they want instead
    /// of what went wrong.
    @objc func suggestAFeature(_ sender: Any?) {
        showFeedback(kind: .feature)
    }

    /// Help > Contact Support: an open question, for everything that is
    /// neither a bug nor an idea.
    @objc func contactSupport(_ sender: Any?) {
        showFeedback(kind: .question)
    }

    /// Held for as long as it is on screen; a window controller with no owner
    /// is released out from under its own window.
    private var feedbackWindow: FeedbackWindowController?

    func showFeedback(kind: FeedbackSubmission.Kind) {
        // One at a time. A second Report a Problem should bring the half-typed
        // first one forward, not open an empty sheet over the top of it.
        if let existing = feedbackWindow {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = FeedbackWindowController(kind: kind)
        feedbackWindow = controller
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: controller.window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.feedbackWindow = nil }
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openIssues(_ sender: Any?) {
        NSWorkspace.shared.open(SupportContact.issues)
    }

    /// A vulnerability goes to GitHub's private advisory form, which is the
    /// route SECURITY.md asks for; the address is on that page too.
    @objc func reportSecurityIssue(_ sender: Any?) {
        NSWorkspace.shared.open(SupportContact.securityAdvisory)
    }

    @objc func openWebsite(_ sender: Any?) {
        NSWorkspace.shared.open(AppInfo.website)
    }

    /// Invokes the Sparkle-style updater flow.
    @objc func checkForUpdates(_ sender: Any?) {
        UpdateController.shared.checkForUpdates(userInitiated: true, in: mainWindowController?.window)
    }

    /// Displays the Enterprise Policies sheet.
    @objc func showEnterprisePolicies(_ sender: Any?) {
        if let window = mainWindowController?.window {
            let controller = EnterprisePoliciesViewController()
            let sheetWindow = NSWindow(contentViewController: controller)
            sheetWindow.styleMask = [.titled, .closable]
            sheetWindow.title = "Enterprise Policies"
            window.beginSheet(sheetWindow) { _ in }
        } else {
            let controller = EnterprisePoliciesViewController()
            let sheetWindow = NSWindow(contentViewController: controller)
            sheetWindow.styleMask = [.titled, .closable]
            sheetWindow.title = "Enterprise Policies"
            sheetWindow.center()
            sheetWindow.makeKeyAndOrderFront(sender)
        }
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
    ///
    /// Where each lands is the window controller's decision: a tab or a glance
    /// in the browser window, or a Little Arc window -- so whether the browser
    /// window comes forward is decided there too, since a Little Arc appears
    /// where the user already is and must not raise the browser behind it.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let session else { return }
        for url in urls {
            if WebAppManager.shared.handleURLScheme(url) {
                continue
            }
            if let command = CommandURL(url: url) {
                command.perform(in: session, window: mainWindowController)
                continue
            }
            if let link = IPhoneLink.parse(urlScheme: url) {
                IPhoneLinkReceiver.shared.receive(link: link, session: session, windowController: mainWindowController)
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

    /// The second half of launch, after the first window is on screen.
    private func finishLaunching(
        session: BrowserSession,
        controller: BrowserWindowController,
        syncCoordinator: SyncCoordinator,
        suspender: TabSuspender
    ) {
        Metrics.reportLaunchIfRequested(stage: "deferred-begins")
        syncCoordinator.start()
        Metrics.reportLaunchIfRequested(stage: "sync-started")
        suspender.start()
        // Rules act on tabs from here on: page loads, idle tabs, media,
        // downloads.
        AutomationService.shared.start(session: session)
        // Chords and custom-command keys, which the menus cannot carry.
        ShortcutDispatcher.shared.install()
        Metrics.reportLaunchIfRequested(stage: "rules-started")
        // Live folders poll on their own timers from here on. Started after
        // the window exists, so the first results land in a sidebar that can
        // show them.
        Task { await session.liveFolders.start() }
        // The Privacy pane's schedules, honoured at launch: a crash report
        // from last time, cookies that were due to go, history past its
        // retention, finished downloads past theirs.
        CrashReporter.reviewPendingReport(policy: Settings.shared.crashReportPolicy)
        session.deleteCookiesIfDue()
        session.pruneHistory()
        DownloadManager.shared.pruneCompleted(atLaunch: true)
        Metrics.reportLaunchIfRequested(stage: "housekeeping-done")
        UpdateController.shared.startBackgroundChecking()
        TabResourceMonitor.shared.startBackgroundMonitoring(session: session)
        Metrics.reportLaunchIfRequested(stage: "monitors-started")
        ICloudInboxCoordinator.shared.start(session: session, windowController: controller)
        // After an update, once: what version this is and where its notes are.
        WhatsNew.presentIfNeeded(on: controller.window)
        Metrics.reportLaunchIfRequested(stage: "launch-complete")
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

    @objc func lockBrowser(_ sender: Any?) {
        BrowserLockManager.shared.lock(animated: true)
    }

    /// The tick beside the selected appearance. `NSMenuItemValidation` reaches
    /// the delegate because the menu items have no explicit target and the
    /// delegate is in the responder chain.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(lockBrowser(_:)) {
            return !BrowserLockManager.shared.isLocked
        }
        guard menuItem.action == #selector(setAppearance(_:)),
              let preference = AppearancePreference.fromMenuTag(menuItem.tag) else {
            return true
        }
        menuItem.state = Settings.shared.appearance == preference ? .on : .off
        return true
    }
}
