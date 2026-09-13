import AppKit
import Foundation
import Testing
@testable import Kylmora

private func temporaryDirectory() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "kylmora-sync-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite("Cross-Device Sync Models and Archiving")
struct SyncArchiveTests {
    @Test("SyncArchive serialises and deserialises without loss")
    func archiveRoundTrip() throws {
        let space = SessionSnapshot.Space(
            name: "Work",
            tabs: [
                SessionSnapshot.Tab(url: URL(string: "https://github.com")!, title: "GitHub"),
                SessionSnapshot.Tab(url: URL(string: "https://apple.com")!, title: "Apple")
            ],
            groups: [
                SessionSnapshot.Group(
                    id: UUID(),
                    name: "Projects",
                    tint: "#ff5500",
                    isCollapsed: false
                )
            ],
            pinnedSites: [
                SessionSnapshot.Pinned(id: UUID(), url: URL(string: "https://mail.google.com")!, title: "Mail")
            ]
        )
        let snapshot = SessionSnapshot(spaces: [space], activeSpaceIndex: 0)
        let bookmark = SyncBookmark(url: URL(string: "https://swift.org")!, title: "Swift", folder: "Dev")

        let archive = SyncArchive(
            version: 1,
            deviceID: UUID(),
            deviceName: "MacBook Pro",
            exportedAt: .now,
            session: snapshot,
            bookmarks: [bookmark]
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(archive)
        let decoded = try JSONDecoder().decode(SyncArchive.self, from: data)

        #expect(decoded.version == archive.version)
        #expect(decoded.deviceID == archive.deviceID)
        #expect(decoded.deviceName == archive.deviceName)
        #expect(decoded.session.spaces.count == 1)
        #expect(decoded.session.spaces.first?.name == "Work")
        #expect(decoded.session.spaces.first?.tabs.count == 2)
        #expect(decoded.session.spaces.first?.groups?.count == 1)
        #expect(decoded.session.spaces.first?.pinnedSites?.count == 1)
        #expect(decoded.bookmarks.count == 1)
        #expect(decoded.bookmarks.first?.url == URL(string: "https://swift.org")!)
    }
}

@Suite("Sync Merging Policy")
struct SyncMergePolicyTests {
    @Test("Merging adds missing spaces and unifies pinned sites and folders")
    func mergeSpacesAndFolders() {
        let localSpace = SessionSnapshot.Space(
            name: "Personal",
            tabs: [SessionSnapshot.Tab(url: URL(string: "https://news.ycombinator.com")!, title: "HN")],
            pinnedSites: [SessionSnapshot.Pinned(id: UUID(), url: URL(string: "https://duckduckgo.com")!, title: "DDG")]
        )
        let localArchive = SyncArchive(
            session: SessionSnapshot(spaces: [localSpace], activeSpaceIndex: 0),
            bookmarks: [SyncBookmark(url: URL(string: "https://apple.com")!, title: "Apple")]
        )

        let remoteGroupID = UUID()
        let remoteSpacePersonal = SessionSnapshot.Space(
            name: "Personal",
            tabs: [SessionSnapshot.Tab(url: URL(string: "https://lobste.rs")!, title: "Lobsters")],
            groups: [SessionSnapshot.Group(id: remoteGroupID, name: "Reading", tint: "#007aff", isCollapsed: false)],
            pinnedSites: [SessionSnapshot.Pinned(id: UUID(), url: URL(string: "https://kagi.com")!, title: "Kagi")]
        )
        let remoteSpaceWork = SessionSnapshot.Space(
            name: "Work",
            tabs: [SessionSnapshot.Tab(url: URL(string: "https://github.com")!, title: "GitHub")]
        )
        let remoteArchive = SyncArchive(
            session: SessionSnapshot(spaces: [remoteSpacePersonal, remoteSpaceWork], activeSpaceIndex: 0),
            bookmarks: [SyncBookmark(url: URL(string: "https://github.com")!, title: "GitHub")]
        )

        let (merged, summary) = SyncMergePolicy.merge(
            local: localArchive,
            remote: remoteArchive,
            syncOpenTabs: true,
            syncBookmarks: true,
            syncSiteSettings: true
        )

        #expect(summary.addedSpaces == 1) // Work
        #expect(summary.addedGroups == 1) // Reading
        #expect(summary.addedPinnedSites == 1) // Kagi
        #expect(summary.addedTabs == 2) // Lobsters in Personal, GitHub in Work
        #expect(summary.addedBookmarks == 1) // GitHub bookmark

        #expect(merged.session.spaces.count == 2)
        let mergedPersonal = merged.session.spaces.first { $0.name == "Personal" }!
        #expect(mergedPersonal.tabs.count == 2)
        #expect(mergedPersonal.groups?.count == 1)
        #expect(mergedPersonal.pinnedSites?.count == 2)
        #expect(merged.bookmarks.count == 2)
    }

