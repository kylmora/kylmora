import Foundation

/// A live folder whose tabs are the newest entries of a feed.
///
/// Handles RSS 2.0 and Atom from the same parser. They are different enough to
/// justify two parsers and similar enough that two would drift: both are a flat
/// list of entries with a title, a link, an identity and a date, and the only
/// real differences are the element names and where the link hides.
struct RSSLiveFolderProvider: LiveFolderProvider {
    static let kind: LiveFolderKind = .rss

    struct Configuration: Codable, Sendable, Equatable {
        var feedURL: URL
        /// Feeds routinely publish hundreds of entries. A folder is a sidebar
        /// section, not an archive.
        var maxItems: Int = 10
        /// Seconds; 0 means no limit. A feed that has not updated in a year
        /// should still show its entries, which is why the default is 0 rather
        /// than a day.
        var timeRange: TimeInterval = 0
        /// Filled in from the feed's own `<title>` the first time it parses, so
        /// the folder stops being called "RSS Feed" the moment it works.
        var feedTitle: String?
    }

    static let maxItemChoices = [5, 10, 25, 50]
    static let timeRangeChoices: [(seconds: TimeInterval, title: String)] = [
        (0, "All time"),
        (3600, "Last hour"),
        (6 * 3600, "Last 6 hours"),
        (12 * 3600, "Last 12 hours"),
        (24 * 3600, "Last 24 hours"),
        (3 * 24 * 3600, "Last 3 days")
    ]

    var configuration: Configuration

    var source: LiveFolderSource { .rss(configuration) }

    var metadata: LiveFolderMetadata {
        LiveFolderMetadata(
            name: configuration.feedTitle ?? configuration.feedURL.host() ?? "Feed",
            symbolName: "dot.radiowaves.up.forward"
        )
    }

    var options: [LiveFolderOption] {
        [
            .choice(
                key: "maxItems",
                title: "Show",
                values: Self.maxItemChoices.map {
                    LiveFolderOption.Value(value: String($0), title: "\($0) items")
                },
                selected: String(configuration.maxItems)
            ),
            .choice(
                key: "timeRange",
                title: "From",
                values: Self.timeRangeChoices.map {
                    LiveFolderOption.Value(value: String(Int($0.seconds)), title: $0.title)
                },
                selected: String(Int(configuration.timeRange))
            )
        ]
    }

    func applying(_ change: LiveFolderOptionChange) -> any LiveFolderProvider {
        var updated = configuration
        switch (change.key, change.value) {
        case ("maxItems", .string(let raw)):
            if let value = Int(raw) { updated.maxItems = max(1, value) }
        case ("timeRange", .string(let raw)):
            if let value = TimeInterval(raw) { updated.timeRange = max(0, value) }
        default:
            break
        }
        return RSSLiveFolderProvider(configuration: updated)
    }

    /// A feed that names itself renames the folder once, so a folder created
    /// from a bare URL stops being called by its hostname.
    func learning(from items: [LiveFolderItem]) -> any LiveFolderProvider {
        guard configuration.feedTitle == nil,
              let title = items.compactMap(\.subtitle).first,
              !title.isEmpty
        else { return self }
        var updated = configuration
        updated.feedTitle = title
        return RSSLiveFolderProvider(configuration: updated)
    }

    func fetchItems(using fetcher: LiveFolderFetcher) async -> LiveFolderFetch {
        guard let scheme = configuration.feedURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return .blocked(.notConfigured)
        }

        let response: LiveFolderFetcher.Response
        do {
            response = try await fetcher.get(
                configuration.feedURL,
                accept: "application/atom+xml, application/rss+xml, application/xml;q=0.9, text/xml;q=0.8"
            )
        } catch let failure as LiveFolderFetcher.Failure {
            return .blocked(.from(failure))
        } catch {
            return .blocked(.network((error as NSError).localizedDescription))
        }

        guard let parsed = FeedParser.parse(response.text) else {
            return .blocked(.malformedResponse)
        }

        let cutoff = configuration.timeRange > 0 ? Date().addingTimeInterval(-configuration.timeRange) : nil
        let items = parsed.entries
            .filter { entry in cutoff.map { entry.date > $0 } ?? true }
            .sorted { $0.date > $1.date }
            .prefix(configuration.maxItems)
            .map { entry in
                LiveFolderItem(
                    id: entry.id,
                    title: entry.title,
                    url: entry.url,
                    subtitle: parsed.title ?? configuration.feedURL.host(),
                    date: entry.date
                )
            }

        return .items(Array(items))
    }
}

// MARK: - Parsing

