import Foundation

/// Supported cloud storage and sync destinations.
public enum SyncService: String, CaseIterable, Codable {
    case iCloud = "icloud"
    case googleDrive = "google_drive"
    case dropbox = "dropbox"
    case oneDrive = "onedrive"
    case webdav = "webdav"
    case customFolder = "custom"

    public var title: String {
        switch self {
        case .iCloud: return "Apple iCloud Drive"
        case .googleDrive: return "Google Drive"
        case .dropbox: return "Dropbox"
        case .oneDrive: return "Microsoft OneDrive"
        case .webdav: return "Nextcloud / WebDAV"
        case .customFolder: return "Custom Folder / Network Share"
        }
    }

    public var symbolName: String {
        switch self {
        case .iCloud: return "icloud"
        case .googleDrive: return "externaldrive.badge.icloud"
        case .dropbox: return "shippingbox"
        case .oneDrive: return "cloud"
        case .webdav: return "server.rack"
        case .customFolder: return "folder"
        }
    }

    public var isFileProvider: Bool {
        self != .webdav
    }
}
