import AppKit
import Foundation
import Testing
@testable import Kylmora

private func temporaryFile(_ extension: String) -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "kylmora-test-\(UUID().uuidString).\(`extension`)")
}

@Suite("History and bookmarks on SQLite")
struct BrowserDatabaseTests {
    private func makeDatabase() throws -> (BrowserDatabase, URL) {
        let file = temporaryFile("sqlite")
        return (try BrowserDatabase(path: file), file)
    }

    private func record(_ database: BrowserDatabase, _ key: String, title: String, times: Int = 1) async throws {
        for _ in 0..<times {
            try await database.recordVisit(url: URL(string: "https://\(key)")!, title: title, key: key)
        }
    }

    @Test("Suggestions match on the address prefix")
    func prefixMatching() async throws {
        let (database, file) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: file) }

        try await record(database, "developer.apple.com/documentation", title: "Docs")
        try await record(database, "example.com", title: "Example")

        let matches = try await database.suggestions(matching: "deve")
        #expect(matches.count == 1)
        #expect(matches.first?.title == "Docs")

        #expect(try await database.suggestions(matching: "nothinghere").isEmpty)
    }

    @Test("Matching is case-insensitive")
    func caseInsensitive() async throws {
        let (database, file) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: file) }

        try await database.recordVisit(url: URL(string: "https://Example.com")!, title: "E", key: "Example.com")
        #expect(try await database.suggestions(matching: "EXAM").count == 1)
    }

    @Test("Repeated visits collapse into one ranked suggestion")
    func visitsAreGrouped() async throws {
        let (database, file) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: file) }

        try await record(database, "a.example", title: "A", times: 1)
        try await record(database, "ab.example", title: "AB", times: 5)

        let matches = try await database.suggestions(matching: "a")
        #expect(matches.count == 2)
        // The site visited more often ranks first, even though it is a longer match.
        #expect(matches.first?.key == "ab.example")
        #expect(matches.first?.visitCount == 5)
    }

    @Test("A typed percent sign is not a wildcard")
    func likeWildcardsAreEscaped() async throws {
        let (database, file) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: file) }

        try await record(database, "example.com", title: "Example")
        #expect(try await database.suggestions(matching: "%").isEmpty)
        #expect(try await database.suggestions(matching: "_xample.com").isEmpty)
    }

    @Test("A late title corrects the most recent visit rather than the rest")
    func retitleUpdatesLatestVisit() async throws {
        let (database, file) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: file) }

        // Two visits to the same page recorded with the bare host as title,
        // which is what happens when the load finishes before the page's own
        // title arrives.
        let url = URL(string: "https://example.com/")!
        try await database.recordVisit(url: url, title: "example.com", key: "example.com")
        try await database.recordVisit(url: url, title: "example.com", key: "example.com")

        try await database.updateLatestVisitTitle(url: url, title: "Example Domain")

        // The grouped suggestion carries the corrected title, and only one row
        // was touched.
        let matches = try await database.suggestions(matching: "example")
        #expect(matches.first?.title == "Example Domain")
        #expect(matches.first?.visitCount == 2)
    }

    @Test("Retitling a page that was never visited writes nothing")
    func retitleUnknownIsHarmless() async throws {
        let (database, file) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: file) }

        try await database.updateLatestVisitTitle(url: URL(string: "https://never.example/")!, title: "X")
        #expect(try await database.recentHistory().isEmpty)
    }

    @Test("Clearing history empties it")
    func clearing() async throws {
        let (database, file) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: file) }

        try await record(database, "example.com", title: "Example")
        try await database.clearHistory()
        #expect(try await database.recentHistory().isEmpty)
    }

    @Test("Bookmarking the same address twice updates rather than duplicates")
    func bookmarksAreUnique() async throws {
        let (database, file) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: file) }

        let url = URL(string: "https://example.com")!
        try await database.addBookmark(url: url, title: "First")
        try await database.addBookmark(url: url, title: "Second")

        let bookmarks = try await database.bookmarks()
        #expect(bookmarks.count == 1)
        #expect(bookmarks.first?.title == "Second")

        try await database.removeBookmark(url: url)
        #expect(try await database.bookmarks().isEmpty)
    }

    @Test("A database survives being closed and reopened")
    func persistsAcrossOpens() async throws {
        let file = temporaryFile("sqlite")
        defer { try? FileManager.default.removeItem(at: file) }

        do {
            let database = try BrowserDatabase(path: file)
            try await database.addBookmark(url: URL(string: "https://example.com")!, title: "Example")
        }
        let reopened = try BrowserDatabase(path: file)
        #expect(try await reopened.bookmarks().count == 1)
    }
}

