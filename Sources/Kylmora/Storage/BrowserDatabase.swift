import Foundation

struct HistoryEntry: Sendable, Equatable {
    let url: URL
    let title: String
    /// The address as the omnibox shows it, which is what prefix matching uses.
    let key: String
    let visitCount: Int
    let lastVisited: Date
}

struct Bookmark: Sendable, Equatable, Identifiable, Codable {
    let id: Int64
    let url: URL
    let title: String
    let created: Date
    /// The `/`-joined folder path the bookmark lives under, empty at the top
    /// level. Set when a bookmark is imported from another browser that kept
    /// folders; manually added bookmarks are always top level.
    var folder: String = ""
    /// User-assigned tags for categorization and search.
    var tags: [String] = []

    init(id: Int64 = 0, url: URL, title: String, created: Date = Date(), folder: String = "", tags: [String] = []) {
        self.id = id
        self.url = url
        self.title = title
        self.created = created
        self.folder = folder
        self.tags = tags
    }
}

struct FullTextHistoryResult: Sendable, Equatable, Identifiable {
    var id: String { url.absoluteString + "::" + String(rank) }
    let url: URL
    let title: String
    let snippet: String
    let rank: Double
    let lastVisited: Date?
}

/// History and bookmarks, on SQLite.
///
/// An actor rather than a lock: the SQLite handle lives in actor state, so every
/// query is serialised by the language and no page visit can block the main
/// thread while it is written.
actor BrowserDatabase {
    private let database: SQLiteDatabase

    init(path: URL) throws {
        database = try SQLiteDatabase(path: path.path(percentEncoded: false))
        try Self.migrate(database)
    }

    private static func migrate(_ database: SQLiteDatabase) throws {
        try database.execute("""
            CREATE TABLE IF NOT EXISTS visits (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                url        TEXT NOT NULL,
                key        TEXT NOT NULL,
                title      TEXT NOT NULL DEFAULT '',
                visited_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS visits_key  ON visits(key);
            CREATE INDEX IF NOT EXISTS visits_time ON visits(visited_at DESC);

            CREATE TABLE IF NOT EXISTS bookmarks (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                url        TEXT NOT NULL UNIQUE,
                title      TEXT NOT NULL DEFAULT '',
                created_at REAL NOT NULL,
                folder     TEXT NOT NULL DEFAULT ''
            );
            """)
        // Databases made before folders existed have the table but not the
        // column; add it in place rather than lose the bookmarks by recreating.
        if try !columnExists("folder", in: "bookmarks", database) {
            try database.execute("ALTER TABLE bookmarks ADD COLUMN folder TEXT NOT NULL DEFAULT '';")
        }
        if try !columnExists("tags", in: "bookmarks", database) {
            try database.execute("ALTER TABLE bookmarks ADD COLUMN tags TEXT NOT NULL DEFAULT '';")
        }

        // FTS5 Full-Text Search index over page history
        try database.execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS history_fts USING fts5(
                url UNINDEXED,
                title,
                content,
                tokenize = 'porter unicode61'
            );
            """)
    }

    /// Whether `table` already has `column`, read from SQLite's own catalogue.
    /// The table name is a fixed literal here, never user input.
    private static func columnExists(_ column: String, in table: String, _ database: SQLiteDatabase) throws -> Bool {
        try database.query("PRAGMA table_info(\(table));") { $0.text(1) }.contains(column)
    }

    // MARK: - History

    func recordVisit(url: URL, title: String, key: String, at date: Date = .now) throws {
        try database.run(
            "INSERT INTO visits (url, key, title, visited_at) VALUES (?, ?, ?, ?);",
            [.text(url.absoluteString), .text(key.lowercased()), .text(title), .double(date.timeIntervalSince1970)]
        )
    }

    /// History read from another browser, in one transaction. Each page becomes
    /// a single visit at the time it was last seen there; the omnibox groups by
    /// key at read time, so a page visited before keeps ranking by how often it
    /// is opened in Kylmora from here on. Returns how many rows were written.
    @discardableResult
    func importVisits(_ items: [(url: URL, title: String, key: String, date: Date)]) throws -> Int {
        guard !items.isEmpty else { return 0 }
        try database.execute("BEGIN;")
        do {
            for item in items {
                try database.run(
                    "INSERT INTO visits (url, key, title, visited_at) VALUES (?, ?, ?, ?);",
                    [.text(item.url.absoluteString), .text(item.key.lowercased()),
                     .text(item.title), .double(item.date.timeIntervalSince1970)]
                )
            }
            try database.execute("COMMIT;")
        } catch {
            try? database.execute("ROLLBACK;")
            throw error
        }
        return items.count
    }

    /// The newest visits, one row each, for sync.
    func recentVisits(limit: Int) throws -> [SyncVisit] {
        try database.query(
            "SELECT url, title, visited_at FROM visits ORDER BY visited_at DESC LIMIT ?;",
            [.integer(Int64(limit))]
        ) { row in
            guard let text = row.text(0), let url = URL(string: text) else { return nil }
            return SyncVisit(url: url, title: row.text(1) ?? "", visitedAt: Date(timeIntervalSince1970: row.double(2)))
        }.compactMap { $0 }
    }

    /// Visits from another device. One that is already here, same page at
    /// the same second, is skipped, so syncing twice adds nothing twice.
    /// Returns how many were new.
    @discardableResult
    func mergeVisits(_ visits: [SyncVisit]) throws -> Int {
        guard !visits.isEmpty else { return 0 }
        var added = 0
        try database.execute("BEGIN;")
        do {
            for visit in visits {
                let stamp = visit.visitedAt.timeIntervalSince1970
                let existing = try database.query(
                    "SELECT COUNT(*) FROM visits WHERE url = ? AND ABS(visited_at - ?) < 1;",
                    [.text(visit.url.absoluteString), .double(stamp)]
                ) { $0.integer(0) }.first ?? 0
                if existing > 0 { continue }
                try database.run(
                    "INSERT INTO visits (url, key, title, visited_at) VALUES (?, ?, ?, ?);",
                    [.text(visit.url.absoluteString), .text(AddressFormatter.display(visit.url).lowercased()),
                     .text(visit.title), .double(stamp)]
                )
                added += 1
            }
            try database.execute("COMMIT;")
        } catch {
            try? database.execute("ROLLBACK;")
            throw error
        }
        return added
    }

    /// Corrects the title of the most recent visit to `url`. A page's title
    /// commonly arrives after the load that recorded the visit, which would
    /// otherwise carry the host as its title for good.
    func updateLatestVisitTitle(url: URL, title: String) throws {
        try database.run(
            """
            UPDATE visits SET title = ?
            WHERE id = (SELECT id FROM visits WHERE url = ? ORDER BY visited_at DESC LIMIT 1);
            """,
            [.text(title), .text(url.absoluteString)]
        )
    }

    /// Prefix match on the displayed address, ranked by how often and how
    /// recently the page was visited. That ordering is what makes one or two
    /// typed characters land on the right site.
    func suggestions(matching prefix: String, limit: Int = 8) throws -> [HistoryEntry] {
        let needle = prefix.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        return try group(
            where: "key LIKE ? ESCAPE '\\'",
            parameters: [.text(escapeLike(needle) + "%"), .integer(Int64(limit))]
        )
    }

    /// The most visited pages, one per address, for the start page.
    func topSites(limit: Int = 8) throws -> [HistoryEntry] {
        try group(where: "1 = 1", parameters: [.integer(Int64(limit))])
    }

    func recentHistory(limit: Int = 100) throws -> [HistoryEntry] {
        try group(where: "1 = 1", parameters: [.integer(Int64(limit))], orderByRecency: true)
    }

    func clearHistory() throws {
        try database.run("DELETE FROM visits;")
        try? database.run("DELETE FROM history_fts;")
    }

    /// Forgets everything visited before a moment.
    func deleteHistory(before date: Date) throws {
        try database.run("DELETE FROM visits WHERE visited_at < ?;", [.double(date.timeIntervalSince1970)])
        try? database.run("DELETE FROM history_fts WHERE url NOT IN (SELECT url FROM visits);")
    }

    /// Indexes page text content for on-device full-text search.
    func indexVisitContent(url: URL, title: String, content: String) throws {
        let clean = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let capped = clean.count > 65536 ? String(clean.prefix(65536)) : clean
        try database.run("DELETE FROM history_fts WHERE url = ?;", [.text(url.absoluteString)])
        try database.run(
            "INSERT INTO history_fts (url, title, content) VALUES (?, ?, ?);",
            [.text(url.absoluteString), .text(title), .text(capped)]
        )
    }

    /// Searches visited pages by full-text content using SQLite FTS5.
    func searchHistoryFullText(query: String, limit: Int = 50) throws -> [FullTextHistoryResult] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return [] }

        let sanitized = clean
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !sanitized.isEmpty else { return [] }

        let matchExpr = sanitized.split(separator: " ").map { "\($0)*" }.joined(separator: " ")
        let sql = """
            SELECT url, title, snippet(history_fts, 2, '<mark>', '</mark>', '…', 24) AS snip, rank
            FROM history_fts
            WHERE history_fts MATCH ?
            ORDER BY rank
            LIMIT ?;
            """
        return try database.query(sql, [.text(matchExpr), .integer(Int64(limit))]) { row in
            FullTextHistoryResult(
                url: URL(string: row.text(0) ?? "") ?? URL(string: "about:blank")!,
                title: row.text(1) ?? "",
                snippet: row.text(2) ?? "",
                rank: row.double(3),
                lastVisited: nil
            )
        }
    }

    private func group(
        where condition: String,
        parameters: [SQLiteDatabase.Value],
        orderByRecency: Bool = false
    ) throws -> [HistoryEntry] {
        let order = orderByRecency ? "last_visit DESC" : "visit_count DESC, last_visit DESC"
        let sql = """
            SELECT url, key, title, COUNT(*) AS visit_count, MAX(visited_at) AS last_visit
            FROM visits
            WHERE \(condition)
            GROUP BY key
            ORDER BY \(order)
            LIMIT ?;
            """
        return try database.query(sql, parameters) { row in
            HistoryEntry(
                url: URL(string: row.text(0) ?? "") ?? URL(string: "about:blank")!,
                title: row.text(2) ?? "",
                key: row.text(1) ?? "",
                visitCount: Int(row.integer(3)),
                lastVisited: Date(timeIntervalSince1970: row.double(4))
            )
        }
    }

    /// `LIKE` treats `%` and `_` as wildcards, so a typed one must be escaped or
    /// "100%" would match everything.
    private nonisolated func escapeLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    // MARK: - Bookmarks

    /// A manually made bookmark, always at the top level. A page bookmarked
    /// again keeps whatever folder it already had (an import may have filed it),
    /// so re-bookmarking never quietly moves it to the root.
    func addBookmark(url: URL, title: String, folder: String = "", tags: [String] = [], at date: Date = .now) throws {
        let tagString = tags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ", ")
        try database.run(
            """
            INSERT INTO bookmarks (url, title, created_at, folder, tags) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(url) DO UPDATE SET title = excluded.title,
                                           folder = CASE WHEN excluded.folder != '' THEN excluded.folder ELSE bookmarks.folder END,
                                           tags = CASE WHEN excluded.tags != '' THEN excluded.tags ELSE bookmarks.tags END;
            """,
            [.text(url.absoluteString), .text(title), .double(date.timeIntervalSince1970), .text(folder), .text(tagString)]
        )
    }

    /// Updates existing bookmark attributes (folder, tags, title).
    func updateBookmark(url: URL, title: String? = nil, folder: String? = nil, tags: [String]? = nil) throws {
        if let title {
            try database.run("UPDATE bookmarks SET title = ? WHERE url = ?;", [.text(title), .text(url.absoluteString)])
        }
        if let folder {
            try database.run("UPDATE bookmarks SET folder = ? WHERE url = ?;", [.text(folder), .text(url.absoluteString)])
        }
        if let tags {
            try setBookmarkTags(tags, for: url)
        }
    }

    func setBookmarkTags(_ tags: [String], for url: URL) throws {
        let tagString = tags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ", ")
        try database.run("UPDATE bookmarks SET tags = ? WHERE url = ?;", [.text(tagString), .text(url.absoluteString)])
    }

    func addBookmarkTag(_ tag: String, to url: URL) throws {
        let clean = tag.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        let current = try bookmarks().first { $0.url == url }?.tags ?? []
        if !current.contains(clean) {
            try setBookmarkTags(current + [clean], for: url)
        }
    }

    func removeBookmarkTag(_ tag: String, from url: URL) throws {
        let clean = tag.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        let current = try bookmarks().first { $0.url == url }?.tags ?? []
        let updated = current.filter { $0 != clean }
        try setBookmarkTags(updated, for: url)
    }

    func allBookmarkTags() throws -> [String] {
        let all = try bookmarks().flatMap(\.tags)
        return Array(Set(all)).sorted()
    }

    func searchBookmarks(query: String, tag: String? = nil) throws -> [Bookmark] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let tagFilter = tag?.trimmingCharacters(in: .whitespaces).lowercased()
        var all = try bookmarks()

        if let tagFilter, !tagFilter.isEmpty {
            all = all.filter { bm in bm.tags.contains { $0.lowercased() == tagFilter } }
        }

        guard !needle.isEmpty else { return all }

        return all.filter { bm in
            bm.title.localizedCaseInsensitiveContains(needle) ||
            bm.url.absoluteString.localizedCaseInsensitiveContains(needle) ||
            bm.folder.localizedCaseInsensitiveContains(needle) ||
            bm.tags.contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    /// Strips tracking parameters, trailing slashes, default ports and fragments for canonical comparison.
    static func canonicalBookmarkKey(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return url.absoluteString.lowercased()
        }
        components.host = components.host?.lowercased()
        if components.port == 80 || components.port == 443 {
            components.port = nil
        }
        if let path = components.path as String?, path.hasSuffix("/") && path.count > 1 {
            components.path = String(path.dropLast())
        }
        let trackingKeys: Set<String> = [
            "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
            "ref", "fbclid", "gclid", "msclkid", "mc_cid", "mc_eid"
        ]
        if let queryItems = components.queryItems {
            let filtered = queryItems.filter { !trackingKeys.contains($0.name.lowercased()) }
            components.queryItems = filtered.isEmpty ? nil : filtered
        }
        components.fragment = nil
        return components.string?.lowercased() ?? url.absoluteString.lowercased()
    }

    /// Groups bookmarks sharing the same canonical target URL.
    func findDuplicateBookmarks() throws -> [[Bookmark]] {
        let all = try bookmarks()
        var grouped: [String: [Bookmark]] = [:]
        for bm in all {
            let key = Self.canonicalBookmarkKey(for: bm.url)
            grouped[key, default: []].append(bm)
        }
        return grouped.values.filter { $0.count > 1 }.sorted { $0[0].title < $1[0].title }
    }

    /// Consolidates duplicate bookmarks: keeps the most tagged/folder-organized bookmark,
    /// merges all tags from duplicates, and removes redundant copies.
    @discardableResult
    func cleanupDuplicateBookmarks() throws -> Int {
        let duplicates = try findDuplicateBookmarks()
        var removedCount = 0

        for group in duplicates {
            guard group.count > 1 else { continue }
            let sorted = group.sorted { a, b in
                if (!a.folder.isEmpty) != (!b.folder.isEmpty) {
                    return !a.folder.isEmpty
                }
                if a.tags.count != b.tags.count {
                    return a.tags.count > b.tags.count
                }
                return a.created < b.created
            }

            let keeper = sorted[0]
            let toRemove = sorted.dropFirst()

            // If keeper has no folder but any duplicate did, adopt that folder
            if keeper.folder.isEmpty, let bestFolder = group.first(where: { !$0.folder.isEmpty })?.folder {
                try updateBookmark(url: keeper.url, folder: bestFolder)
            }

            let mergedTags = Array(Set(group.flatMap(\.tags))).sorted()
            if mergedTags != keeper.tags {
                try setBookmarkTags(mergedTags, for: keeper.url)
            }

            for dup in toRemove {
                try removeBookmark(url: dup.url)
                removedCount += 1
            }
        }

        return removedCount
    }

    /// Bookmarks read from another browser, in one transaction so a few
    /// thousand do not mean a few thousand separate writes. Unlike a manual
    /// add, a re-import updates the folder too, so the tree follows the source.
    /// Returns how many rows were written.
    @discardableResult
    func importBookmarks(_ items: [(url: URL, title: String, folder: String, date: Date)]) throws -> Int {
        guard !items.isEmpty else { return 0 }
        try database.execute("BEGIN;")
        do {
            for item in items {
                try database.run(
                    """
                    INSERT INTO bookmarks (url, title, created_at, folder, tags) VALUES (?, ?, ?, ?, '')
                    ON CONFLICT(url) DO UPDATE SET title = excluded.title, folder = excluded.folder;
                    """,
                    [.text(item.url.absoluteString), .text(item.title),
                     .double(item.date.timeIntervalSince1970), .text(item.folder)]
                )
            }
            try database.execute("COMMIT;")
        } catch {
            try? database.execute("ROLLBACK;")
            throw error
        }
        return items.count
    }

    func removeBookmark(url: URL) throws {
        try database.run("DELETE FROM bookmarks WHERE url = ?;", [.text(url.absoluteString)])
    }

    func bookmarks() throws -> [Bookmark] {
        try database.query("SELECT id, url, title, created_at, folder, tags FROM bookmarks ORDER BY created_at DESC;") { row in
            let tagsRaw = row.text(5) ?? ""
            let tags = tagsRaw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return Bookmark(
                id: row.integer(0),
                url: URL(string: row.text(1) ?? "") ?? URL(string: "about:blank")!,
                title: row.text(2) ?? "",
                created: Date(timeIntervalSince1970: row.double(3)),
                folder: row.text(4) ?? "",
                tags: tags
            )
        }
    }
}
