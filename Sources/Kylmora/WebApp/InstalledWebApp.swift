import Foundation

/// Represents a web site installed or running as a standalone Web App (SSB - Site Specific Browser).
public struct InstalledWebApp: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var url: URL
    public var spaceID: UUID?
    public var appBundlePath: String?
    public var iconPath: String?
    public var dateInstalled: Date

    public init(
        id: UUID = UUID(),
        name: String,
        url: URL,
        spaceID: UUID? = nil,
        appBundlePath: String? = nil,
        iconPath: String? = nil,
        dateInstalled: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.spaceID = spaceID
        self.appBundlePath = appBundlePath
        self.iconPath = iconPath
        self.dateInstalled = dateInstalled
    }
}
