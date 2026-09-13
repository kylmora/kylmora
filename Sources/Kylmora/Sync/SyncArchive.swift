import Foundation

/// A complete, standalone sync package containing browser state across devices.
///
/// Designed to be serialised as JSON for:
/// 1. End-to-end encrypted iCloud / CloudKit sync
/// 2. Local-first file sync (iCloud Drive / local ubiquitous directory)
/// 3. One-click JSON backup and restore (F-12)
struct SyncArchive: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var deviceID: UUID
    var deviceName: String
    var exportedAt: Date

    /// Core sidebar model: Spaces, folders, pinned sites, and tabs.
    var session: SessionSnapshot

    /// Bookmarks tree.
    var bookmarks: [SyncBookmark]

    /// Per-site rules and permissions (Content blockers, AutoPlay, Zoom, etc.).
    var siteSettings: SiteSettingsState?

    /// Domain and URL Space routing rules.
    var spaceRouting: [SpaceRoute]?

    /// Custom search engines.
    var customSearchEngines: [SearchEngine]?
    var defaultSearchEngineID: String?

    init(
        version: Int = currentVersion,
        deviceID: UUID = UUID(),
        deviceName: String = Host.current().localizedName ?? "Mac",
        exportedAt: Date = .now,
        session: SessionSnapshot,
        bookmarks: [SyncBookmark] = [],
        siteSettings: SiteSettingsState? = nil,
        spaceRouting: [SpaceRoute]? = nil,
        customSearchEngines: [SearchEngine]? = nil,
        defaultSearchEngineID: String? = nil
    ) {
        self.version = version
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.exportedAt = exportedAt
        self.session = session
        self.bookmarks = bookmarks
        self.siteSettings = siteSettings
        self.spaceRouting = spaceRouting
        self.customSearchEngines = customSearchEngines
        self.defaultSearchEngineID = defaultSearchEngineID
    }
}

/// A bookmark entry formatted for cross-device sync.
struct SyncBookmark: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var url: URL
    var title: String
    var folder: String
    var created: Date

    init(
        id: UUID = UUID(),
        url: URL,
        title: String,
        folder: String = "",
        created: Date = .now
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.folder = folder
        self.created = created
    }
}