    @Test("When open tabs sync is disabled, only spaces, pins, and groups are synced")
    func mergeWithoutOpenTabs() {
        let localSpace = SessionSnapshot.Space(name: "Personal", tabs: [
            SessionSnapshot.Tab(url: URL(string: "https://example.com/1")!, title: "1")
        ])
        let localArchive = SyncArchive(session: SessionSnapshot(spaces: [localSpace], activeSpaceIndex: 0))

        let remoteSpace = SessionSnapshot.Space(
            name: "Personal",
            tabs: [SessionSnapshot.Tab(url: URL(string: "https://example.com/2")!, title: "2")],
            pinnedSites: [SessionSnapshot.Pinned(id: UUID(), url: URL(string: "https://pinned.com")!, title: "Pin")]
        )
        let remoteNewSpace = SessionSnapshot.Space(
            name: "Research",
            tabs: [SessionSnapshot.Tab(url: URL(string: "https://example.com/3")!, title: "3")]
        )
        let remoteArchive = SyncArchive(session: SessionSnapshot(spaces: [remoteSpace, remoteNewSpace], activeSpaceIndex: 0))

        let (merged, summary) = SyncMergePolicy.merge(
            local: localArchive,
            remote: remoteArchive,
            syncOpenTabs: false,
            syncBookmarks: true,
            syncSiteSettings: true
        )

        #expect(summary.addedSpaces == 1)
        #expect(summary.addedTabs == 0) // No open tabs added
        #expect(summary.addedPinnedSites == 1)

        let personal = merged.session.spaces.first { $0.name == "Personal" }!
        #expect(personal.tabs.count == 1)
        #expect(personal.tabs.first?.url == URL(string: "https://example.com/1")!)
        #expect(personal.pinnedSites?.count == 1)

        let research = merged.session.spaces.first { $0.name == "Research" }!
        #expect(research.tabs.isEmpty)
    }
}

@Suite("Arc Sidebar Importer")
struct ArcSidebarImporterTests {
    @Test("Parses Arc StorableSidebar JSON format into spaces, folders, and tabs")
    func parseArcJson() throws {
        let arcJson = """
        {
            "version": 1,
            "sidebar": {
                "containers": [
                    {
                        "spaces": [
                            {
                                "id": "space-uuid-1",
                                "title": "Development",
                                "customInfo": {
                                    "windowTheme": {
                                        "singleColor": { "r": 0.1, "g": 0.5, "b": 0.9 }
                                    }
                                }
                            }
                        ],
                        "items": [
                            {
                                "id": "folder-1",
                                "parentID": "space-uuid-1",
                                "title": "Tools",
                                "data": { "itemContainer": {} }
                            },
                            {
                                "id": "tab-1",
                                "parentID": "folder-1",
                                "title": "GitHub",
                                "data": {
                                    "tab": { "savedURL": "https://github.com", "savedTitle": "GitHub" }
                                }
                            },
                            {
                                "id": "pin-1",
                                "parentID": "space-uuid-1",
                                "title": "Kylmora",
                                "pinned": true,
                                "data": {
                                    "tab": { "savedURL": "https://kylmora.org", "savedTitle": "Kylmora" }
                                }
                            }
                        ]
                    }
                ]
            }
        }
        """

        let data = arcJson.data(using: .utf8)!
        let snapshot = try ArcSidebarImporter.importSidebar(from: data)

        #expect(snapshot.spaces.count == 1)
        let space = snapshot.spaces[0]
        #expect(space.name == "Development")
        #expect(space.groups?.count == 1)
        #expect(space.groups?.first?.name == "Tools")
        #expect(space.pinnedSites?.count == 1)
        #expect(space.pinnedSites?.first?.url == URL(string: "https://kylmora.org")!)
        #expect(space.tabs.count == 1)
        #expect(space.tabs.first?.url == URL(string: "https://github.com")!)
    }
}

@Suite("File-Based Ubiquity Sync Provider")
struct FileUbiquitySyncProviderTests {
    @Test("Saves local device archive and fetches remote peer archives")
    func saveAndFetch() async throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let provider = FileUbiquitySyncProvider(syncDirectory: dir)

