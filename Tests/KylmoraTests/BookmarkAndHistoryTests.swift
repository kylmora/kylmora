import AppKit
import Foundation
import Testing
@testable import Kylmora

@Suite("Bookmark Tags, Search, Duplicate Cleanup & Full-Text History (F-22)")
struct BookmarkAndHistoryTests {

    private func makeTemporaryDatabase() throws -> (BrowserDatabase, URL) {
        let tempDir = FileManager.default.temporaryDirectory
        let dbURL = tempDir.appendingPathComponent("test-browser-\(UUID().uuidString).sqlite")
        let db = try BrowserDatabase(path: dbURL)
        return (db, dbURL)
    }

    @Test("Bookmark tags can be added, updated, listed, and queried")
    func testBookmarkTags() async throws {
        let (db, dbURL) = try makeTemporaryDatabase()
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let url1 = URL(string: "https://apple.com/swift")!
        let url2 = URL(string: "https://news.ycombinator.com")!

        try await db.addBookmark(url: url1, title: "Swift Programming", folder: "Dev", tags: ["swift", "apple"])
        try await db.addBookmark(url: url2, title: "Hacker News", folder: "", tags: ["news", "tech"])

        let allTags = try await db.allBookmarkTags()
        #expect(allTags.contains("swift"))
        #expect(allTags.contains("apple"))
        #expect(allTags.contains("news"))
        #expect(allTags.contains("tech"))

        // Add tag
        try await db.addBookmarkTag("compiler", to: url1)
        let tagsAfterAdd = try await db.bookmarks().first { $0.url == url1 }?.tags ?? []
        #expect(tagsAfterAdd.contains("compiler"))
        #expect(tagsAfterAdd.contains("swift"))

        // Remove tag
        try await db.removeBookmarkTag("apple", from: url1)
        let tagsAfterRemove = try await db.bookmarks().first { $0.url == url1 }?.tags ?? []
        #expect(!tagsAfterRemove.contains("apple"))
        #expect(tagsAfterRemove.contains("swift"))
    }

    @Test("Bookmarks can be searched by text query and filtered by tag")
    func testSearchBookmarks() async throws {
        let (db, dbURL) = try makeTemporaryDatabase()
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let url1 = URL(string: "https://github.com/apple/swift")!
        let url2 = URL(string: "https://rust-lang.org")!
        let url3 = URL(string: "https://golang.org")!

        try await db.addBookmark(url: url1, title: "Swift Repo", folder: "OpenSource", tags: ["swift", "systems"])
        try await db.addBookmark(url: url2, title: "Rust Language", folder: "OpenSource", tags: ["rust", "systems"])
        try await db.addBookmark(url: url3, title: "Go Language", folder: "Backend", tags: ["go", "web"])

        // Query by title
        let rustResults = try await db.searchBookmarks(query: "Rust")
        #expect(rustResults.count == 1)
        #expect(rustResults.first?.url == url2)

        // Filter by tag
        let systemsResults = try await db.searchBookmarks(query: "", tag: "systems")
        #expect(systemsResults.count == 2)

        // Query within tag
        let swiftInSystems = try await db.searchBookmarks(query: "Swift", tag: "systems")
        #expect(swiftInSystems.count == 1)
        #expect(swiftInSystems.first?.url == url1)

        // Search by folder name
        let folderResults = try await db.searchBookmarks(query: "Backend")
        #expect(folderResults.count == 1)
        #expect(folderResults.first?.url == url3)
    }

    @Test("Duplicate bookmarks are detected across trailing slashes, schemes, and tracking query params")
    func testCanonicalURLAndDuplicateDetection() async throws {
        let urlA = URL(string: "https://example.com/article")!
        let urlB = URL(string: "https://example.com/article/?utm_source=twitter&utm_medium=social")!
        let urlC = URL(string: "http://example.com/article")!

        let keyA = BrowserDatabase.canonicalBookmarkKey(for: urlA)
        let keyB = BrowserDatabase.canonicalBookmarkKey(for: urlB)
        let keyC = BrowserDatabase.canonicalBookmarkKey(for: urlC)

        #expect(keyA == "https://example.com/article")
        #expect(keyB == "https://example.com/article")
        #expect(keyC == "http://example.com/article")
    }

    @Test("cleanupDuplicateBookmarks consolidates duplicates and merges tags")
    func testDuplicateCleanup() async throws {
        let (db, dbURL) = try makeTemporaryDatabase()
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let url1 = URL(string: "https://kylmora.org/docs")!
        let url2 = URL(string: "https://kylmora.org/docs/?utm_source=newsletter")!

        try await db.addBookmark(url: url1, title: "Kylmora Docs", folder: "Browsers", tags: ["browser"])
        try await db.addBookmark(url: url2, title: "Kylmora Documentation", folder: "", tags: ["docs", "mac"])

        let duplicates = try await db.findDuplicateBookmarks()
        #expect(duplicates.count == 1)
        #expect(duplicates[0].count == 2)

        let removedCount = try await db.cleanupDuplicateBookmarks()
        #expect(removedCount == 1)

        let remaining = try await db.bookmarks()
        #expect(remaining.count == 1)
        let keeper = remaining[0]
        #expect(keeper.folder == "Browsers")
        #expect(keeper.tags.contains("browser"))
        #expect(keeper.tags.contains("docs"))
        #expect(keeper.tags.contains("mac"))

        // Re-running cleanup finds nothing
        let removedAgain = try await db.cleanupDuplicateBookmarks()
        #expect(removedAgain == 0)
    }

    @Test("Full-text history indexing and search with SQLite FTS5")
    func testFullTextHistorySearch() async throws {
        let (db, dbURL) = try makeTemporaryDatabase()
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let page1 = URL(string: "https://example.com/physics")!
        let page2 = URL(string: "https://example.com/biology")!

        try await db.indexVisitContent(
            url: page1,
            title: "Quantum Mechanics & Superconductors",
            content: "Quantum entanglement and topological superconductors exhibit anomalous thermoelectric effects."
        )

        try await db.indexVisitContent(
            url: page2,
            title: "Cellular Mitosis",
            content: "Cell division and chromosome segregation during eukaryotic mitosis."
        )

        // Search full text by body keyword
        let quantumMatches = try await db.searchHistoryFullText(query: "superconductors")
        #expect(quantumMatches.count == 1)
        #expect(quantumMatches.first?.url == page1)
        #expect(quantumMatches.first?.snippet.contains("superconductors") == true)

        let mitosisMatches = try await db.searchHistoryFullText(query: "mitosis")
        #expect(mitosisMatches.count == 1)
        #expect(mitosisMatches.first?.url == page2)

        // Clear history also purges FTS
        try await db.clearHistory()
        let clearedMatches = try await db.searchHistoryFullText(query: "superconductors")
        #expect(clearedMatches.isEmpty)
    }

    @Test("CommandCatalog and ShortcutManager include bookmarks & history search commands")
    @MainActor
    func testCommandsAndShortcuts() {
        let catalog = CommandCatalog.all

        #expect(catalog.contains { $0.id == "search-bookmarks" })
        #expect(catalog.contains { $0.id == "cleanup-duplicate-bookmarks" })
        #expect(catalog.contains { $0.id == "search-history-full-text" })

        let sm = ShortcutManager()
        #expect(sm.definition(for: "search-bookmarks") != nil)
        #expect(sm.definition(for: "search-history-full-text") != nil)
    }
}
