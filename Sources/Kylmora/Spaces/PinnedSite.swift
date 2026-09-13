import Foundation

/// A site pinned to the top of the sidebar as a tile.
///
/// Deliberately not a Tab. A pinned site is a destination that is always there,
/// costs nothing when you are not looking at it, and survives closing its tab.
/// Modelling it as a permanent tab would mean either a permanently loaded web
/// view or a tab that cannot be closed, and both are worse.
///
/// Opening one reuses an existing tab on the same site if there is one, so
/// clicking a pin repeatedly does not accumulate duplicates.
struct PinnedSite: Identifiable, Equatable, Sendable {
    let id: UUID
    var url: URL
    /// Shown as the tile's tooltip and used when a favicon is unavailable.
    var title: String

    init(id: UUID = UUID(), url: URL, title: String) {
        self.id = id
        self.url = url
        self.title = title
    }

    /// Two pins are "the same site" when host and path match, ignoring the
    /// query and fragment, which is what makes reopening a pin land on the tab
    /// you already have rather than a near-duplicate.
    func matches(_ other: URL) -> Bool {
        guard let a = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let b = URLComponents(url: other, resolvingAgainstBaseURL: false) else {
            return url == other
        }
        return a.host?.lowercased() == b.host?.lowercased()
            && a.path.trimmingTrailingSlash == b.path.trimmingTrailingSlash
    }
}

private extension String {
    var trimmingTrailingSlash: String {
        hasSuffix("/") && count > 1 ? String(dropLast()) : self
    }
}
