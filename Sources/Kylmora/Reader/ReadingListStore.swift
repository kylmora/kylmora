import AppKit
import Foundation

extension Notification.Name {
    public static let readingListDidChange = Notification.Name("readingListDidChange")
}

/// Thread-safe, persistent storage for articles saved in the user's Reading List.
@MainActor
public final class ReadingListStore {
    public static let shared = ReadingListStore()

    private let fileURL: URL
    public private(set) var items: [ReadingListItem] = []

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = appSupport.appendingPathComponent("Kylmora", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("reading_list.json")
        }
        load()
    }

    public var unreadItems: [ReadingListItem] {
        items.filter { !$0.isRead }
    }

    public var unreadCount: Int {
        unreadItems.count
    }

    public func contains(url: URL) -> Bool {
        items.contains { $0.url == url }
    }

    @discardableResult
    public func add(
        url: URL,
        title: String,
        previewText: String = "",
        offlineHTML: String? = nil
    ) -> ReadingListItem {
        if let idx = items.firstIndex(where: { $0.url == url }) {
            items[idx].title = title
            if !previewText.isEmpty { items[idx].previewText = previewText }
            if let offlineHTML { items[idx].offlineHTML = offlineHTML }
            save()
            notify()
            return items[idx]
        }

        let item = ReadingListItem(
            url: url,
            title: title.isEmpty ? (url.host() ?? "Untitled") : title,
            previewText: previewText,
            offlineHTML: offlineHTML
        )
        items.insert(item, at: 0)
        save()
        notify()
        return item
    }

    public func remove(id: UUID) {
        items.removeAll { $0.id == id }
        save()
        notify()
    }

    public func toggleRead(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].isRead.toggle()
        save()
        notify()
    }

    public func markAllRead() {
        for i in items.indices {
            items[i].isRead = true
        }
        save()
        notify()
    }

    public func clearAll() {
        items.removeAll()
        save()
        notify()
    }

    private func notify() {
        NotificationCenter.default.post(name: .readingListDidChange, object: self)
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(items)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Kylmora: Could not save reading list: \(error)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            items = try decoder.decode([ReadingListItem].self, from: data)
        } catch {
            NSLog("Kylmora: Could not load reading list: \(error)")
            items = []
        }
    }
}
