import Foundation
import Testing
@testable import Kylmora

@Suite("Importing history from a browser's database")
struct HistoryImporterTests {
    /// 2020-01-01 00:00:00 UTC, the moment the fixtures time their visits to.
    private let reference = Date(timeIntervalSince1970: 1_577_836_800)

    /// Writes a throwaway SQLite file and hands back its path. The writer is
    /// closed before the path is used, so its data is in the main file where a
    /// read-only, immutable open can see it.
    private func makeDatabase(_ build: (SQLiteDatabase) throws -> Void) throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("kylmora-history-\(UUID().uuidString).sqlite").path
        do {
            let database = try SQLiteDatabase(path: path)
            try build(database)
            try database.execute("PRAGMA wal_checkpoint(TRUNCATE);")
        }
        return path
    }

    @Test("Chrome's urls table is read, its 1601 epoch converted")
    func chrome() throws {
        // 2020-01-01 in microseconds since 1601.
        let chromeTime = Int64((1_577_836_800 + 11_644_473_600) * 1_000_000)
        let path = try makeDatabase { db in
            try db.execute("CREATE TABLE urls (id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, last_visit_time INTEGER);")
            try db.run("INSERT INTO urls (url, title, last_visit_time) VALUES (?, ?, ?);",
                       [.text("https://kept.example/"), .text("Kept"), .integer(chromeTime)])
            // Never actually visited -> skipped.
            try db.run("INSERT INTO urls (url, title, last_visit_time) VALUES (?, ?, ?);",
                       [.text("https://never.example/"), .text("Never"), .integer(0)])
            // Not a web page -> skipped.
            try db.run("INSERT INTO urls (url, title, last_visit_time) VALUES (?, ?, ?);",
                       [.text("chrome://settings"), .text("Settings"), .integer(chromeTime)])
        }
        defer { try? FileManager.default.removeItem(atPath: path) }

        let visits = try HistoryImporter.visits(atPath: path)
        #expect(visits.count == 1)
        let visit = try #require(visits.first)
        #expect(visit.url.absoluteString == "https://kept.example/")
        #expect(visit.title == "Kept")
        #expect(abs(visit.lastVisited.timeIntervalSince(reference)) < 1)
    }

    @Test("Firefox's moz_places table is read, its 1970 epoch kept")
    func firefox() throws {
        let firefoxTime = Int64(1_577_836_800 * 1_000_000)
        let path = try makeDatabase { db in
            try db.execute("CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url TEXT, title TEXT, last_visit_date INTEGER);")
            try db.run("INSERT INTO moz_places (url, title, last_visit_date) VALUES (?, ?, ?);",
                       [.text("https://fox.example/"), .text("Fox"), .integer(firefoxTime)])
            // Bookmarked but never visited -> null date -> skipped.
            try db.run("INSERT INTO moz_places (url, title, last_visit_date) VALUES (?, ?, NULL);",
                       [.text("https://unvisited.example/"), .text("Unvisited")])
        }
        defer { try? FileManager.default.removeItem(atPath: path) }

        let visits = try HistoryImporter.visits(atPath: path)
        #expect(visits.count == 1)
        let visit = try #require(visits.first)
        #expect(visit.url.host() == "fox.example")
        #expect(abs(visit.lastVisited.timeIntervalSince(reference)) < 1)
    }

    @Test("A database of neither shape is not recognised")
    func unrecognised() throws {
        let path = try makeDatabase { db in
            try db.execute("CREATE TABLE something_else (id INTEGER PRIMARY KEY);")
        }
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(throws: HistoryImporter.Failure.unrecognised) {
            try HistoryImporter.visits(atPath: path)
        }
    }

    @Test("A path to nothing is unreadable, not a crash")
    func unreadable() {
        #expect(throws: HistoryImporter.Failure.unreadable) {
            try HistoryImporter.visits(atPath: "/no/such/kylmora/history.sqlite")
        }
    }
}