        let device1ID = UUID()
        let archive1 = SyncArchive(
            deviceID: device1ID,
            deviceName: "Device 1",
            session: SessionSnapshot(spaces: [SessionSnapshot.Space(name: "Space 1", tabs: [])], activeSpaceIndex: 0)
        )

        let device2ID = UUID()
        let archive2 = SyncArchive(
            deviceID: device2ID,
            deviceName: "Device 2",
            session: SessionSnapshot(spaces: [SessionSnapshot.Space(name: "Space 2", tabs: [])], activeSpaceIndex: 0)
        )

        try await provider.saveLocalArchive(archive1)
        try await provider.saveLocalArchive(archive2)

        let manifest = await provider.loadManifest()
        #expect(manifest.devices.count == 2)
        #expect(manifest.devices[device1ID.uuidString]?.name == "Device 1")
        #expect(manifest.devices[device2ID.uuidString]?.name == "Device 2")

        let remoteForDevice1 = await provider.fetchRemoteArchives(excludingDeviceID: device1ID)
        #expect(remoteForDevice1.count == 1)
        #expect(remoteForDevice1.first?.deviceID == device2ID)
        #expect(remoteForDevice1.first?.deviceName == "Device 2")

        let remoteForDevice2 = await provider.fetchRemoteArchives(excludingDeviceID: device2ID)
        #expect(remoteForDevice2.count == 1)
        #expect(remoteForDevice2.first?.deviceID == device1ID)
    }
}

@Suite("Sync Settings and Defaults")
struct SyncSettingsTests {
    @Test("Settings has sync keys registered with expected defaults")
    @MainActor
    func defaults() {
        let suiteName = "test.kylmora.sync.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = Settings(defaults: defaults)
        #expect(settings.syncEnabled == false)
        #expect(settings.syncOpenTabs == true)
        #expect(settings.syncBookmarks == true)
        #expect(settings.syncSiteSettings == true)
        #expect(settings.syncCustomDirectory == "")
        #expect(settings.syncLastTimestamp == 0.0)

        settings.syncEnabled = true
        settings.syncOpenTabs = false
        settings.syncCustomDirectory = "/tmp/sync"
        settings.syncLastTimestamp = 12345.67

        let again = Settings(defaults: defaults)
        #expect(again.syncEnabled == true)
        #expect(again.syncOpenTabs == false)
        #expect(again.syncCustomDirectory == "/tmp/sync")
        #expect(again.syncLastTimestamp == 12345.67)
        #expect(again.syncService == .iCloud)

        settings.syncService = .googleDrive
        settings.syncPassphrase = "my-secret-passphrase"
        settings.syncWebDAVURL = "https://cloud.example.com/remote.php/dav/files/user/Kylmora"

        let third = Settings(defaults: defaults)
        #expect(third.syncService == .googleDrive)
        #expect(third.syncPassphrase == "my-secret-passphrase")
        #expect(third.syncWebDAVURL == "https://cloud.example.com/remote.php/dav/files/user/Kylmora")
    }
}