@Suite("Session persistence")
@MainActor
struct SessionPersistenceTests {
    @Test("Spaces, tabs and selection come back after a relaunch")
    func roundTrip() throws {
        let file = temporaryFile("json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = SessionStore(fileURL: file)
        let defaults = UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!

        let first = BrowserSession(database: nil, sessionStore: store, settings: Settings(defaults: defaults))
        first.newTab(url: URL(string: "https://one.example")!)
        let work = first.addSpace(named: "Work")
        first.newTab(url: URL(string: "https://two.example")!)
        first.selectSpace(first.spaces[0])
        first.saveNow()

        let second = BrowserSession(database: nil, sessionStore: store, settings: Settings(defaults: defaults))
        #expect(second.spaces.map(\.name) == ["Personal", "Work"])
        #expect(second.activeSpace.name == "Personal")
        #expect(second.activeSpace.tabs.count == 2)
        #expect(second.spaces[1].tabs.count == 2)
        #expect(second.spaces[1].name == work.name)
        // Restored tabs are still lazy: no web view until they are shown.
        #expect(second.activeSpace.tabs.allSatisfy { !$0.isLoaded })
    }

    @Test("Turning restore off starts a fresh session")
    func restoreDisabled() throws {
        let file = temporaryFile("json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = SessionStore(fileURL: file)
        let defaults = UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!
        let settings = Settings(defaults: defaults)

        let first = BrowserSession(database: nil, sessionStore: store, settings: settings)
        first.addSpace(named: "Work")
        first.saveNow()

        settings.restoresSession = false
        let second = BrowserSession(database: nil, sessionStore: store, settings: settings)
        #expect(second.spaces.count == 1)
        #expect(second.spaces[0].name == "Personal")
    }

    @Test("A corrupt session file is ignored rather than fatal")
    func corruptFile() throws {
        let file = temporaryFile("json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("not json".utf8).write(to: file)

        let defaults = UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!
        let session = BrowserSession(
            database: nil,
            sessionStore: SessionStore(fileURL: file),
            settings: Settings(defaults: defaults)
        )
        #expect(session.spaces.count == 1)
        #expect(session.activeTab != nil)
    }

    @Test("Space tints survive the round trip")
    func tintRoundTrip() {
        let colors = ["#007aff", "#ff3b30", "#000000", "#ffffff"]
        for hex in colors {
            #expect(NSColor(hexString: hex)?.hexString == hex)
        }
        #expect(NSColor(hexString: "nonsense") == nil)
        #expect(NSColor(hexString: "#12345") == nil)
    }
}

@Suite("Settings")
@MainActor
struct SettingsTests {
    private func makeSettings() -> Settings {
        Settings(defaults: UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!)
    }

    @Test("Defaults are DuckDuckGo and session restore on")
    func defaults() {
        let settings = makeSettings()
        #expect(settings.searchEngine == .duckDuckGo)
        #expect(settings.restoresSession)
    }

    @Test("A stored engine is read back, and an unknown one falls back")
    func engineRoundTrip() {
        let settings = makeSettings()
        settings.searchEngine = .google
        #expect(settings.searchEngine == .google)
        settings.newTabTarget = .startPage
        #expect(settings.newTabURL == SearchEngine.google.homeURL)

        UserDefaults.standard.removeObject(forKey: "searchEngineIdentifier")
        #expect(SearchEngine.named("nope") == nil)
    }
}
