import Foundation
import Testing
@testable import Kylmora

@Suite("Download destinations")
struct DownloadDestinationTests {
    /// A directory that does not have to exist: `resolve` never touches the
    /// disk, because existence is injected.
    private let downloads = URL(filePath: "/Users/someone/Downloads", directoryHint: .isDirectory)

    @Test("A plain name survives unchanged")
    func plainName() {
        #expect(DownloadDestination.sanitized("report.pdf") == "report.pdf")
    }

    @Test("Path separators cannot survive a suggested filename")
    func separatorsAreRemoved() {
        for suggested in ["../../.zshenv", "/etc/passwd", "a/b/c.txt", "..\\..\\evil.exe", "Macintosh HD:evil"] {
            let name = DownloadDestination.sanitized(suggested)
            #expect(!name.contains("/"), "\(suggested) kept a separator")
            #expect(!name.contains("\\"), "\(suggested) kept a separator")
            #expect(!name.contains(":"), "\(suggested) kept a separator")
            #expect(name != "..")
        }
    }

    @Test("A separator hidden behind percent-encoding is still a separator")
    func percentEncodedSeparators() {
        #expect(!DownloadDestination.sanitized("..%2F..%2Fevil.sh").contains("/"))
    }

    @Test("A leading dot is dropped, so nothing arrives invisible")
    func hiddenFiles() {
        #expect(DownloadDestination.sanitized(".bashrc") == "bashrc")
        #expect(DownloadDestination.sanitized("...") == DownloadDestination.fallbackName)
    }

    @Test("A name that collapses to nothing gets a fallback rather than an empty path")
    func emptyName() {
        for suggested in ["", "   ", "/", "//"] {
            #expect(DownloadDestination.sanitized(suggested) == DownloadDestination.fallbackName)
        }
    }

    @Test("A control character cannot be smuggled into a name")
    func controlCharacters() {
        let name = DownloadDestination.sanitized("re\u{0}port\nnext.pdf")
        #expect(!name.contains("\u{0}"))
        #expect(!name.contains("\n"))
    }

    @Test("An over-long name is trimmed to the file system limit, keeping its extension")
    func longNames() {
        let name = DownloadDestination.sanitized(String(repeating: "a", count: 900) + ".pdf")
        #expect(name.utf8.count <= DownloadDestination.maximumNameBytes)
        #expect(name.hasSuffix(".pdf"))
    }

    @Test("An unused name is used as it is")
    func noCollision() {
        let resolution = DownloadDestination.resolve(suggested: "report.pdf", in: downloads) { _ in false }
        #expect(resolution?.url.lastPathComponent == "report.pdf")
        #expect(resolution?.renamed == false)
    }

    @Test("A taken name is numbered rather than overwritten")
    func collisionIsNumbered() {
        let taken: Set<String> = ["report.pdf", "report 2.pdf"]
        let resolution = DownloadDestination.resolve(suggested: "report.pdf", in: downloads) {
            taken.contains($0.lastPathComponent)
        }
        #expect(resolution?.url.lastPathComponent == "report 3.pdf")
        #expect(resolution?.renamed == true)
    }

    @Test("An extensionless name is numbered without gaining one")
    func collisionWithoutExtension() {
        let resolution = DownloadDestination.resolve(suggested: "archive", in: downloads) {
            $0.lastPathComponent == "archive"
        }
        #expect(resolution?.url.lastPathComponent == "archive 2")
    }

    @Test("Numbering gives up rather than looping forever")
    func collisionIsBounded() {
        #expect(DownloadDestination.resolve(suggested: "report.pdf", in: downloads) { _ in true } == nil)
    }

    @Test("Every resolved destination stays inside the chosen directory")
    func containment() {
        for suggested in ["../../.zshenv", "/etc/passwd", "....//....//x", ".."] {
            guard let resolution = DownloadDestination.resolve(suggested: suggested, in: downloads, exists: { _ in false })
            else { continue }
            #expect(
                resolution.url.deletingLastPathComponent().standardizedFileURL.path()
                    == downloads.standardizedFileURL.path(),
                "\(suggested) escaped to \(resolution.url.path())"
            )
        }
    }
}

@Suite("Download records")
struct DownloadRecordTests {
    private func record(_ state: DownloadState) -> DownloadRecord {
        DownloadRecord(
            id: UUID(),
            sourceURL: URL(string: "https://example.com/report.pdf")!,
            destination: URL(filePath: "/Users/someone/Downloads/report.pdf"),
            state: state,
            startedAt: Date(timeIntervalSince1970: 1_000),
            finishedAt: Date(timeIntervalSince1970: 1_010),
            byteCount: 4_096
        )
    }

