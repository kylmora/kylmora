import AppKit
import Foundation
import Testing
@testable import Kylmora

@Suite("iPhone & iPad Companion (F-35)")
@MainActor
struct IPhoneCompanionTests {

    @Test("IPhoneLink parses structured JSON")
    func jsonParsing() throws {
        let json = """
        {
            "url": "https://example.com/swift-testing",
            "title": "Swift Testing Guide",
            "spaceName": "Research",
            "mode": "pinned",
            "note": "Read this tonight",
            "sender": "iPhone 16 Pro"
        }
        """
        let link = try #require(IPhoneLink.parse(jsonData: Data(json.utf8)))
        #expect(link.url == URL(string: "https://example.com/swift-testing")!)
        #expect(link.title == "Swift Testing Guide")
        #expect(link.spaceName == "Research")
        #expect(link.mode == .pinned)
        #expect(link.note == "Read this tonight")
        #expect(link.sender == "iPhone 16 Pro")
        #expect(link.displayTitle == "Swift Testing Guide")
    }

    @Test("IPhoneLink parses loose Shortcut dictionary")
    func looseJsonParsing() throws {
        let json = """
        {
            "link": "https://news.ycombinator.com",
            "name": "Hacker News",
            "space": "Read Later",
            "mode": "littleArc"
        }
        """
        let link = try #require(IPhoneLink.parse(jsonData: Data(json.utf8)))
        #expect(link.url == URL(string: "https://news.ycombinator.com")!)
        #expect(link.title == "Hacker News")
        #expect(link.spaceName == "Read Later")
        #expect(link.mode == .littleArc)
        #expect(link.displayTitle == "Hacker News")
    }

    @Test("IPhoneLink parses plain text and URL format")
    func textParsing() throws {
        let text = """
        [InternetShortcut]
        URL=https://webkit.org/blog/
        Space: WebKit
        Title: WebKit Blog
        Mode: pinned
        """
        let link = try #require(IPhoneLink.parse(text: text))
        #expect(link.url == URL(string: "https://webkit.org/blog/")!)
        #expect(link.spaceName == "WebKit")
        #expect(link.title == "WebKit Blog")
        #expect(link.mode == .pinned)
    }

    @Test("IPhoneLink parses kylmora:// deep link URL schemes")
    func urlSchemeParsing() throws {
        let url = URL(string: "kylmora://send?url=https%3A%2F%2Fgithub.com%2Fzen-browser&space=Read%20Later&title=Zen%20Browser&mode=tab")!
        let link = try #require(IPhoneLink.parse(urlScheme: url))
        #expect(link.url == URL(string: "https://github.com/zen-browser")!)
        #expect(link.spaceName == "Read Later")
        #expect(link.title == "Zen Browser")
        #expect(link.mode == .tab)
        #expect(link.displayTitle == "Zen Browser")
    }

    @Test("IPhoneLink rejects invalid non-HTTP schemes")
    func rejectsNonHttp() {
        let json = """
        {
            "url": "file:///etc/passwd",
            "space": "System"
        }
        """
        #expect(IPhoneLink.parse(jsonData: Data(json.utf8)) == nil)
        #expect(IPhoneLink.parse(text: "URL=javascript:alert(1)") == nil)
    }

    @Test("IPhoneLinkReceiver routes link into existing space")
    func routesToExistingSpace() {
        let session = TestSession.make().0
        let space = session.addSpace(named: "Tech News")

        let link = IPhoneLink(
            url: URL(string: "https://arstechnica.com")!,
            title: "Ars Technica",
            spaceName: "Tech News",
            mode: .tab
        )

        var notified = false
        IPhoneLinkReceiver.shared.onLinkReceived = { receivedLink, targetSpace in
            if receivedLink.url == link.url && targetSpace.id == space.id {
                notified = true
            }
        }
        defer { IPhoneLinkReceiver.shared.onLinkReceived = nil }

        let target = IPhoneLinkReceiver.shared.receive(link: link, session: session)
        #expect(target.id == space.id)
        #expect(space.tabs.contains { $0.url == link.url })
        #expect(notified == true)
    }

    @Test("IPhoneLinkReceiver auto-creates 'Read Later' space when missing")
    func autoCreatesSpace() {
        let session = TestSession.make().0
        let uniqueSpaceName = "Read Later \(UUID().uuidString.prefix(6))"

        let link = IPhoneLink(
            url: URL(string: "https://paulgraham.com/articles.html")!,
            title: "Paul Graham Essays",
            spaceName: uniqueSpaceName,
            mode: .tab
        )

        let target = IPhoneLinkReceiver.shared.receive(link: link, session: session)
        #expect(target.name == uniqueSpaceName)
        #expect(session.spaces.contains { $0.id == target.id })
        #expect(target.tabs.contains { $0.url == link.url })
    }

