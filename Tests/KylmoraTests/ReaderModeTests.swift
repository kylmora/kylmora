import AppKit
import Foundation
import Testing
import WebKit
@testable import Kylmora

private final class TestBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

@Suite("Reader Mode, Speech & Reading List (F-21)")
@MainActor
struct ReaderModeTests {

    @Test("ReadingListStore adds, retrieves, and checks containment")
    func testReadingListStoreAddAndRetrieve() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("reading-list-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let store = ReadingListStore(fileURL: tempURL)
        #expect(store.items.isEmpty)
        #expect(store.unreadCount == 0)

        let testURL = URL(string: "https://example.com/article1")!
        _ = store.add(url: testURL, title: "Article One", previewText: "Snippet of article...")

        #expect(store.items.count == 1)
        #expect(store.contains(url: testURL))
        #expect(store.unreadCount == 1)
        #expect(store.items.first?.title == "Article One")
        #expect(store.items.first?.previewText == "Snippet of article...")
        #expect(store.items.first?.isRead == false)

        // Updating same URL updates title and preview without duplicating
        let updated = store.add(url: testURL, title: "Article One Updated", previewText: "New snippet")
        #expect(store.items.count == 1)
        #expect(updated.title == "Article One Updated")
        #expect(updated.previewText == "New snippet")
    }

    @Test("ReadingListStore toggles read status and filters unread articles")
    func testReadingListStoreToggleReadAndFilter() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("reading-list-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let store = ReadingListStore(fileURL: tempURL)
        let item1 = store.add(url: URL(string: "https://example.com/1")!, title: "One")
        let item2 = store.add(url: URL(string: "https://example.com/2")!, title: "Two")

        #expect(store.unreadCount == 2)
        #expect(store.unreadItems.count == 2)

        store.toggleRead(id: item1.id)
        #expect(store.unreadCount == 1)
        #expect(store.unreadItems.first?.id == item2.id)

        store.markAllRead()
        #expect(store.unreadCount == 0)
        #expect(store.unreadItems.isEmpty)
    }

    @Test("ReadingListStore removes item and clears all")
    func testReadingListStoreRemoveAndClear() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("reading-list-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let store = ReadingListStore(fileURL: tempURL)
        let item1 = store.add(url: URL(string: "https://example.com/1")!, title: "One")
        let item2 = store.add(url: URL(string: "https://example.com/2")!, title: "Two")

        store.remove(id: item1.id)
        #expect(store.items.count == 1)
        #expect(store.items.first?.id == item2.id)

        store.clearAll()
        #expect(store.items.isEmpty)
    }

    @Test("ReadingListStore persists items to disk and loads them across instances")
    func testReadingListStorePersistence() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("reading-list-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let store1 = ReadingListStore(fileURL: tempURL)
        store1.add(url: URL(string: "https://apple.com/news")!, title: "Apple News", previewText: "Cupertino updates")

        let store2 = ReadingListStore(fileURL: tempURL)
        #expect(store2.items.count == 1)
        #expect(store2.items.first?.title == "Apple News")
        #expect(store2.items.first?.previewText == "Cupertino updates")
    }

    @Test("ReaderScript produces valid JavaScript containing themes and controls")
    func testReaderScriptGeneration() {
        let toggleOnScript = ReaderScript.toggleScript(force: true)
        #expect(toggleOnScript.contains("kylmora-hud"))
        #expect(toggleOnScript.contains("kylmora-article"))
        #expect(toggleOnScript.contains("kylmoraReader"))
        #expect(toggleOnScript.contains("kylmoraReaderSpeech"))
        #expect(toggleOnScript.contains("data-theme=\"sepia\""))
        #expect(toggleOnScript.contains("data-theme=\"dark\""))
        #expect(toggleOnScript.contains("var force = true;"))

        let toggleOffScript = ReaderScript.toggleScript(force: false)
        #expect(toggleOffScript.contains("window.__kylmoraOriginalContent"))
        #expect(toggleOffScript.contains("var force = false;"))
    }

    @Test("ReaderSpeechService manages playback state")
    func testReaderSpeechService() {
        let speech = ReaderSpeechService.shared
        #expect(speech.isSpeaking == false)
        #expect(speech.isPaused == false)

        speech.stop()
        #expect(speech.isSpeaking == false)
    }

    @Test("ReaderModeController registers WKScriptMessageHandler endpoints")
    func testReaderModeControllerRegistration() {
        let controller = ReaderModeController()
        let ucc = WKUserContentController()

        controller.attach(ucc)
        #expect(ReaderModeController.readerHandlerName == "kylmoraReader")
        #expect(ReaderModeController.speechHandlerName == "kylmoraReaderSpeech")
    }

    @Test("CommandCatalog and ShortcutManager include Reader Mode commands")
    func testCommandCatalogAndShortcuts() {
        let commands = CommandCatalog.all

        #expect(commands.contains { $0.id == "reader-mode" })
        #expect(commands.contains { $0.id == "always-use-reader-on-domain" })
        #expect(commands.contains { $0.id == "add-to-reading-list" })
        #expect(commands.contains { $0.id == "show-reading-list" })
        #expect(commands.contains { $0.id == "read-aloud" })

        let sm = ShortcutManager()
        #expect(sm.definition(for: "toggle-reader-mode") != nil)
        #expect(sm.definition(for: "add-to-reading-list") != nil)
        #expect(sm.definition(for: "show-reading-list") != nil)
        #expect(sm.definition(for: "read-aloud") != nil)
    }
}
