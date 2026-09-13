import Foundation

/// Reads the browsing history other browsers keep in a SQLite file.
///
/// Two schemas cover the field: Chrome and the other Chromium browsers keep an
/// `urls` table timed in microseconds since 1601; Firefox keeps `moz_places`
/// timed in microseconds since 1970. Safari's history is inside its sandbox
/// container, which macOS protects, so it is not reachable here.
///
/// The file is opened read-only and immutable (`SQLiteDatabase.init(readingOnly:)`)
/// so a running browser's lock never blocks the read and its file is never
/// touched. The file is one the user picked in an open panel, as with bookmarks.
enum HistoryImporter {
    struct Visit: Sendable, Equatable {
        let url: URL
        let title: String
        let lastVisited: Date
    }

    enum Failure: Error, Equatable {
        case unreadable
        case unrecognised
    }

    /// The offset between the 1601 epoch Chromium counts from and the 1970 one
    /// Foundation uses, in seconds.
    private static let chromeEpochOffset: Double = 11_644_473_600

    /// A sane cap: a history import is a convenience, not an archive, and tens
    /// of thousands of the most recent pages is already more than the omnibox
    /// will ever surface.
    static func visits(atPath path: String, limit: Int = 20_000) throws -> [Visit] {
        guard FileManager.default.fileExists(atPath: path) else { throw Failure.unreadable }
        let database: SQLiteDatabase
        do {
            database = try SQLiteDatabase(readingOnly: path)
        } catch {
            throw Failure.unreadable
        }
        let tables = Set((try? database.query("SELECT name FROM sqlite_master WHERE type = 'table';") { $0.text(0) ?? "" }) ?? [])
        if tables.contains("urls") {
            return chromeVisits(database, limit: limit)
        }
        if tables.contains("moz_places") {
            return firefoxVisits(database, limit: limit)
        }
        throw Failure.unrecognised
    }

    /// Chrome's `urls`: one row per page, `last_visit_time` microseconds since
    /// 1601. Rows never actually visited carry a zero time and are skipped.
    static func chromeVisits(_ database: SQLiteDatabase, limit: Int) -> [Visit] {
        let rows = (try? database.query(
            "SELECT url, title, last_visit_time FROM urls WHERE last_visit_time > 0 ORDER BY last_visit_time DESC LIMIT ?;",
            [.integer(Int64(limit))]
        ) { row in
            (url: row.text(0) ?? "", title: row.text(1) ?? "", time: row.double(2))
        }) ?? []
        return rows.compactMap { row in
            visit(urlString: row.url, title: row.title, seconds: row.time / 1_000_000 - chromeEpochOffset)
        }
    }

    /// Firefox's `moz_places`: `last_visit_date` microseconds since 1970, null
    /// for pages only bookmarked and never visited.
    static func firefoxVisits(_ database: SQLiteDatabase, limit: Int) -> [Visit] {
        let rows = (try? database.query(
            "SELECT url, title, last_visit_date FROM moz_places WHERE last_visit_date IS NOT NULL ORDER BY last_visit_date DESC LIMIT ?;",
            [.integer(Int64(limit))]
        ) { row in
            (url: row.text(0) ?? "", title: row.text(1) ?? "", time: row.double(2))
        }) ?? []
        return rows.compactMap { row in
            visit(urlString: row.url, title: row.title, seconds: row.time / 1_000_000)
        }
    }

    /// Builds a visit, keeping only web pages with a believable timestamp.
    private static func visit(urlString: String, title: String, seconds: Double) -> Visit? {
        guard let url = URL(string: urlString), url.scheme == "http" || url.scheme == "https" else { return nil }
        // Guard against a garbage time that would land the page in 1601 or the
        // far future; a plausible visit is between 1990 and a day from now.
        guard seconds > 631_152_000, seconds < Date().timeIntervalSince1970 + 86_400 else { return nil }
        return Visit(url: url, title: title, lastVisited: Date(timeIntervalSince1970: seconds))
    }
}
