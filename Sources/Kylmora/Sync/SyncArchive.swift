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

    /// Recent history, newest first, when history sync is on. Absent in
    /// archives written before it existed.
    var history: [SyncVisit]?

    /// Saved logins, only ever inside a passphrase-encrypted archive. Never
    /// sent to CloudKit; see `strippingCredentials()`.
    var credentials: [SyncCredential]?

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

    /// The same archive without logins, for any store that is not encrypted
    /// with the user's passphrase.
    func strippingCredentials() -> SyncArchive {
        var copy = self
        copy.credentials = nil
        return copy
    }

    /// How many visits an archive carries at most: enough for the omnibox to
    /// rank by, small enough to travel.
    static let historyLimit = 2000
}

/// One page visit, for history sync.
struct SyncVisit: Codable, Equatable, Sendable {
    var url: URL
    var title: String
    var visitedAt: Date

    init(url: URL, title: String, visitedAt: Date) {
        self.url = url
        self.title = title
        self.visitedAt = visitedAt
    }

    /// Two devices that saw the same page at the same second saw one visit.
    var key: String { "\(url.absoluteString)|\(Int(visitedAt.timeIntervalSince1970))" }
}

/// One saved login, for password sync.
struct SyncCredential: Codable, Equatable, Sendable {
    var host: String
    var username: String
    var password: String

    init(host: String, username: String, password: String) {
        self.host = host
        self.username = username
        self.password = password
    }

    var key: String { "\(host)\u{0000}\(username)" }
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
