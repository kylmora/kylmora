import Foundation

/// An article saved to the user's Reading List for later or offline reading.
public struct ReadingListItem: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let url: URL
    public var title: String
    public var previewText: String
    public let dateAdded: Date
    public var isRead: Bool
    public var offlineHTML: String?

    public init(
        id: UUID = UUID(),
        url: URL,
        title: String,
        previewText: String = "",
        dateAdded: Date = Date(),
        isRead: Bool = false,
        offlineHTML: String? = nil
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.previewText = previewText
        self.dateAdded = dateAdded
        self.isRead = isRead
        self.offlineHTML = offlineHTML
    }

    public var host: String {
        url.host() ?? url.absoluteString
    }
}
