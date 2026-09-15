import AppKit
import Foundation

/// The page a new tab opens with when it is Kylmora's own: native, drawn in
/// the window, nothing fetched. It has an address so a tab can carry it
/// through the session file and the omnibox can tell it apart from a page,
/// but the web view underneath is never asked to load it.
enum StartPage {
    static let url = URL(string: "kylmora://start")!
    static let title = "New Tab"

    static func isStartPage(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "kylmora" && url.host()?.lowercased() == "start"
    }
}

/// What the start page shows, gathered by whoever has the session.
struct StartPageModel: Equatable {
    struct Link: Equatable, Identifiable {
        let id: String
        let url: URL
        let title: String

        init(id: String? = nil, url: URL, title: String) {
            self.id = id ?? url.absoluteString
            self.url = url
            self.title = title.isEmpty ? (url.host() ?? url.absoluteString) : title
        }
    }

    var spaceName: String = ""
    var spaceColor: NSColor?
    var isPrivate = false
    var pinned: [Link] = []
    var topSites: [Link] = []
    var recentlyClosed: [Link] = []
    var readingList: [Link] = []

    var isEmpty: Bool { pinned.isEmpty && topSites.isEmpty && recentlyClosed.isEmpty && readingList.isEmpty }

    /// Top sites that are not already pinned, so a site is never shown twice.
    var topSitesNotPinned: [Link] {
        let pinnedHosts = Set(pinned.compactMap { $0.url.host() })
        return topSites.filter { site in
            guard let host = site.url.host() else { return true }
            return !pinnedHosts.contains(host)
        }
    }
}
