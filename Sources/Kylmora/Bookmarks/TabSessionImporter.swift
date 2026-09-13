import Foundation

/// Reads the open tabs another browser had, from its saved session.
///
/// Only Firefox is reachable: it keeps its session as JSON in a `mozLz4`
/// file (`sessionstore.jsonlz4`, or the live `recovery.jsonlz4`), which is a
/// documented, stable format. Chrome's session is an undocumented binary
/// command stream that changes between versions, and Safari's is inside a
/// container macOS protects -- neither is imported.
enum TabSessionImporter {
    struct Tab: Sendable, Equatable {
        let url: URL
        let title: String
    }

    enum Failure: Error, Equatable {
        case unreadable
        case unrecognised
    }

    /// Firefox's session: `windows[].tabs[].entries[]`, where a tab's `index`
    /// is a 1-based pointer at the entry currently shown (the rest are its
    /// back-forward history). The file is usually `mozLz4`-compressed; older or
    /// hand-saved ones are plain JSON, so both are tried.
    static func firefoxTabs(in data: Data) throws -> [Tab] {
        let json = (try? MozLz4.decompress(data)) ?? data
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let windows = root["windows"] as? [[String: Any]] else {
            throw Failure.unrecognised
        }
        var tabs: [Tab] = []
        for window in windows {
            for tab in window["tabs"] as? [[String: Any]] ?? [] {
                guard let entries = tab["entries"] as? [[String: Any]], !entries.isEmpty else { continue }
                // `index` is 1-based; clamp, since a corrupt session can point
                // past its own entries.
                let pointer = (tab["index"] as? Int).map { $0 - 1 } ?? entries.count - 1
                let entry = entries[min(max(pointer, 0), entries.count - 1)]
                guard let text = entry["url"] as? String, let url = URL(string: text),
                      url.scheme == "http" || url.scheme == "https" else { continue }
                let title = (entry["title"] as? String) ?? (tab["title"] as? String) ?? ""
                tabs.append(Tab(url: url, title: title))
            }
        }
        return tabs
    }
}
