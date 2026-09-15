import Foundation
import Combine
import AppKit

/// Coordinates cross-device sync for Kylmora.
///
/// Encapsulates local file/iCloud Drive sync and Apple CloudKit sync.
/// Listens to session saves to automatically broadcast changes, and periodically
/// pulls remote changes to merge seamlessly.
@MainActor
final class SyncCoordinator: ObservableObject {
    enum SyncStatus: Equatable {
        case disabled
        case idle
        case syncing
        case synced(Date)
        case error(String)

        var title: String {
            switch self {
            case .disabled:
                return "Sync Disabled"
            case .idle:
                return "Ready to sync"
            case .syncing:
                return "Syncing with iCloud…"
            case .synced(let date):
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .short
                return "Synced \(formatter.localizedString(for: date, relativeTo: .now))"
            case .error(let message):
                return "Sync error: \(message)"
            }
        }
    }

    let session: BrowserSession
    private let database: BrowserDatabase?
    private let settings: Settings

    @Published private(set) var status: SyncStatus = .idle
    private var syncTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var pollTimer: Timer?

    private var fileProvider: FileUbiquitySyncProvider
    private var webdavProvider: WebDAVSyncProvider?
    private var cloudKitProvider: CloudKitSyncProvider?

    var deviceID: UUID {
        let key = "kylmora.sync.deviceID"
        if let stored = UserDefaults.standard.string(forKey: key), let uuid = UUID(uuidString: stored) {
            return uuid
        }
        let fresh = UUID()
        UserDefaults.standard.set(fresh.uuidString, forKey: key)
        return fresh
    }

    var deviceName: String {
        Host.current().localizedName ?? "Mac"
    }

    init(session: BrowserSession, database: BrowserDatabase?, settings: Settings = .shared) {
        self.session = session
        self.database = database
        self.settings = settings

        let syncDir = AppPaths.syncDirectory(for: settings.syncService, customPath: settings.syncCustomDirectory.isEmpty ? nil : settings.syncCustomDirectory)
        self.fileProvider = FileUbiquitySyncProvider(syncDirectory: syncDir)
        self.cloudKitProvider = CloudKitSyncProvider()
        self.reloadProviders()
    }

    /// Reconfigures active storage providers based on user settings.
    func reloadProviders() {
        let syncDir = AppPaths.syncDirectory(for: settings.syncService, customPath: settings.syncCustomDirectory.isEmpty ? nil : settings.syncCustomDirectory)
        self.fileProvider = FileUbiquitySyncProvider(syncDirectory: syncDir)

        if settings.syncService == .webdav, let url = URL(string: settings.syncWebDAVURL), !settings.syncWebDAVURL.isEmpty {
            self.webdavProvider = WebDAVSyncProvider(
                serverURL: url,
                username: settings.syncWebDAVUsername,
                password: settings.syncWebDAVPassword
            )
        } else {
            self.webdavProvider = nil
        }
    }

    /// Tests WebDAV connection with current settings.
    func testWebDAVConnection() async throws -> Bool {
        guard let url = URL(string: settings.syncWebDAVURL), !settings.syncWebDAVURL.isEmpty else {
            throw WebDAVSyncProvider.WebDAVError.invalidURL
        }
        let provider = WebDAVSyncProvider(
            serverURL: url,
            username: settings.syncWebDAVUsername,
            password: settings.syncWebDAVPassword
        )
        return try await provider.testConnection()
    }