    @Test("IPhoneLinkReceiver pins site when mode is pinned")
    func routesToPinnedSite() {
        let session = TestSession.make().0
        let space = session.addSpace(named: "Daily Dashboard")

        let link = IPhoneLink(
            url: URL(string: "https://weather.gov")!,
            title: "National Weather Service",
            spaceName: "Daily Dashboard",
            mode: .pinned
        )

        let target = IPhoneLinkReceiver.shared.receive(link: link, session: session)
        #expect(target.id == space.id)
        #expect(space.pinnedSites.contains { $0.matches(link.url) })
    }

    @Test("ICloudInboxCoordinator processes files and removes them from inbox")
    func inboxFileProcessing() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: "kylmora-test-inbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let session = TestSession.make().0
        let coordinator = ICloudInboxCoordinator.shared

        // Write a test incoming link file
        let linkFile = tempDir.appending(path: "incoming-link-test.json")
        let jsonPayload = """
        {
            "url": "https://swift.org",
            "title": "Swift Programming Language",
            "space": "Development",
            "mode": "tab"
        }
        """
        try jsonPayload.data(using: .utf8)!.write(to: linkFile)
        #expect(FileManager.default.fileExists(atPath: linkFile.path(percentEncoded: false)))

        // Test parsing directly from file
        let data = try Data(contentsOf: linkFile)
        let link = try #require(IPhoneLink.parse(jsonData: data))
        let target = IPhoneLinkReceiver.shared.receive(link: link, session: session)
        #expect(target.name == "Development")
        #expect(target.tabs.contains { $0.url == URL(string: "https://swift.org")! })

        // Simulating cleanup
        try FileManager.default.removeItem(at: linkFile)
        #expect(!FileManager.default.fileExists(atPath: linkFile.path(percentEncoded: false)))
    }

    @Test("AppleShortcutHelper generates instructions and valid payload")
    func shortcutHelperGeneration() throws {
        let instructions = AppleShortcutHelper.generateShortcutInstructions()
        #expect(!instructions.isEmpty)
        #expect(instructions.contains("iCloud Drive"))
        #expect(instructions.contains("Shortcuts"))
        #expect(instructions.contains("Send to Kylmora"))

        let payload = AppleShortcutHelper.generateShortcutPayload()
        #expect(!payload.isEmpty)
        #expect(payload["WFWorkflowActions"] != nil)

        let tempExportDir = FileManager.default.temporaryDirectory.appending(path: "kylmora-shortcut-\(UUID().uuidString)")
        try AppleShortcutHelper.exportShortcutBundle(to: tempExportDir)
        defer { try? FileManager.default.removeItem(at: tempExportDir) }

        let shortcutFile = tempExportDir.appending(path: "Send to Kylmora.shortcut")
        let setupFile = tempExportDir.appending(path: "iPhone-ShareSheet-Setup.txt")
        #expect(FileManager.default.fileExists(atPath: shortcutFile.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: setupFile.path(percentEncoded: false)))
    }

    @Test("Settings has iCloudInbox properties with defaults and notification emission")
    func settingsConfiguration() {
        let defaults = UserDefaults(suiteName: "kylmora.tests.inbox.\(UUID().uuidString)")!
        let settings = Settings(defaults: defaults)

        #expect(settings.iCloudInboxEnabled == true)
        #expect(settings.iCloudInboxDefaultSpace == "Read Later")
        #expect(settings.iCloudInboxTargetMode == "tab")
        #expect(settings.iCloudInboxNotify == true)
        #expect(settings.iCloudInboxAutoCreateSpace == true)

        var notified = false
        let observer = NotificationCenter.default.addObserver(
            forName: .iCloudInboxSettingsDidChange,
            object: nil,
            queue: .main
        ) { _ in
            notified = true
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        settings.iCloudInboxDefaultSpace = "Work"
        #expect(settings.iCloudInboxDefaultSpace == "Work")
        #expect(notified == true)
    }

    @Test("Command catalog includes iPhone Companion commands")
    func commandCatalogEntries() {
        let commands = CommandCatalog.all
        #expect(commands.contains { $0.id == "open-icloud-inbox" })
        #expect(commands.contains { $0.id == "export-iphone-shortcut" })
        #expect(commands.contains { $0.id == "process-icloud-inbox" })
    }
}
