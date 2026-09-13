import Foundation

/// Where an icon came from, which is also how good it is.
///
/// A `.dom` icon is the one the page itself declares, so it is the icon the
/// site's authors chose. A `.convention` icon is whatever answers
/// `/favicon.ico`, which is often the same file and occasionally a leftover
/// from a previous design. Recording the difference is what lets a cached
/// convention icon be upgraded once the page is loaded and can be asked.
enum FaviconSourceKind: String, Sendable, CaseIterable {
    case convention = "c"
    case dom = "d"
}

/// One `<link rel="icon">` as the page's own DOM reports it.
struct FaviconLink: Sendable, Equatable {
    var href: String
    var rel: String = ""
    var sizes: String = ""
    var type: String = ""
}

/// Turning a page into an ordered list of icon URLs to try.
///
/// This is deliberately free of AppKit, WebKit and Foundation networking: the
/// interesting part of favicon discovery is a pile of edge cases (relative
/// hrefs, `sizes="any"`, `apple-touch-icon` at 180 points, `mask-icon` that is
/// a monochrome SVG stencil and not a favicon at all), and every one of them is
/// a unit test here rather than a site that quietly shows the wrong icon.
enum FaviconSource {
    /// Two device pixels per point at the sidebar's 16-point icon slot. Icons
    /// are ranked by how close they get to this without going under it.
    static let targetPixelSize = 32

    /// The cache is keyed by host alone. A site serves one favicon for its
    /// whole origin in practice, and folding `http` and `https` together avoids
    /// fetching the same bytes twice for a host that upgrades mid-session.
    static func cacheKey(for pageURL: URL) -> String? {
        guard isFetchableScheme(pageURL.scheme), let host = pageURL.host() else { return nil }
        let trimmed = host.lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `/favicon.ico` at the page's own origin: the convention that predates
    /// the `<link>` tag and is still the only thing many sites publish.
    static func conventionURL(for pageURL: URL) -> URL? {
        guard let scheme = pageURL.scheme, isFetchableScheme(scheme), let host = pageURL.host() else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = pageURL.port
        components.path = "/favicon.ico"
        return components.url
    }

    /// The URLs to try, best first, always ending in the `/favicon.ico`
    /// convention so a page whose declared icons all fail still has a chance.
    static func candidates(pageURL: URL, links: [FaviconLink]) -> [URL] {
        let ranked = links
            .compactMap { link -> (url: URL, rank: Rank)? in
                guard let url = resolve(link.href, against: pageURL), isUsable(link, url: url) else { return nil }
                return (url, rank(for: link, url: url))
            }
            .enumerated()
            .sorted { left, right in
                if left.element.rank != right.element.rank { return left.element.rank < right.element.rank }
                // Equally appropriate icons keep declaration order, which is
                // what the HTML specification says a user agent must do.
                return left.offset < right.offset
            }
            .map(\.element.url)

        var seen: Set<String> = []
        var result: [URL] = []
        for url in ranked + [conventionURL(for: pageURL)].compactMap({ $0 }) {
            let key = url.absoluteString
            if seen.insert(key).inserted { result.append(url) }
        }
        return result
    }

    // MARK: - Ranking

    /// Sorts as: a size at or above the target (closest first), then an unknown
    /// size, then a size below the target (largest first).
    ///
    /// Unknown sits in the middle rather than last because an undeclared size
    /// is usually a `.ico` holding several sizes, one of which is the one we
    /// want — the same reason Chromium favours `.ico` files.
    private struct Rank: Comparable {
        var tier: Int
        var distance: Int

        static func < (lhs: Rank, rhs: Rank) -> Bool {
            lhs.tier != rhs.tier ? lhs.tier < rhs.tier : lhs.distance < rhs.distance
        }
    }

    private static func rank(for link: FaviconLink, url: URL) -> Rank {
        guard let side = largestDeclaredSide(in: link.sizes) else { return Rank(tier: 1, distance: 0) }
        if side >= targetPixelSize { return Rank(tier: 0, distance: side - targetPixelSize) }
        return Rank(tier: 2, distance: targetPixelSize - side)
    }

    /// `sizes` is a space-separated list such as `"16x16 32x32"`. `"any"` means
    /// a vector icon and carries no size, so it reads as unknown.
    static func largestDeclaredSide(in sizes: String) -> Int? {
        var largest: Int?
        for token in sizes.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }) {
            let parts = token.split(separator: "x", omittingEmptySubsequences: false)
            guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]),
                  width > 0, height > 0 else { continue }
            largest = max(largest ?? 0, max(width, height))
        }
        return largest
    }

    // MARK: - Filtering

    private static func isFetchableScheme(_ scheme: String?) -> Bool {
        scheme == "http" || scheme == "https"
    }

    private static func resolve(_ href: String, against pageURL: URL) -> URL? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed, relativeTo: pageURL)?.absoluteURL
    }

    private static func isUsable(_ link: FaviconLink, url: URL) -> Bool {
        // Only ordinary web fetches. `data:` and `blob:` icons are skipped
        // rather than special-cased: they are rare, and every one of them is a
        // second decoding path to get wrong.
        guard isFetchableScheme(url.scheme), url.host() != nil else { return false }

        let rel = link.rel.lowercased()
        // `mask-icon` is Safari's monochrome pinned-tab stencil. It is a
        // single-colour SVG silhouette, not the site's icon, and drawing it
        // would show a black blob where the favicon should be.
        if rel.split(whereSeparator: \.isWhitespace).contains("mask-icon") { return false }

        // SVG is deliberately not accepted; see the decision log. Filtering it
        // here keeps a site that declares only an SVG icon falling through to
        // `/favicon.ico` instead of burning a request on bytes we will refuse.
        if link.type.lowercased().contains("svg") { return false }
        if url.pathExtension.lowercased() == "svg" { return false }

        return true
    }
}
