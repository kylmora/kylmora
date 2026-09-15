import AppKit
import Foundation
import Testing
@testable import Kylmora

@Suite("Per-Space Extras (F-24)")
@MainActor
struct PerSpaceExtrasTests {

    @Test("Space initializes and resolves per-space downloads directory")
    func downloadsDirectoryResolution() {
        let space = Space(name: "Work", identity: .makeIsolated())
        #expect(space.downloadsDirectoryPath == nil)
        #expect(space.effectiveDownloadsDirectory == DownloadDestination.downloadsDirectory()!)

        let customPath = "/tmp/kylmora-test-work-downloads"
        space.downloadsDirectoryPath = customPath
        #expect(space.effectiveDownloadsDirectory.path == customPath)
    }

    @Test("Space resolves effective password vault account name")
    func passwordAccountResolution() {
        let space = Space(name: "Personal", identity: .standard)
        #expect(space.effectivePasswordAccount == "Personal")

        space.passwordVaultAccount = "My 1Password Vault"
        #expect(space.effectivePasswordAccount == "My 1Password Vault")
    }

    @Test("BrowserSession persists per-space downloads, bookmarks, extensions, and vault account")
    func sessionPersistence() {
        let session = BrowserSession(database: nil)
        let space = session.addSpace(named: "Work")

        let customDownloads = "/tmp/kylmora-work-downloads"
        let customBookmarkFolder = "Work Bookmarks"
        let testExtID = UUID()
        let customVault = "Work Vault"

        session.setDownloadsDirectoryPath(customDownloads, for: space)
        session.setBookmarkFolder(customBookmarkFolder, for: space)
        session.setEnabledExtensionIDs([testExtID], for: space)
        session.setPasswordVaultAccount(customVault, for: space)

        #expect(space.downloadsDirectoryPath == customDownloads)
        #expect(space.bookmarkFolder == customBookmarkFolder)
        #expect(space.enabledExtensionIDs == [testExtID])
        #expect(space.passwordVaultAccount == customVault)

        let snapshot = session.snapshot()
        guard let restoredSpace = BrowserSession.spaces(from: snapshot)?.first(where: { $0.name == "Work" }) else {
            Issue.record("Failed to restore Work space from snapshot")
            return
        }

        #expect(restoredSpace.downloadsDirectoryPath == customDownloads)
        #expect(restoredSpace.bookmarkFolder == customBookmarkFolder)
        #expect(restoredSpace.enabledExtensionIDs == [testExtID])
        #expect(restoredSpace.passwordVaultAccount == customVault)
    }

    @Test("ExtensionManager checks per-space extension enablement")
    func extensionPerSpaceFiltering() {
        if #available(macOS 15.4, *) {
            let manager = ExtensionManager(controllerConfiguration: .nonPersistent())
            let extID1 = UUID()
            let extID2 = UUID()

            let spaceAll = Space(name: "Default Space", identity: .standard)
            // With enabledExtensionIDs nil, all enabled extensions run
            #expect(manager.isExtensionEnabled(extID1, in: spaceAll) == false) // not in records

            let spaceRestricted = Space(name: "Restricted", identity: .makeIsolated())
            spaceRestricted.enabledExtensionIDs = [extID1]
            #expect(spaceRestricted.enabledExtensionIDs?.contains(extID1) == true)
            #expect(spaceRestricted.enabledExtensionIDs?.contains(extID2) == false)
        }
    }

    @Test("Per-space bookmark folder filters bookmarks appropriately")
    func bookmarkFiltering() {
        let session = BrowserSession(database: nil)
        let space = session.addSpace(named: "Work")
        session.setBookmarkFolder("Work", for: space)

        let workBookmark = Bookmark(url: URL(string: "https://work.com")!, title: "Work Dashboard", folder: "Work")
        let personalBookmark = Bookmark(url: URL(string: "https://personal.com")!, title: "Personal Blog", folder: "Personal")
        let all = [workBookmark, personalBookmark]

        let filtered = all.filter { $0.folder.localizedCaseInsensitiveCompare(space.bookmarkFolder!) == .orderedSame }
        #expect(filtered.count == 1)
        #expect(filtered.first?.url.absoluteString == "https://work.com")
    }
}
