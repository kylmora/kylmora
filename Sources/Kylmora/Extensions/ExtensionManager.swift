import AppKit
import Combine
import WebKit

/// Hosts WebKit's extension engine and the extensions the user installed.
///
/// `WKWebExtensionController` is Safari's extension runtime made public. It
/// reads the manifest format that Chrome extensions use, runs their
/// background and content scripts, and asks the application only for what an
/// engine cannot know: which windows and tabs exist, and where to show a
/// popup. That is what this class answers. Kylmora's part is small on purpose,
/// which is also what makes it trustworthy: nothing here interprets an
/// extension's code.
///
/// One controller for the app, persistent, so extension storage survives a
/// relaunch. Every web view is made with it (`WebEnvironment`), so content
/// scripts reach every page in every space -- except private ones, which the
/// engine keeps extensions out of.
@available(macOS 15.4, *)
@MainActor
final class ExtensionManager: NSObject {
    static let shared = ExtensionManager()

    /// Fixed, so the same storage comes back every launch.
    private static let controllerIdentifier = UUID(uuidString: "6D1F0A62-5C4B-4A8B-9D53-2B7E0F1C9A11")!

    /// One extension's state, for the pane.
    struct Entry: Identifiable {
        let record: InstalledExtension
        let displayName: String
        let displayVersion: String
        let summary: String
        let icon: NSImage?
        /// Load errors, WebKit's words.
        let problems: [String]
        var id: UUID { record.id }
    }

    let controller: WKWebExtensionController
    private(set) var records: [InstalledExtension] = []
    private var extensions: [UUID: WKWebExtension] = [:]
    private var contexts: [UUID: WKWebExtensionContext] = [:]
    private var problems: [UUID: [String]] = [:]
    private let index: ExtensionIndex

    private(set) weak var session: BrowserSession?
    private(set) var windowAdapter: ExtensionWindowAdapter?
    /// Where an action's popup is anchored: the Extensions button.
    var popupAnchor: (() -> NSView?)?
    /// The list or an action changed; the pane and the button redraw.
    var onChange: (() -> Void)?

    private var adapters: [Tab.ID: ExtensionTabAdapter] = [:]
    private var knownTabs: [Tab.ID] = []
    private var activeTabID: Tab.ID?
    private var cancellables: Set<AnyCancellable> = []

    /// `KYLMORA_EXTENSION_LOG=1` prints what the engine was told and what it
    /// answered, because a content script that does not run leaves no trace.
    static let isLogging = ProcessInfo.processInfo.environment["KYLMORA_EXTENSION_LOG"] == "1"

    init(index: ExtensionIndex = ExtensionIndex(),
         controllerConfiguration: WKWebExtensionController.Configuration = .init(identifier: ExtensionManager.controllerIdentifier)) {
        self.index = index
        controller = WKWebExtensionController(configuration: controllerConfiguration)
        super.init()
        controller.delegate = self
        records = index.load()
    }

    // MARK: - Lifecycle

    /// Attaches to the session and the window, then loads what is enabled.
    func start(session: BrowserSession, window: BrowserWindowController) {
        self.session = session
        windowAdapter = ExtensionWindowAdapter(windowController: window, manager: self)
        knownTabs = visibleTabs.map(\.id)
        activeTabID = session.activeTab?.id
        session.changes
            .sink { [weak self] change in self?.sessionChanged(change) }
            .store(in: &cancellables)
        controller.didOpenWindow(windowAdapter!)
        controller.didFocusWindow(windowAdapter)
        ExtensionSidebarService.shared.presents = { [weak self] id in
            guard let self, let context = self.contexts[id] else { return nil }
            let entry = self.entries.first { $0.id == id }
            return ExtensionSidebarService.Presentation(
                context: context,
                title: entry?.displayName ?? "Extension",
                icon: entry?.icon
            )
        }
        ExtensionSidebarStore.shared.onChange = { id in
            ExtensionSidebarService.shared.stateChanged(for: id)
        }
        for record in records where record.isEnabled {
            Task { await load(record) }
        }
    }

    /// Everything in the list, loaded or not.
    var entries: [Entry] {
        records.map { record in
            let ext = extensions[record.id]
            return Entry(
                record: record,
                displayName: ext?.displayName ?? record.name,
                displayVersion: ext?.displayVersion ?? record.version,
                summary: ext?.displayDescription ?? "",
                icon: ext?.icon(for: CGSize(width: 32, height: 32)),
                problems: problems[record.id] ?? []
            )
        }
    }

    // MARK: - Installing

