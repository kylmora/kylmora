import Foundation

/// Where Kylmora keeps its data.
///
/// `Application Support/<bundle id>` is the location macOS expects, and is
/// inside the container if the app is ever sandboxed, so nothing here needs to
/// change when entitlements are added.
enum AppPaths {
    static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.kylmora.Kylmora"

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: bundleIdentifier, directoryHint: .isDirectory)
    }

    static var databaseFile: URL { supportDirectory.appending(path: "browser.sqlite") }
    static var sessionFile: URL { supportDirectory.appending(path: "session.json") }

    /// Where cross-device sync data lives. Checks for custom path, iCloud ubiquitous container,
    /// Directory for cross-device sync storage. Resolves the active sync service (iCloud,
    /// Google Drive, Dropbox, OneDrive, or custom folder) and creates it if needed.
    static func syncDirectory(for service: SyncService = .iCloud, customPath: String? = nil) -> URL {
        let (url, _, _) = CloudStorageDetector.resolveFolder(for: service, customPath: customPath)
        if let url {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let fallback = supportDirectory.appending(path: "Sync/\(service.rawValue)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    /// Creates the support directory if needed. Returns false if it could not be
    /// created, so callers can degrade to running without persistence rather
    /// than crashing.
    @discardableResult
    static func ensureSupportDirectory() -> Bool {
        do {
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }
}