/// The feed shape both formats reduce to.
struct ParsedFeed: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        var id: String
        var title: String
        var url: URL
        var date: Date
    }

    var title: String?
    var entries: [Entry]
}

/// `XMLParser` over a feed, tolerant of the two formats and hostile to
/// everything else.
///
/// An entry with no usable link, or no date, is dropped rather than defaulted.
/// A missing date defaulted to "now" would sort a broken entry to the top of
/// the folder forever, and a missing link would produce a tab pointing nowhere.
/// Schemes are allow-listed to http and https, which is what stops a feed from
/// opening `javascript:`, `data:` or `file:` in a browser tab -- the feed is
/// untrusted input that the browser turns directly into navigation, so this is
/// a security boundary and not a tidiness rule.
enum FeedParser {
    static func parse(_ text: String) -> ParsedFeed? {
        guard let data = text.data(using: .utf8) else { return nil }
        let delegate = FeedParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse() || !delegate.entries.isEmpty else { return nil }
        guard !delegate.sawUnknownRoot else { return nil }
        return ParsedFeed(title: delegate.feedTitle, entries: delegate.entries)
    }

    static func isNavigable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}

/// Not `Sendable` and deliberately not shared: one is created, driven and
/// discarded inside a single synchronous `parse` call, so it never crosses an
/// isolation boundary.
private final class FeedParserDelegate: NSObject, XMLParserDelegate {
    private(set) var feedTitle: String?
    private(set) var entries: [ParsedFeed.Entry] = []
    private(set) var sawUnknownRoot = false

    private var path: [String] = []
    private var text = ""

    private var inEntry = false
    private var entryTitle = ""
    private var entryID: String?
    private var entryLink: String?
    private var entryDate: Date?
    private var sawRoot = false

    private static let entryElements: Set<String> = ["item", "entry"]

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = elementName.lowercased()
        if !sawRoot {
            sawRoot = true
            if name != "rss" && name != "feed" && name != "rdf:rdf" { sawUnknownRoot = true }
        }
        path.append(name)
        text = ""

        if Self.entryElements.contains(name) {
            inEntry = true
            entryTitle = ""
            entryID = nil
            entryLink = nil
            entryDate = nil
        }

        // Atom puts the address in an attribute, and a feed may carry several
        // links: the alternate one is the human page, which is the only one a
        // tab should open.
        if inEntry, name == "link", let href = attributeDict["href"] {
            let relation = attributeDict["rel"]?.lowercased() ?? "alternate"
            if relation == "alternate" && entryLink == nil { entryLink = href }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = elementName.lowercased()
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer {
            if !path.isEmpty { path.removeLast() }
            text = ""
        }

        if Self.entryElements.contains(name) {
            finishEntry()
            inEntry = false
            return
        }

        guard inEntry else {
            // The feed's own title, which is the one element outside an entry
            // worth keeping. Guarded on depth so a channel image's title does
            // not overwrite it.
            if name == "title", feedTitle == nil, path.count <= 3, !value.isEmpty {
                feedTitle = value
            }
            return
        }

        switch name {
        case "title":
            if entryTitle.isEmpty { entryTitle = value }
        case "link":
            if entryLink == nil, !value.isEmpty { entryLink = value }
        case "guid", "id":
            if entryID == nil, !value.isEmpty { entryID = value }
        case "pubdate", "published", "updated", "dc:date":
            if entryDate == nil { entryDate = FeedDate.parse(value) }
        default:
            break
        }
    }

    private func finishEntry() {
        guard let link = entryLink,
              let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              FeedParser.isNavigable(url),
              let date = entryDate
        else { return }

        let title = entryTitle.isEmpty ? (url.host() ?? link) : entryTitle
        entries.append(
            ParsedFeed.Entry(
                // The link is the identity when the feed gives none: it is what
                // the tab points at, so two entries sharing one are the same
                // entry as far as a folder of tabs is concerned.
                id: entryID ?? url.absoluteString,
                title: title,
                url: url,
                date: date
            )
        )
    }
}

/// Feed dates, in the two formats feeds actually use plus the variations they
/// get wrong.
enum FeedDate {
    static func parse(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]
        if let date = isoPlain.date(from: trimmed) { return date }

        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFractional.date(from: trimmed) { return date }

        for format in rfc822Formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    /// RFC 822 as feeds write it: with and without the weekday, with a named
    /// zone or a numeric offset.
    private static let rfc822Formats = [
        "EEE, dd MMM yyyy HH:mm:ss Z",
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "dd MMM yyyy HH:mm:ss Z",
        "EEE, dd MMM yyyy HH:mm Z",
        "yyyy-MM-dd'T'HH:mm:ssZ",
        "yyyy-MM-dd"
    ]
}