@Suite("End-to-End Sync Encryption (AES-256-GCM)")
struct SyncCryptoTests {
    @Test("Encrypts and decrypts payload seamlessly with passphrase")
    func encryptDecryptRoundTrip() throws {
        let originalText = "Kylmora cross-device sync payload with open tabs & bookmarks"
        let rawData = originalText.data(using: .utf8)!
        let passphrase = "correct-horse-battery-staple"

        let encrypted = try SyncCrypto.encrypt(rawData, passphrase: passphrase)
        #expect(SyncCrypto.isEncrypted(encrypted) == true)
        #expect(encrypted != rawData)

        let decrypted = try SyncCrypto.decrypt(encrypted, passphrase: passphrase)
        #expect(decrypted == rawData)
        #expect(String(data: decrypted, encoding: .utf8) == originalText)
    }

    @Test("Throws error when decrypting with wrong passphrase")
    func wrongPassphraseThrows() throws {
        let rawData = "Confidential data".data(using: .utf8)!
        let encrypted = try SyncCrypto.encrypt(rawData, passphrase: "password-1")

        #expect(throws: SyncCrypto.CryptoError.self) {
            _ = try SyncCrypto.decrypt(encrypted, passphrase: "wrong-password")
        }
    }

    @Test("Throws error when decrypting encrypted data without passphrase")
    func missingPassphraseThrows() throws {
        let rawData = "Confidential data".data(using: .utf8)!
        let encrypted = try SyncCrypto.encrypt(rawData, passphrase: "password-1")

        #expect(throws: SyncCrypto.CryptoError.self) {
            _ = try SyncCrypto.decrypt(encrypted, passphrase: nil)
        }
    }

    @Test("Passes through unencrypted plaintext payloads transparently")
    func plainDataPassthrough() throws {
        let rawData = "{\"version\": 1, \"devices\": {}}".data(using: .utf8)!
        #expect(SyncCrypto.isEncrypted(rawData) == false)

        let result = try SyncCrypto.decrypt(rawData, passphrase: nil)
        #expect(result == rawData)
    }
}

@Suite("Encrypted File Ubiquity Sync Provider")
struct EncryptedSyncProviderTests {
    @Test("Saves encrypted archive and reads it back successfully with passphrase")
    func encryptedLocalSync() async throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let provider = FileUbiquitySyncProvider(syncDirectory: dir)
        let deviceID = UUID()
        let archive = SyncArchive(
            deviceID: deviceID,
            deviceName: "Secure Mac",
            session: SessionSnapshot(spaces: [SessionSnapshot.Space(name: "Private Space", tabs: [])], activeSpaceIndex: 0)
        )

        let passphrase = "e2ee-secret-key"
        try await provider.saveLocalArchive(archive, passphrase: passphrase)

        // Verify file is actually encrypted on disk
        let fileURL = dir.appending(path: "devices/device-\(deviceID.uuidString).json")
        let fileData = try Data(contentsOf: fileURL)
        #expect(SyncCrypto.isEncrypted(fileData) == true)

        // Fetch using correct passphrase
        let remotes = await provider.fetchRemoteArchives(excludingDeviceID: UUID(), passphrase: passphrase)
        #expect(remotes.count == 1)
        #expect(remotes.first?.deviceName == "Secure Mac")
        #expect(remotes.first?.session.spaces.first?.name == "Private Space")

        // Fetch with wrong passphrase yields empty (skips corrupted/unreadable)
        let remotesWrong = await provider.fetchRemoteArchives(excludingDeviceID: UUID(), passphrase: "wrong")
        #expect(remotesWrong.isEmpty)
    }
}

@Suite("Cloud Storage Path Resolution")
struct CloudStorageDetectorTests {
    @Test("Resolves custom paths and provides proper labels")
    func customPathResolution() {
        let (url, isAuto, label) = CloudStorageDetector.resolveFolder(for: .googleDrive, customPath: "/tmp/custom-gdrive")
        #expect(url?.path == "/tmp/custom-gdrive")
        #expect(isAuto == false)
        #expect(label == "/tmp/custom-gdrive")
    }

    @Test("Resolves default iCloud drive folder")
    func defaultICloudResolution() {
        let (url, isAuto, label) = CloudStorageDetector.resolveFolder(for: .iCloud, customPath: nil)
        #expect(url != nil)
        #expect(isAuto == true)
        #expect(label.contains("iCloud"))
    }
}