    /// Unpacks the package into Kylmora's folder, records it, and loads it.
    @discardableResult
    func install(from source: URL, storeID: String? = nil, firefoxSlug: String? = nil) async throws -> InstalledExtension {
        let id = UUID()
        let root = index.root
        let folder = try await Task.detached(priority: .userInitiated) {
            try ExtensionPackage.install(from: source, id: id, under: root)
        }.value
        // Before the engine ever sees it: an extension with a side panel needs
        // an API this engine does not have, and the only place to put one is
        // inside the package.
        try? ExtensionSidebarPackage.prepare(folder: folder)
        let summary = ExtensionPackage.manifestSummary(in: folder)
        let record = InstalledExtension(
            id: id,
            name: summary?.name ?? "Extension",
            version: summary?.version ?? "",
            isEnabled: true,
            installedAt: .now,
            storeID: storeID,
            firefoxSlug: firefoxSlug
        )
        records.append(record)
        try index.save(records)
        await load(record)
        return record
    }

    /// Downloads from the Chrome Web Store and installs. An extension already
    /// installed from the same store ID is replaced, which is also how it is
    /// updated.
    @discardableResult
    func install(fromChromeWebStore input: String) async throws -> InstalledExtension {
        guard let storeID = ChromeWebStore.extensionID(from: input) else { throw ChromeWebStore.Failure.notAStoreLink }
        let package = try await ChromeWebStore.download(storeID)
        defer { try? FileManager.default.removeItem(at: package) }
        if let previous = records.first(where: { $0.storeID == storeID }) {
            remove(previous.id)
        }
        return try await install(from: package, storeID: storeID)
    }

    /// Downloads from addons.mozilla.org and installs, replacing an earlier
    /// install of the same add-on.
    @discardableResult
    func install(fromFirefoxAddons input: String) async throws -> InstalledExtension {
        guard let slug = FirefoxAddons.slug(from: input) else { throw FirefoxAddons.Failure.notAnAddonLink }
        let package = try await FirefoxAddons.download(slug)
        defer { try? FileManager.default.removeItem(at: package) }
        if let previous = records.first(where: { $0.firefoxSlug == slug }) {
            remove(previous.id)
        }
        return try await install(from: package, firefoxSlug: slug)
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        guard let position = records.firstIndex(where: { $0.id == id }) else { return }
        records[position].isEnabled = enabled
        try? index.save(records)
        if enabled {
            Task { await load(records[position]) }
        } else {
            unload(id)
            onChange?()
        }
    }

    /// Unloads, forgets, and deletes the files. The engine's own storage for
    /// the extension goes with it.
    func remove(_ id: UUID) {
        unload(id)
        if let record = records.first(where: { $0.id == id }) {
            try? FileManager.default.removeItem(at: index.folder(for: record))
        }
        records.removeAll { $0.id == id }
        try? index.save(records)
        problems[id] = nil
        onChange?()
    }

    private func load(_ record: InstalledExtension) async {
        guard contexts[record.id] == nil else { return }
        let folder = index.folder(for: record)
        // Every load, not only the first: this brings an extension installed
        // before Kylmora could do side panels up to the shim it ships now.
        let sidebar = try? ExtensionSidebarPackage.prepare(folder: folder)
        do {
            let ext = try await WKWebExtension(resourceBaseURL: folder)
            let context = WKWebExtensionContext(for: ext)
            // Stable across launches: the engine keys its storage on it.
            context.uniqueIdentifier = record.id.uuidString
            context.hasAccessToPrivateData = false
            // Everything the manifest asks for, granted at install. That is
            // Chrome's contract for a package the user chose to install, and
            // an extension asked to prompt for each site is one that never
            // works on a page the user is not looking at.
            for permission in ext.requestedPermissions {
                context.setPermissionStatus(.grantedExplicitly, for: permission)
            }
            // Host permissions and the content scripts' own match patterns
            // both: a content script only runs where the context has access.
            for pattern in ext.allRequestedMatchPatterns {
                context.setPermissionStatus(.grantedExplicitly, for: pattern)
            }
            try controller.load(context)
            extensions[record.id] = ext
            contexts[record.id] = context
            ExtensionSidebarStore.shared.adopt(sidebar?.definition, for: record.id)
            problems[record.id] = (ext.errors + context.errors).map(\.localizedDescription)
            if Self.isLogging {
                let probe = URL(string: "https://duckduckgo.com/")!
                NSLog("kylmora.extension: loaded %@ isLoaded=%d access=%d injected=%d patterns=%@ errors=%@",
                      record.name, context.isLoaded ? 1 : 0,
                      context.hasAccess(to: probe) ? 1 : 0, context.hasInjectedContent(for: probe) ? 1 : 0,
                      ext.allRequestedMatchPatterns.map(\.string).joined(separator: ","),
                      (ext.errors + context.errors).map(\.localizedDescription).joined(separator: " | "))
            }
            // The manifest's name may be a localisation key; the engine has
            // resolved it now.
            if let position = records.firstIndex(where: { $0.id == record.id }),
               let name = ext.displayName, records[position].name != name {
                records[position].name = name
                records[position].version = ext.displayVersion ?? ext.version ?? record.version
                try? index.save(records)
            }
        } catch {
            problems[record.id] = [error.localizedDescription]
        }
        onChange?()
    }

