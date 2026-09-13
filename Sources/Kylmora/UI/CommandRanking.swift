import Foundation

/// What activating a command-bar row does.
///
/// An enum of plain values rather than a closure per row, because the ranker is
/// pure and has nothing to call: it decides *what* the row means, and the
/// integrator's one handler decides how the session performs it (D-UI2).
enum CommandAction: Equatable, Sendable {
    /// The identifier is `Tab.ID`, spelled as `UUID` so this layer never names
    /// a model type.
    case switchToTab(UUID)
    case openURL(URL)
}

/// An open tab, reduced to the four things ranking cares about.
struct TabCandidate: Equatable, Sendable {
    let id: UUID
    let title: String
    /// The address as the chrome writes it -- `AddressFormatter.display(...)`,
    /// no scheme -- because that is the string the user is typing against.
    let address: String
    let url: URL
    /// The tab already on screen. Offering "switch to the tab you are looking
    /// at" is a row that can only waste a keystroke, so it is dropped.
    let isActive: Bool
}

/// A history row, reduced the same way. Mirrors `HistoryEntry` without
/// depending on it.
struct HistoryCandidate: Equatable, Sendable {
    let url: URL
    let title: String
    /// `HistoryEntry.key`: the address in omnibox form, which is what prefix
    /// matching is meant to run against.
    let key: String
    let visitCount: Int
}

/// A bookmark, reduced the same way.
struct BookmarkCandidate: Equatable, Sendable {
    let url: URL
    let title: String
    /// The address in omnibox form, as for history.
    let key: String
}

/// The engine a "Search for" row would use.
struct SearchCandidate: Equatable, Sendable {
    let engineName: String
    /// The search for the query as typed.
    let url: URL
}

/// Which sources the bar draws on. Every one is on unless Settings says
/// otherwise.
struct CommandSources: Equatable, Sendable {
    var openTabs = true
    var history = true
    var bookmarks = true
    var searchEngine = true
    /// The one destination the query most plainly names -- the address that
    /// starts with what was typed -- promoted above everything.
    var topHits = true
}

/// One row of the command bar.
struct CommandResult: Equatable, Sendable, Identifiable {
    enum Kind: Equatable, Sendable {
        case openTab
        case history
        case bookmark
        case search
    }

    /// Stable across re-ranks of the same destination, so a row that survives a
    /// keystroke can keep the selection.
    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let symbolName: String
    let action: CommandAction
    /// Exposed because the ordering is the interesting part of this type and a
    /// test that could not see the score could only assert on the order.
    let score: Int
}

/// Turns a query plus the two things Kylmora can already answer it with -- open
/// tabs and history -- into an ordered list of rows.
///
/// Pure and free of AppKit, in the same spirit as `URLResolver` and
/// `TabSuspension`: the ranking is the part with judgement in it, so it is the
/// part that has to be arguable in a test rather than observable only by
/// squinting at a running browser.
enum CommandRanker {
    /// Eight is what `BrowserSession.historySuggestions` already defaults to,
    /// and about as many rows as can be scanned without reading.
    static let defaultLimit = 8

    /// Match quality, coarse and ordered. Deliberately a small ladder of named
    /// tiers rather than a fuzzy score: a user who can predict why one row is
    /// above another will trust the first row enough to press Return, which is
    /// the only interaction that matters here.
    enum Tier {
        /// The query *is* the host: "github" for github.com. The strongest
        /// signal there is, and the one a hostname-shaped query usually means.
        static let exactHost = 120
        static let addressPrefix = 100
        static let titlePrefix = 70
        /// The query starts a word inside the title, or a label inside the
        /// address: "docs" matching "developer.apple.com/documentation".
        static let wordPrefix = 50
        static let substring = 25
    }

    /// An open tab outranks a history row of equal match quality: the page is
    /// already loaded, so switching to it is both the cheaper answer and,
    /// nearly always, the one that was meant.
    static let openTabBonus = 15

    /// How much a frequently visited page may climb. Capped so that one much
    /// visited site cannot outrank a better match, which is the failure mode of
    /// every frequency-weighted omnibox.
    static let maximumFrequencyBonus = 10

    /// What a top hit is worth: above any tab or history score.
    static let topHitBonus = 100

