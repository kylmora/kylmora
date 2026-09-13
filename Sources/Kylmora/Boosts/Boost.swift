import Foundation

/// A per-site customization: user CSS, user JavaScript, and universal dark mode.
public struct Boost: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    /// The normalized hostname the boost applies to (e.g. "github.com"), or "*" for global.
    public var host: String
    public var name: String
    public var isEnabled: Bool
    public var isDarkModeEnabled: Bool
    public var customCSS: String
    public var customJS: String
    public var dateModified: Date

    public init(
        id: UUID = UUID(),
        host: String,
        name: String = "",
        isEnabled: Bool = true,
        isDarkModeEnabled: Bool = false,
        customCSS: String = "",
        customJS: String = "",
        dateModified: Date = .now
    ) {
        self.id = id
        self.host = host
        self.name = name.isEmpty ? host : name
        self.isEnabled = isEnabled
        self.isDarkModeEnabled = isDarkModeEnabled
        self.customCSS = customCSS
        self.customJS = customJS
        self.dateModified = dateModified
    }
}