    private func unload(_ id: UUID) {
        ExtensionSidebarService.shared.forget(id)
        if let context = contexts[id] {
            try? controller.unload(context)
        }
        contexts[id] = nil
        extensions[id] = nil
    }

    // MARK: - Actions

    /// The loaded extensions that put a button somewhere, with the action
    /// Checks whether an extension is enabled in a specific space.
    func isExtensionEnabled(_ recordID: UUID, in space: Space?) -> Bool {
        guard let record = records.first(where: { $0.id == recordID }), record.isEnabled else {
            return false
        }
        guard let space, let allowed = space.enabledExtensionIDs else {
            return true
        }
        return allowed.contains(recordID)
    }

    /// for the visible tab.
    var actions: [(entry: Entry, action: WKWebExtension.Action)] {
        let activeSpace = session?.activeSpace
        return entries.compactMap { entry in
            guard isExtensionEnabled(entry.id, in: activeSpace) else { return nil }
            guard let context = contexts[entry.id] else { return nil }
            let tab = session?.activeTab.map { adapter(for: $0) }
            guard let action = context.action(for: tab) else { return nil }
            return (entry, action)
        }
    }

    func perform(_ action: WKWebExtension.Action) {
        guard let context = action.webExtensionContext else { return }
        // `sidePanel.setPanelBehavior({ openPanelOnActionClick: true })` is how
        // an extension says its button opens the panel rather than a popup,
        // and an extension with a panel and no popup means the same thing.
        if let id = recordID(for: context),
           ExtensionSidebarService.shared.hasPanel(id),
           ExtensionSidebarService.shared.opensOnActionClick(id) || !action.presentsPopup {
            ExtensionSidebarService.shared.toggle(id)
            return
        }
        let tab = session?.activeTab.map { adapter(for: $0) }
        context.performAction(for: tab)
    }

    /// The record a loaded context belongs to.
    func recordID(for context: WKWebExtensionContext) -> UUID? {
        guard let id = UUID(uuidString: context.uniqueIdentifier) else { return nil }
        return records.contains(where: { $0.id == id }) ? id : nil
    }

    // MARK: - Tabs, as the engine sees them

    /// Every tab in every space that is not private, in sidebar order.
    var visibleTabs: [Tab] {
        session?.spaces.filter { !$0.isPrivate }.flatMap(\.tabs) ?? []
    }

    func adapter(for tab: Tab) -> ExtensionTabAdapter {
        if let existing = adapters[tab.id], existing.tab === tab { return existing }
        let adapter = ExtensionTabAdapter(tab: tab, manager: self)
        adapters[tab.id] = adapter
        return adapter
    }

    private func sessionChanged(_ change: BrowserSession.Change) {
        switch change {
        case .tabs, .spaces, .structure:
            reconcileTabs()
        case .activeTab:
            let previous = activeTabID.flatMap { adapters[$0] }
            activeTabID = session?.activeTab?.id
            if let tab = session?.activeTab, visibleTabs.contains(where: { $0 === tab }) {
                controller.didActivateTab(adapter(for: tab), previousActiveTab: previous)
            }
            // A panel's page can be set per tab, so the tab changing may mean
            // a different page, or none.
            ExtensionSidebarService.shared.activeTabChanged()
        case .tab(let tab):
            if let adapter = adapters[tab.id] {
                controller.didChangeTabProperties([.title, .URL, .loading], for: adapter)
            }
        case .bookmarks:
            break
        }
    }

    private func reconcileTabs() {
        let current = visibleTabs
        let currentIDs = current.map(\.id)
        let known = Set(knownTabs)
        for tab in current where !known.contains(tab.id) {
            controller.didOpenTab(adapter(for: tab))
        }
        let stillHere = Set(currentIDs)
        for id in knownTabs where !stillHere.contains(id) {
            if let adapter = adapters[id] {
                controller.didCloseTab(adapter, windowIsClosing: false)
            }
            adapters[id] = nil
        }
        knownTabs = currentIDs
    }
}

// MARK: - What the engine asks for

