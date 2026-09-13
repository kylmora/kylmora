import Foundation

/// Detects local sync root directories for Google Drive, Dropbox, OneDrive, and iCloud.
public enum CloudStorageDetector {
    private static var fileManager: FileManager { .default }

    private static var home: URL {
        fileManager.homeDirectoryForCurrentUser
    }

    private static var cloudStorageDirectory: URL {
        home.appending(path: "Library/CloudStorage", directoryHint: .isDirectory)
    }

    /// Tests whether a directory is actually accessible and readable.
    public static func isAccessible(url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        do {
            _ = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            return true
        } catch {
            return false
        }
    }

    /// Finds the user's Google Drive root folder, if installed and active.
    public static func detectGoogleDrive() -> URL? {
        // 1. Modern macOS FileProvider: ~/Library/CloudStorage/GoogleDrive-*
        if let contents = try? fileManager.contentsOfDirectory(at: cloudStorageDirectory, includingPropertiesForKeys: nil) {
            for url in contents where url.lastPathComponent.starts(with: "GoogleDrive") {
                let myDrive = url.appending(path: "My Drive", directoryHint: .isDirectory)
                if isAccessible(url: myDrive) {
                    return myDrive
                }
                if isAccessible(url: url) {
                    return url
                }
            }
        }

        // 2. Legacy path: ~/Google Drive/My Drive or ~/Google Drive
        let legacyMyDrive = home.appending(path: "Google Drive/My Drive", directoryHint: .isDirectory)
        if isAccessible(url: legacyMyDrive) {
            return legacyMyDrive
        }
        let legacy = home.appending(path: "Google Drive", directoryHint: .isDirectory)
        if isAccessible(url: legacy) {
            return legacy
        }

        return nil
    }

    /// Finds the user's Dropbox folder, if installed and active.
    public static func detectDropbox() -> URL? {
        // 1. ~/Library/CloudStorage/Dropbox*
        if let contents = try? fileManager.contentsOfDirectory(at: cloudStorageDirectory, includingPropertiesForKeys: nil) {
            for url in contents where url.lastPathComponent.starts(with: "Dropbox") {
                if isAccessible(url: url) {
                    return url
                }
            }
        }

        // 2. ~/Dropbox
        let legacy = home.appending(path: "Dropbox", directoryHint: .isDirectory)
        if isAccessible(url: legacy) {
            return legacy
        }

        return nil
    }

    /// Finds the user's Microsoft OneDrive folder, if installed and active.
    public static func detectOneDrive() -> URL? {
        // 1. ~/Library/CloudStorage/OneDrive*
        if let contents = try? fileManager.contentsOfDirectory(at: cloudStorageDirectory, includingPropertiesForKeys: nil) {
            for url in contents where url.lastPathComponent.starts(with: "OneDrive") {
                if isAccessible(url: url) {
                    return url
                }
            }
        }

        // 2. ~/OneDrive
        let legacy = home.appending(path: "OneDrive", directoryHint: .isDirectory)
        if isAccessible(url: legacy) {
            return legacy
        }

        return nil
    }

    /// Resolves the storage folder for a given sync service.
    public static func resolveFolder(for service: SyncService, customPath: String? = nil) -> (url: URL?, isAutoDetected: Bool, label: String) {
        if let customPath, !customPath.isEmpty {
            let url = URL(fileURLWithPath: customPath, isDirectory: true)
            return (url, false, customPath)
        }

        switch service {
        case .iCloud:
            if let ubiquity = fileManager.url(forUbiquityContainerIdentifier: nil)?.appending(path: "Documents", directoryHint: .isDirectory) {
                return (ubiquity.appending(path: "Kylmora", directoryHint: .isDirectory), true, "iCloud Drive (Ubiquity Container)")
            }
            let cloudDocs = home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs/Kylmora", directoryHint: .isDirectory)
            return (cloudDocs, true, "iCloud Drive (~/Library/Mobile Documents/com~apple~CloudDocs/Kylmora)")

        case .googleDrive:
            if let detected = detectGoogleDrive() {
                let target = detected.appending(path: "Kylmora", directoryHint: .isDirectory)
                return (target, true, "Google Drive (\(detected.lastPathComponent)/Kylmora)")
            }
            return (nil, false, "Google Drive (Not detected — choose folder)")

        case .dropbox:
            if let detected = detectDropbox() {
                let target = detected.appending(path: "Kylmora", directoryHint: .isDirectory)
                return (target, true, "Dropbox (\(detected.lastPathComponent)/Kylmora)")
            }
            return (nil, false, "Dropbox (Not detected — choose folder)")

        case .oneDrive:
            if let detected = detectOneDrive() {
                let target = detected.appending(path: "Kylmora", directoryHint: .isDirectory)
                return (target, true, "OneDrive (\(detected.lastPathComponent)/Kylmora)")
            }
            return (nil, false, "OneDrive (Not detected — choose folder)")

        case .webdav:
            return (nil, false, "Nextcloud / WebDAV (Remote Server)")

        case .customFolder:
            return (nil, false, "Custom Folder (Not configured)")
        }
    }
}