    private func roundTrip(_ original: DownloadRecord) throws -> DownloadRecord {
        let data = try JSONEncoder().encode(original)
        return try JSONDecoder().decode(DownloadRecord.self, from: data)
    }

    @Test("Finished, failed and cancelled all survive a round trip")
    func statesRoundTrip() throws {
        for state in [DownloadState.finished, .cancelled, .failed("The network connection was lost")] {
            let original = record(state)
            #expect(try roundTrip(original) == original)
        }
    }

    @Test("A transfer still running at quit comes back as interrupted, not as running")
    func runningIsNotRestoredAsRunning() throws {
        let restored = try roundTrip(record(.running))
        #expect(restored.state != .running)
        if case .failed(let message) = restored.state {
            #expect(!message.isEmpty)
        } else {
            Issue.record("a running download should be restored as a failure, got \(restored.state)")
        }
    }

    @Test("The stored list is capped, newest first")
    func storeCapsTheList() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "kylmora-downloads-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }

        let store = DownloadStore(fileURL: file)
        let many = (0..<(DownloadStore.limit + 50)).map { _ in record(.finished) }
        try store.save(many)

        let loaded = store.load()
        #expect(loaded.count == DownloadStore.limit)
        #expect(loaded.first == many.first)
    }

    @Test("A missing file is an empty list, not a failure")
    func missingFileLoadsEmpty() {
        let file = FileManager.default.temporaryDirectory.appending(path: "kylmora-absent-\(UUID().uuidString).json")
        #expect(DownloadStore(fileURL: file).load().isEmpty)
    }
}

@Suite("The downloads list")
@MainActor
struct DownloadManagerTests {
    /// A manager backed by a throwaway file, seeded with records, so the list
    /// behaviour can be tested without a network or a web view.
    private func manager(seededWith states: [DownloadState]) throws -> (DownloadManager, URL) {
        let file = FileManager.default.temporaryDirectory.appending(path: "kylmora-downloads-\(UUID().uuidString).json")
        let store = DownloadStore(fileURL: file)
        try store.save(states.enumerated().map { index, state in
            DownloadRecord(
                id: UUID(),
                sourceURL: URL(string: "https://example.com/file\(index).bin")!,
                destination: URL(filePath: "/Users/someone/Downloads/file\(index).bin"),
                state: state,
                startedAt: .now,
                finishedAt: nil,
                byteCount: nil
            )
        })
        return (DownloadManager(store: store), file)
    }

    @Test("The list is restored from disk at launch")
    func restoresList() throws {
        let (manager, file) = try manager(seededWith: [.finished, .cancelled])
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(manager.downloads.count == 2)
        #expect(manager.downloads.map(\.filename) == ["file0.bin", "file1.bin"])
    }

    @Test("A restored row has nothing in flight, so it is never reported as active")
    func restoredRowsAreNotActive() throws {
        // A record written while a transfer was running decodes as a failure,
        // which is the honest reading: the bytes stopped when Kylmora quit.
        let (manager, file) = try manager(seededWith: [.running])
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(!manager.hasActiveDownloads)
        #expect(manager.downloads.first?.canResume == false)
    }

    @Test("Clearing removes finished rows and writes the shorter list")
    func clearingIsPersisted() throws {
        let (manager, file) = try manager(seededWith: [.finished, .failed("Boom"), .cancelled])
        defer { try? FileManager.default.removeItem(at: file) }

        manager.clearCompleted()
        #expect(manager.downloads.isEmpty)

        manager.saveNow()
        #expect(DownloadStore(fileURL: file).load().isEmpty)
    }

    @Test("Removing one row leaves the others alone")
    func removeOne() throws {
        let (manager, file) = try manager(seededWith: [.finished, .finished])
        defer { try? FileManager.default.removeItem(at: file) }

        let first = manager.downloads[0]
        manager.remove(first)
        #expect(manager.downloads.count == 1)
        #expect(manager.downloads[0].filename == "file1.bin")
    }

    @Test("A finished row whose file was deleted stops offering Open and Reveal")
    func missingFileIsNotOpenable() throws {
        let (manager, file) = try manager(seededWith: [.finished])
        defer { try? FileManager.default.removeItem(at: file) }
        // The seeded destination is a path that does not exist.
        #expect(manager.downloads[0].fileExists == false)
    }
}

