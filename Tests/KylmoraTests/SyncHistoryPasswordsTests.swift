import Foundation
import Testing
@testable import Kylmora

@Suite("History and password sync")
struct SyncHistoryPasswordsTests {
    private func archive(history: [SyncVisit]? = nil, credentials: [SyncCredential]? = nil, device: UUID = UUID()) -> SyncArchive {
        var archive = SyncArchive(deviceID: device, session: SessionSnapshot(spaces: [], activeSpaceIndex: 0))
        archive.history = history
        archive.credentials = credentials
        return archive
    }

    private func visit(_ s: String, at seconds: TimeInterval) -> SyncVisit {
        SyncVisit(url: URL(string: s)!, title: s, visitedAt: Date(timeIntervalSince1970: seconds))
    }

    @Test("Visits and logins travel in the archive, and old archives still decode")
    func archiveShape() throws {
        let full = archive(history: [visit("https://a.example/", at: 1000)], credentials: [SyncCredential(host: "a.example", username: "ada", password: "pw")])
        let data = try JSONEncoder().encode(full)
        let back = try JSONDecoder().decode(SyncArchive.self, from: data)
        #expect(back.history?.count == 1)
        #expect(back.credentials?.first?.password == "pw")

        // An archive written before these fields existed has neither.
        var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        json.removeValue(forKey: "history")
        json.removeValue(forKey: "credentials")
        let old = try JSONDecoder().decode(SyncArchive.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.history == nil)
        #expect(old.credentials == nil)

        #expect(full.strippingCredentials().credentials == nil)
        #expect(full.strippingCredentials().history?.count == 1)
    }

    @Test("Merging adds the other device's visits once, newest first, capped")
    func mergeHistory() {
        let local = archive(history: [visit("https://a.example/", at: 1000), visit("https://b.example/", at: 900)])
        let remote = archive(history: [visit("https://a.example/", at: 1000), visit("https://c.example/", at: 1100)])
        let (merged, summary) = SyncMergePolicy.merge(local: local, remote: remote, syncHistory: true)
        #expect(summary.addedVisits == 1)
        #expect(summary.hasChanges)
        #expect(merged.history?.map { $0.url.host() } == ["c.example", "a.example", "b.example"])

        // Off: nothing moves.
        let (untouched, none) = SyncMergePolicy.merge(local: local, remote: remote, syncHistory: false)
        #expect(none.addedVisits == 0)
        #expect(untouched.history?.count == 2)

        // The cap keeps the newest.
        let many = (0..<(SyncArchive.historyLimit + 50)).map { visit("https://n.example/\($0)", at: TimeInterval($0)) }
        let (capped, _) = SyncMergePolicy.merge(local: archive(history: []), remote: archive(history: many), syncHistory: true)
        #expect(capped.history?.count == SyncArchive.historyLimit)
        #expect(capped.history?.first?.visitedAt == many.last?.visitedAt)
    }

    @Test("Merging adds logins this device lacks and keeps its own passwords")
    func mergeCredentials() {
        let mine = SyncCredential(host: "a.example", username: "ada", password: "local")
        let theirs = SyncCredential(host: "a.example", username: "ada", password: "remote")
        let new = SyncCredential(host: "b.example", username: "ada", password: "b")
        let (merged, summary) = SyncMergePolicy.merge(local: archive(credentials: [mine]), remote: archive(credentials: [theirs, new]), syncPasswords: true)
        #expect(summary.addedCredentials == 1)
        #expect(merged.credentials?.count == 2)
        #expect(merged.credentials?.first { $0.host == "a.example" }?.password == "local")

        let (off, none) = SyncMergePolicy.merge(local: archive(credentials: [mine]), remote: archive(credentials: [new]), syncPasswords: false)
        #expect(none.addedCredentials == 0)
        #expect(off.credentials?.count == 1)
    }

    @Test("The database takes visits from elsewhere once, and hands back the newest")
    func databaseMerge() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "sync-history-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: file) }
        let database = try BrowserDatabase(path: file)
        try await database.recordVisit(url: URL(string: "https://here.example/")!, title: "Here", key: "here.example", at: Date(timeIntervalSince1970: 500))

        let visits = [
            visit("https://there.example/", at: 600),
            visit("https://here.example/", at: 500),
            visit("https://there.example/", at: 600)
        ]
        #expect(try await database.mergeVisits(visits) == 1, "one new visit; the duplicate and the one already here are skipped")
        #expect(try await database.mergeVisits(visits) == 0, "syncing again adds nothing")

        let recent = try await database.recentVisits(limit: 10)
        #expect(recent.map { $0.url.host() } == ["there.example", "here.example"])
        #expect(recent.first?.title == "https://there.example/")

        // The merged visit is history like any other: the omnibox can find it.
        let suggestions = try await database.suggestions(matching: "there")
        #expect(suggestions.first?.url.host() == "there.example")
    }

    @Test("The sync switches default to off for history and passwords")
    @MainActor
    func defaults() {
        let settings = Settings(defaults: UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!)
        #expect(!settings.syncHistory)
        #expect(!settings.syncPasswords)
        #expect(settings.syncBookmarks)
        settings.syncHistory = true
        #expect(settings.syncHistory)
    }
}
