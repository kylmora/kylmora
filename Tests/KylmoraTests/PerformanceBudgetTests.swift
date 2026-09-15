import AppKit
import Foundation
import Testing
@testable import Kylmora

@Suite("Performance budgets")
@MainActor
struct PerformanceBudgetTests {
    @Test("The lock's idle clock is read a few times per timeout, never every five seconds for an hour")
    func idleInterval() {
        #expect(BrowserLockManager.idleCheckInterval(forTimeout: 60) == 10)
        #expect(BrowserLockManager.idleCheckInterval(forTimeout: 300) == 30)
        #expect(BrowserLockManager.idleCheckInterval(forTimeout: 3600) == 30)
        #expect(BrowserLockManager.idleCheckInterval(forTimeout: 12) == 5)
        #expect(BrowserLockManager.idleCheckInterval(forTimeout: 0) == 30)
    }

    @Test("An unchanged session is not written to disk again")
    func sessionWrites() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "session-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = SessionStore(fileURL: file)
        let snapshot = SessionSnapshot(spaces: [SessionSnapshot.Space(name: "A")], activeSpaceIndex: 0)
        try store.save(snapshot)
        let first = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: file.path)
        try store.save(snapshot)
        let after = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        #expect(after == Date(timeIntervalSince1970: 1000), "the same bytes were not written again")
        try store.save(SessionSnapshot(spaces: [SessionSnapshot.Space(name: "B")], activeSpaceIndex: 0))
        let changed = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        #expect(changed != Date(timeIntervalSince1970: 1000), "a different session is written")
        _ = first
    }

    @Test("Page scripts arrive as one document-start script, and still cover every behaviour")
    func scripts() {
        let starts = SiteBehaviourScripts.all.filter { $0.injectionTime == .atDocumentStart && !$0.isForMainFrameOnly }
        #expect(starts.count == 1)
        for marker in ["kylmoraSite", "geolocation", "readText", "getDisplayMedia"] {
            #expect(SiteBehaviourScripts.documentStart.contains(marker), "\(marker)")
        }
    }
}