@Suite("General pane machinery")
struct GeneralMachineryTests {
    @Test("Bookmarks are read from Netscape HTML and from Chrome's file")
    func importsBothFormats() throws {
        let html = """
            <!DOCTYPE NETSCAPE-Bookmark-file-1>
            <DL><p>
            <DT><H3>Folder</H3>
            <DL><p>
            <DT><A HREF="https://a.example/" ADD_DATE="1">A &amp; B</A>
            <DT><A HREF="https://b.example/x">Bee</A>
            <DT><A HREF="javascript:alert(1)">Nope</A>
            </DL><p>
            </DL>
            """
        let fromHTML = try BookmarkImporter.entries(in: Data(html.utf8))
        // The folder is preserved now, not flattened away.
        #expect(fromHTML == [
            BookmarkImporter.Entry(title: "A & B", url: URL(string: "https://a.example/")!, folderPath: ["Folder"]),
            BookmarkImporter.Entry(title: "Bee", url: URL(string: "https://b.example/x")!, folderPath: ["Folder"])
        ])

        let chrome = """
            {"roots": {"bookmark_bar": {"type": "folder", "children": [
                {"type": "url", "name": "One", "url": "https://one.example/"},
                {"type": "folder", "children": [{"type": "url", "name": "Two", "url": "https://two.example/"}]}
            ]}, "other": {"type": "folder", "children": []}}, "version": 1}
            """
        let fromChrome = try BookmarkImporter.entries(in: Data(chrome.utf8))
        #expect(fromChrome.map(\.title) == ["One", "Two"])

        #expect(throws: BookmarkImporter.Failure.unrecognised) {
            try BookmarkImporter.entries(in: Data("just some text".utf8))
        }
    }

    @Test("Download rows leave on the schedule")
    func removalSchedule() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(DownloadRemoval.manually.removes(finishedAt: now, atLaunch: true) == false)
        #expect(DownloadRemoval.onQuit.removes(finishedAt: now, atLaunch: true))
        #expect(DownloadRemoval.onQuit.removes(finishedAt: now, atLaunch: false) == false)
        #expect(DownloadRemoval.afterDay.removes(finishedAt: now.addingTimeInterval(-90_000), now: now, atLaunch: false))
        #expect(DownloadRemoval.afterDay.removes(finishedAt: now.addingTimeInterval(-3_600), now: now, atLaunch: false) == false)
        #expect(DownloadRemoval.uponSuccess.removes(finishedAt: now, atLaunch: false))
    }

    @Test("Safe files are what the file is, and only the harmless kinds")
    @MainActor func safeFiles() {
        #expect(DownloadManager.isSafeToOpen(URL(fileURLWithPath: "/tmp/a.png")))
        #expect(DownloadManager.isSafeToOpen(URL(fileURLWithPath: "/tmp/a.pdf")))
        #expect(DownloadManager.isSafeToOpen(URL(fileURLWithPath: "/tmp/a.zip")))
        #expect(DownloadManager.isSafeToOpen(URL(fileURLWithPath: "/tmp/a.txt")))
        #expect(DownloadManager.isSafeToOpen(URL(fileURLWithPath: "/tmp/a.dmg")) == false)
        #expect(DownloadManager.isSafeToOpen(URL(fileURLWithPath: "/tmp/a.pkg")) == false)
        #expect(DownloadManager.isSafeToOpen(URL(fileURLWithPath: "/tmp/a.sh")) == false)
        #expect(DownloadManager.isSafeToOpen(URL(fileURLWithPath: "/tmp/a")) == false)
    }

    @Test("The General pane's new settings persist")
    @MainActor func generalSettingsPersist() {
        let defaults = UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!
        let settings = Settings(defaults: defaults)
        #expect(settings.downloadLocation == .downloads && settings.downloadRemoval == .manually)
        #expect(settings.externalLinkTarget == .currentSpace && settings.warnsBeforeQuitting)
        let id = UUID()
        settings.downloadLocation = .ask
        settings.downloadRemoval = .afterDay
        settings.opensSafeFilesAfterDownloading = true
        settings.defaultSpaceID = id
        settings.externalLinkTarget = .defaultSpace
        settings.warnsBeforeQuitting = false
        let again = Settings(defaults: defaults)
        #expect(again.downloadLocation == .ask && again.downloadRemoval == .afterDay)
        #expect(again.opensSafeFilesAfterDownloading && again.defaultSpaceID == id)
        #expect(again.externalLinkTarget == .defaultSpace && again.warnsBeforeQuitting == false)
    }
}