    /// Starts observing changes and running periodic syncs if enabled.
    func start() {
        updateStatusFromSettings()

        // Debounce session changes to auto-sync
        session.changes
            .debounce(for: .seconds(5), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.settings.syncEnabled else { return }
                Task { [weak self] in
                    try? await self?.syncNow()
                }
            }
            .store(in: &cancellables)

        // Periodic background pull (every 3 minutes)
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.settings.syncEnabled else { return }
                try? await self.syncNow()
            }
        }

        if settings.syncEnabled {
            Task { [weak self] in
                try? await self?.syncNow()
            }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        cancellables.removeAll()
    }

    func updateSyncDirectory() {
        reloadProviders()
        if settings.syncEnabled {
            Task { [weak self] in
                try? await self?.syncNow()
            }
        }
    }

    func updateStatusFromSettings() {
        if !settings.syncEnabled {
            status = .disabled
        } else if settings.syncLastTimestamp > 0 {
            status = .synced(Date(timeIntervalSince1970: settings.syncLastTimestamp))
        } else {
            status = .idle
        }
    }

    /// Performs an immediate push of local state and pulls/merges remote peer updates.
    func syncNow() async throws {
        guard settings.syncEnabled else {
            status = .disabled
            return
        }

        status = .syncing
        reloadProviders()

        do {
            let passphrase = settings.syncPassphrase.isEmpty ? nil : settings.syncPassphrase

            // 1. Build local archive
            let localArchive = await buildCurrentArchive()

            // 2. Save local archive to active provider
            var remoteArchives: [SyncArchive] = []

            if settings.syncService == .webdav, let webdav = webdavProvider {
                try await webdav.saveLocalArchive(localArchive, passphrase: passphrase)
                remoteArchives = try await webdav.fetchRemoteArchives(excludingDeviceID: deviceID, passphrase: passphrase)
            } else {
                try await fileProvider.saveLocalArchive(localArchive, passphrase: passphrase)

                if settings.syncService == .iCloud, let cloudKitProvider, await cloudKitProvider.isAvailable() {
                    // CloudKit holds the archive as it is; logins go only
                    // where the passphrase has encrypted them.
                    try? await cloudKitProvider.save(archive: localArchive.strippingCredentials())
                }

                remoteArchives = await fileProvider.fetchRemoteArchives(excludingDeviceID: deviceID, passphrase: passphrase)

                if remoteArchives.isEmpty, settings.syncService == .iCloud, let cloudKitProvider, await cloudKitProvider.isAvailable() {
                    remoteArchives = (try? await cloudKitProvider.fetchRemoteArchives(excludingDeviceID: deviceID)) ?? []
                }
            }

            // 5. Merge remote archives into local state
            var currentMerged = localArchive
            var totalSummary = SyncMergePolicy.MergeSummary()

            for remote in remoteArchives {
                let (merged, summary) = SyncMergePolicy.merge(
                    local: currentMerged,
                    remote: remote,
                    syncOpenTabs: settings.syncOpenTabs,
                    syncBookmarks: settings.syncBookmarks,
                    syncSiteSettings: settings.syncSiteSettings,
                    syncHistory: settings.syncHistory,
                    syncPasswords: settings.syncPasswords && passphrase != nil
                )
                currentMerged = merged
                if summary.hasChanges {
                    totalSummary.addedSpaces += summary.addedSpaces
                    totalSummary.addedGroups += summary.addedGroups
                    totalSummary.addedPinnedSites += summary.addedPinnedSites
                    totalSummary.addedTabs += summary.addedTabs
                    totalSummary.addedBookmarks += summary.addedBookmarks
                    totalSummary.updatedSiteSettings += summary.updatedSiteSettings
                    totalSummary.addedRoutes += summary.addedRoutes
                    totalSummary.addedVisits += summary.addedVisits
                    totalSummary.addedCredentials += summary.addedCredentials
                }
            }

            // 6. Apply merged changes to active session if anything changed
            if totalSummary.hasChanges {
                session.mergeSnapshot(currentMerged.session, mergeTabs: settings.syncOpenTabs)

                if settings.syncBookmarks && totalSummary.addedBookmarks > 0 {
                    await session.importSyncBookmarks(currentMerged.bookmarks)
                }

                if settings.syncSiteSettings, let updatedSites = currentMerged.siteSettings {
                    SiteSettings.shared.update { state in
                        state = updatedSites
                    }
                }

                if settings.syncHistory, totalSummary.addedVisits > 0, let history = currentMerged.history {
                    await session.importSyncVisits(history)
                }

                if settings.syncPasswords, passphrase != nil, totalSummary.addedCredentials > 0, let credentials = currentMerged.credentials {
                    Self.importCredentials(credentials)
                }

                session.showToast?(
                    Toast(
                        symbolName: "arrow.triangle.2.circlepath",
                        message: "Synced with other devices"
                    )
                )
            }

            let now = Date.now
            settings.syncLastTimestamp = now.timeIntervalSince1970
            status = .synced(now)
        } catch {
            status = .error(error.localizedDescription)
            throw error
        }
    }

    /// Exports the entire browser state as a standalone JSON backup file.
    func exportBackup(to url: URL) async throws {
        let archive = await buildCurrentArchive()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(archive)
        try data.write(to: url, options: [.atomic])
    }

    /// Imports browser state from a JSON backup file.
    func importBackup(from url: URL, mode: SyncMergePolicy.MergeMode) async throws {
        let data = try Data(contentsOf: url)
        let archive = try JSONDecoder().decode(SyncArchive.self, from: data)

        switch mode {
        case .replace:
            session.replaceWithSnapshot(archive.session)
            if !archive.bookmarks.isEmpty {
                await session.importSyncBookmarks(archive.bookmarks)
            }
            if let siteSettings = archive.siteSettings {
                SiteSettings.shared.update { state in
                    state = siteSettings
                }
            }
        case .merge:
            let local = await buildCurrentArchive()
            let (merged, _) = SyncMergePolicy.merge(
                local: local,
                remote: archive,
                syncOpenTabs: true,
                syncBookmarks: true,
                syncSiteSettings: true
            )
            session.mergeSnapshot(merged.session, mergeTabs: true)
            if !merged.bookmarks.isEmpty {
                await session.importSyncBookmarks(merged.bookmarks)
            }
            if let siteSettings = merged.siteSettings {
                SiteSettings.shared.update { state in
                    state = siteSettings
                }
            }
        }
    }

    /// Imports Arc's `StorableSidebar.json` file into Kylmora.
    func importArcSidebar(from url: URL) async throws {
        let data = try Data(contentsOf: url)
        let snapshot = try ArcSidebarImporter.importSidebar(from: data)
        session.mergeSnapshot(snapshot, mergeTabs: true)
    }

    /// Adds logins from other devices that this Mac does not have. An
    /// existing login keeps its own password.
    static func importCredentials(_ credentials: [SyncCredential]) {
        let existing = Set(KeychainPasswordStore.all().map { "\($0.host)\u{0000}\($0.username)" })
        for credential in credentials where !existing.contains(credential.key) && !credential.password.isEmpty {
            KeychainPasswordStore.save(host: credential.host, username: credential.username, password: credential.password)
        }
    }

    private func buildCurrentArchive() async -> SyncArchive {
        let sessionSnapshot = session.snapshot()
        let currentBookmarks = await session.allBookmarks()
        let syncBookmarks = currentBookmarks.map {
            SyncBookmark(url: $0.url, title: $0.title, folder: $0.folder, created: $0.created)
        }
        let siteSettings = SiteSettings.shared.state
        let spaceRouting = SpaceRoutingStore().load().routes
        let searchEngines = settings.customSearchEngines

        var archive = SyncArchive(
            version: SyncArchive.currentVersion,
            deviceID: deviceID,
            deviceName: deviceName,
            exportedAt: .now,
            session: sessionSnapshot,
            bookmarks: syncBookmarks,
            siteSettings: siteSettings,
            spaceRouting: spaceRouting,
            customSearchEngines: searchEngines,
            defaultSearchEngineID: settings.searchEngine.id
        )
        if settings.syncHistory {
            archive.history = await session.recentVisits()
        }
        // Logins only travel encrypted: no passphrase, no logins.
        if settings.syncPasswords, !settings.syncPassphrase.isEmpty {
            archive.credentials = KeychainPasswordStore.all().map {
                SyncCredential(host: $0.host, username: $0.username, password: $0.password)
            }
        }
        return archive
    }
}
