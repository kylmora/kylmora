import AppKit
import Foundation

/// Arc-style Command Bar Site Search: typing a trigger (e.g. "youtube", "gh", "wiki")
/// and pressing Tab turns the prefix into a pill badge that searches directly on that site.
struct SiteSearch: Equatable, Sendable {
    let id: String
    let name: String
    let triggers: [String]
    let urlTemplate: String
    let badgeHex: UInt32

    static let builtIn: [SiteSearch] = [
        SiteSearch(id: "youtube", name: "YouTube", triggers: ["youtube", "youtube.com", "yt"], urlTemplate: "https://www.youtube.com/results?search_query=%@", badgeHex: 0xE53935),
        SiteSearch(id: "github", name: "GitHub", triggers: ["github", "github.com", "gh"], urlTemplate: "https://github.com/search?q=%@", badgeHex: 0x5C6BC0),
        SiteSearch(id: "wikipedia", name: "Wikipedia", triggers: ["wikipedia", "wikipedia.org", "wiki"], urlTemplate: "https://en.wikipedia.org/w/index.php?search=%@", badgeHex: 0x546E7A),
        SiteSearch(id: "reddit", name: "Reddit", triggers: ["reddit", "reddit.com"], urlTemplate: "https://www.reddit.com/search/?q=%@", badgeHex: 0xF4511E),
        SiteSearch(id: "amazon", name: "Amazon", triggers: ["amazon", "amazon.com", "amz"], urlTemplate: "https://www.amazon.com/s?k=%@", badgeHex: 0xFB8C00),
        SiteSearch(id: "google", name: "Google", triggers: ["google", "google.com", "g"], urlTemplate: "https://www.google.com/search?q=%@", badgeHex: 0x1E88E5),
        SiteSearch(id: "mdn", name: "MDN", triggers: ["mdn", "developer.mozilla.org"], urlTemplate: "https://developer.mozilla.org/en-US/search?q=%@", badgeHex: 0x00897B),
        SiteSearch(id: "npm", name: "npm", triggers: ["npm", "npmjs.com"], urlTemplate: "https://www.npmjs.com/search?q=%@", badgeHex: 0xC62828),
        SiteSearch(id: "x", name: "X", triggers: ["x.com", "twitter", "twitter.com"], urlTemplate: "https://x.com/search?q=%@", badgeHex: 0x455A64),
    ]

    /// Matches a typed command bar prefix (case-insensitive, trimmed, optional https:// or www.).
    static func match(_ raw: String) -> SiteSearch? {
        var key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key.hasPrefix("https://") { key = String(key.dropFirst(8)) }
        else if key.hasPrefix("http://") { key = String(key.dropFirst(7)) }
        if key.hasPrefix("www.") { key = String(key.dropFirst(4)) }
        if key.hasSuffix("/") { key = String(key.dropLast()) }
        guard !key.isEmpty else { return nil }
        return builtIn.first { $0.triggers.contains(key) }
    }

    func searchURL(for query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        return URL(string: urlTemplate.replacingOccurrences(of: "%@", with: encoded))
    }

    var badgeColor: NSColor {
        let r = CGFloat((badgeHex >> 16) & 0xFF) / 255.0
        let g = CGFloat((badgeHex >> 8) & 0xFF) / 255.0
        let b = CGFloat(badgeHex & 0xFF) / 255.0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }
}
