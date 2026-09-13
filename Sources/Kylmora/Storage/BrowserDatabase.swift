import Foundation

struct HistoryEntry: Sendable, Equatable {
    let url: URL
    let title: String
    /// The address as the omnibox shows it, which is what prefix matching uses.
    let key: String
    let visitCount: Int
    let lastVisited: Date
}

struct Bookmark: Sendable, Equatable, Identifiable {
    let id: Int64
    let url: URL
    let title: String
    let created: Date
    /// The `/`-joined folder path the bookmark lives under, empty at the top
    /// level. Set when a bookmark is imported from another browser that kept
    /// folders; manually added bookmarks are always top level.
    var folder: String = ""
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

    func recentHistory(limit: Int = 100) throws -> [HistoryEntry] {
        try group(where: "1 = 1", parameters: [.integer(Int64(limit))], orderByRecency: true)
    }

    func clearHistory() throws {
        try database.run("DELETE FROM visits;")
    }

    /// Forgets everything visited before a moment.
    func deleteHistory(before date: Date) throws {
        try database.run("DELETE FROM visits WHERE visited_at < ?;", [.double(date.timeIntervalSince1970)])
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
    func addBookmark(url: URL, title: String, at date: Date = .now) throws {
        try database.run(
            """
            INSERT INTO bookmarks (url, title, created_at, folder) VALUES (?, ?, ?, '')
            ON CONFLICT(url) DO UPDATE SET title = excluded.title;
            """,
            [.text(url.absoluteString), .text(title), .double(date.timeIntervalSince1970)]
        )
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
                    INSERT INTO bookmarks (url, title, created_at, folder) VALUES (?, ?, ?, ?)
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
        try database.query("SELECT id, url, title, created_at, folder FROM bookmarks ORDER BY created_at DESC;") { row in
            Bookmark(
                id: row.integer(0),
                url: URL(string: row.text(1) ?? "") ?? URL(string: "about:blank")!,
                title: row.text(2) ?? "",
                created: Date(timeIntervalSince1970: row.double(3)),
                folder: row.text(4) ?? ""
            )
        }
    }
}