    static func rank(
        query: String,
        tabs: [TabCandidate],
        history: [HistoryCandidate],
        bookmarks: [BookmarkCandidate] = [],
        search: SearchCandidate? = nil,
        sources: CommandSources = CommandSources(),
        limit: Int = defaultLimit
    ) -> [CommandResult] {
        let normalisedQuery = matchKey(query)
        guard !normalisedQuery.isEmpty, limit > 0 else { return [] }

        var results: [CommandResult] = []
        var claimed: Set<String> = []

        for tab in tabs where !tab.isActive && sources.openTabs {
            guard let score = score(query: normalisedQuery, title: tab.title, address: tab.address) else {
                continue
            }
            claimed.insert(destinationKey(tab.url))
            results.append(CommandResult(
                id: "tab:\(tab.id.uuidString)",
                kind: .openTab,
                title: tab.title,
                subtitle: tab.address,
                symbolName: "macwindow",
                action: .switchToTab(tab.id),
                score: score + openTabBonus
            ))
        }

        for entry in history where sources.history {
            // A history row for a page that is already open is the same
            // destination said twice; the tab is the better half of the pair.
            let key = destinationKey(entry.url)
            guard !claimed.contains(key) else { continue }
            guard let score = score(query: normalisedQuery, title: entry.title, address: entry.key) else {
                continue
            }
            claimed.insert(key)
            results.append(CommandResult(
                id: "history:\(key)",
                kind: .history,
                title: entry.title.isEmpty ? entry.key : entry.title,
                subtitle: entry.key,
                symbolName: "clock",
                action: .openURL(entry.url),
                score: score + min(max(entry.visitCount, 0), maximumFrequencyBonus)
            ))
        }

        for bookmark in bookmarks where sources.bookmarks {
            let key = destinationKey(bookmark.url)
            guard !claimed.contains(key) else { continue }
            guard let score = score(query: normalisedQuery, title: bookmark.title, address: bookmark.key) else {
                continue
            }
            claimed.insert(key)
            results.append(CommandResult(
                id: "bookmark:\(key)",
                kind: .bookmark,
                title: bookmark.title.isEmpty ? bookmark.key : bookmark.title,
                subtitle: bookmark.key,
                symbolName: "bookmark",
                action: .openURL(bookmark.url),
                score: score
            ))
        }

        // The top hit: of the destinations whose address starts with what
        // was typed, the shortest, which is what a bare hostname means. Open
        // tabs are candidates too, so a tab already on the site stays the
        // answer -- switching still beats reloading.
        if sources.topHits {
            let prefixed = results.enumerated().filter { matchKey($0.element.subtitle).hasPrefix(normalisedQuery) }
            // Ties broken the same way the final order is, so the choice
            // never depends on the order candidates were gathered in.
            if let top = prefixed.min(by: {
                if $0.element.subtitle.count != $1.element.subtitle.count { return $0.element.subtitle.count < $1.element.subtitle.count }
                if $0.element.subtitle != $1.element.subtitle { return $0.element.subtitle < $1.element.subtitle }
                return $0.element.id < $1.element.id
            }) {
                let row = top.element
                results[top.offset] = CommandResult(
                    id: row.id, kind: row.kind, title: row.title, subtitle: row.subtitle,
                    symbolName: row.symbolName, action: row.action, score: row.score + topHitBonus
                )
            }
        }

        var ordered = Array(results.sorted(by: isOrderedBefore).prefix(limit))

        // The search row is last, and always there when the source is on:
        // it is the one answer that cannot be wrong, so it never competes.
        if sources.searchEngine, let search {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            ordered.append(CommandResult(
                id: "search",
                kind: .search,
                title: "Search \(search.engineName) for \u{201c}\(trimmed)\u{201d}",
                subtitle: search.url.host() ?? search.engineName,
                symbolName: "magnifyingglass",
                action: .openURL(search.url),
                score: -1
            ))
        }
        return ordered
    }

    /// Total, so ranking never depends on the order the caller happened to
    /// gather its candidates in. After the score, the shorter address wins:
    /// between `example.com` and `example.com/a/b/c` the root is the more
    /// canonical destination, and it is the one a bare hostname query means.
    private static func isOrderedBefore(_ lhs: CommandResult, _ rhs: CommandResult) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.kind != rhs.kind { return lhs.kind == .openTab }
        if lhs.subtitle.count != rhs.subtitle.count { return lhs.subtitle.count < rhs.subtitle.count }
        if lhs.subtitle != rhs.subtitle { return lhs.subtitle < rhs.subtitle }
        return lhs.id < rhs.id
    }

    /// The tier a query earns against one candidate, or nil for no match.
    ///
    /// Checked in descending order so the first hit is the best one; the ladder
    /// reads as the precedence it implements.
    static func score(query: String, title: String, address: String) -> Int? {
        let query = matchKey(query)
        guard !query.isEmpty else { return nil }

        let address = matchKey(address)
        let title = normalise(title)
        let host = String(address.prefix { $0 != "/" })

        if host == query { return Tier.exactHost }
        if address.hasPrefix(query) { return Tier.addressPrefix }
        if title.hasPrefix(query) { return Tier.titlePrefix }
        if startsAWord(query, in: title) || startsAWord(query, in: address) { return Tier.wordPrefix }
        if address.contains(query) || title.contains(query) { return Tier.substring }
        return nil
    }

    // MARK: - Normalisation

    /// Case- and accent-insensitive, trimmed. Typing is not spelling.
    static func normalise(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `normalise`, plus the two prefixes that carry no information for
    /// matching: the scheme and `www.`. Without this, pasting a full URL back
    /// into the bar would fail to match the history row it came from.
    static func matchKey(_ text: String) -> String {
        var key = normalise(text)
        if let separator = key.range(of: "://") {
            key = String(key[separator.upperBound...])
        }
        if key.hasPrefix("www.") {
            key = String(key.dropFirst(4))
        }
        return key
    }

    /// Two URLs are the same destination when they differ only by scheme,
    /// `www.` or a trailing slash -- which is exactly how the same page tends
    /// to arrive from a tab and from history.
    private static func destinationKey(_ url: URL) -> String {
        let key = matchKey(url.absoluteString)
        return key.hasSuffix("/") ? String(key.dropLast()) : key
    }

    /// Whether the query begins a word. Words are split on the punctuation that
    /// separates them in both prose and addresses, so `docs` starts a word in
    /// "Apple Docs" and in "developer.apple.com/docs".
    private static func startsAWord(_ query: String, in text: String) -> Bool {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .contains { $0.hasPrefix(query) }
    }
}