@available(macOS 15.4, *)
extension ExtensionManager: WKWebExtensionControllerDelegate {
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        windowAdapter.map { [$0] } ?? []
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        windowAdapter
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, Error?) -> Void
    ) {
        guard let session else { return completionHandler(nil, nil) }
        let tab = session.newTab(url: configuration.url, select: configuration.shouldBeActive)
        completionHandler(adapter(for: tab), nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openOptionsPageFor extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let url = extensionContext.optionsPageURL else { return completionHandler(nil) }
        session?.newTab(url: url)
        completionHandler(nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        completionHandler(permissions, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        completionHandler(urls, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        completionHandler(matchPatterns, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action, forExtensionContext context: WKWebExtensionContext) {
        onChange?()
    }

    /// `runtime.sendNativeMessage`: one message to a program on the Mac, one
    /// reply back. The engine asks; every decision about whether that may
    /// happen belongs to `NativeMessagingService`.
    func webExtensionController(
        _ controller: WKWebExtensionController,
        sendMessage message: Any,
        toApplicationWithIdentifier applicationIdentifier: String?,
        for context: WKWebExtensionContext,
        replyHandler: @escaping (Any?, Error?) -> Void
    ) {
        if ExtensionSidebarService.isBrokerHost(applicationIdentifier) {
            guard let id = recordID(for: context), let body = message as? [String: Any] else {
                return replyHandler(nil, NativeMessagingService.error(NativeMessagingService.Denial.noSuchHost(ExtensionSidebarShim.brokerHostName)))
            }
            let method = body["method"] as? String ?? ""
            let arguments = (body["args"] as? [String: Any]) ?? [:]
            switch ExtensionSidebarService.shared.broker.perform(method, arguments: arguments, for: id) {
            case .done:
                return replyHandler(["ok": true], nil)
            case .value(let values):
                return replyHandler(["ok": true, "value": values.mapValues(\.json)], nil)
            case .failure(let reason):
                return replyHandler(["ok": false, "error": reason], nil)
            }
        }
        guard let identity = nativeMessagingIdentity(for: context) else {
            return replyHandler(nil, NativeMessagingService.error(NativeMessagingService.Denial.noSuchHost(applicationIdentifier ?? "")))
        }
        let permitted = context.hasPermission(.nativeMessaging)
        Task { @MainActor in
            do {
                let reply = try await NativeMessagingService.shared.send(
                    message,
                    toHostNamed: applicationIdentifier,
                    from: identity,
                    hasPermission: permitted
                )
                replyHandler(reply, nil)
            } catch {
                replyHandler(nil, NativeMessagingService.error(error))
            }
        }
    }

    /// `runtime.connectNative`: the program stays running and both sides talk
    /// until one hangs up.
    func webExtensionController(
        _ controller: WKWebExtensionController,
        connectUsing port: WKWebExtension.MessagePort,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let identity = nativeMessagingIdentity(for: context) else {
            return completionHandler(NativeMessagingService.error(NativeMessagingService.Denial.noSuchHost(port.applicationIdentifier ?? "")))
        }
        // Kylmora's own name, answered in process: this is how an extension's
        // background code reaches the side panel API, and it starts nothing.
        if ExtensionSidebarService.isBrokerHost(port.applicationIdentifier) {
            guard let id = recordID(for: context) else {
                return completionHandler(NativeMessagingService.error(NativeMessagingService.Denial.noSuchHost(ExtensionSidebarShim.brokerHostName)))
            }
            ExtensionSidebarService.shared.attach(NativeMessagingPortAdapter(port), for: id)
            return completionHandler(nil)
        }
        let permitted = context.hasPermission(.nativeMessaging)
        Task { @MainActor in
            do {
                try await NativeMessagingService.shared.connect(
                    NativeMessagingPortAdapter(port),
                    from: identity,
                    hasPermission: permitted
                )
                completionHandler(nil)
            } catch {
                completionHandler(NativeMessagingService.error(error))
            }
        }
    }

    /// What a host's manifest would call this extension.
    ///
    /// The engine knows an extension by the identifier Kylmora gave it; a host
    /// knows it by its Chrome Web Store ID or the identifier its own manifest
    /// declares. Matching the two is this method's whole job, and it is done
    /// from the record on disk so an extension cannot claim to be another.
    func nativeMessagingIdentity(for context: WKWebExtensionContext) -> NativeMessagingExtensionIdentity? {
        let identifier = context.uniqueIdentifier
        guard let id = UUID(uuidString: identifier),
              let record = records.first(where: { $0.id == id })
        else { return nil }
        return NativeMessagingIdentity.identity(
            for: record,
            folder: index.folder(for: record),
            engineIdentifier: identifier
        )
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        presentActionPopup action: WKWebExtension.Action,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let anchor = popupAnchor?(), let popover = action.popupPopover else {
            return completionHandler(CocoaError(.featureUnsupported))
        }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        completionHandler(nil)
    }
}
