import AppKit
import Foundation
import Testing
@testable import Kylmora

private func temporaryDirectory() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "kylmora-webapp-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite("Web Applications (SSB)")
@MainActor
struct WebAppTests {

    @Test("InstalledWebApp encodes and decodes JSON correctly")
    func webAppCodable() throws {
        let app = InstalledWebApp(
            id: UUID(),
            name: "GitHub",
            url: URL(string: "https://github.com")!,
            spaceID: UUID(),
            appBundlePath: "/Applications/GitHub.app",
            iconPath: "/path/to/icon.png",
            dateInstalled: Date()
        )

        let data = try JSONEncoder().encode(app)
        let decoded = try JSONDecoder().decode(InstalledWebApp.self, from: data)

        #expect(decoded.id == app.id)
        #expect(decoded.name == "GitHub")
        #expect(decoded.url == URL(string: "https://github.com")!)
        #expect(decoded.spaceID == app.spaceID)
        #expect(decoded.appBundlePath == "/Applications/GitHub.app")
        #expect(decoded.iconPath == "/path/to/icon.png")
    }

    @Test("WebAppStore manages persistence and lookups")
    func webAppStoreCRUD() {
        let tempDir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storeFile = tempDir.appending(path: "webapps.json")
        let store = WebAppStore(fileURL: storeFile)

        #expect(store.apps.isEmpty)

        let app1 = InstalledWebApp(
            id: UUID(),
            name: "Slack",
            url: URL(string: "https://app.slack.com")!
        )
        let app2 = InstalledWebApp(
            id: UUID(),
            name: "Linear",
            url: URL(string: "https://linear.app")!
        )

        store.add(app1)
        store.add(app2)

        #expect(store.apps.count == 2)
        #expect(store.app(for: app1.id)?.name == "Slack")
        #expect(store.app(for: URL(string: "https://linear.app/issue/123")!)?.name == "Linear")

        // Reload fresh from disk
        let reloadedStore = WebAppStore(fileURL: storeFile)
        #expect(reloadedStore.apps.count == 2)
        #expect(reloadedStore.app(for: app1.id)?.name == "Slack")

        store.remove(id: app1.id)
        #expect(store.apps.count == 1)
        #expect(store.app(for: app1.id) == nil)
    }

    @Test("WebAppGenerator creates valid macOS application bundle")
    func webAppBundleGeneration() throws {
        let tempDir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let app = InstalledWebApp(
            id: UUID(),
            name: "Notion HQ",
            url: URL(string: "https://notion.so")!,
            spaceID: UUID()
        )

        let bundleURL = try WebAppGenerator.createAppBundle(
            app: app,
            destinationDirectory: tempDir
        )

        let fileManager = FileManager.default
        #expect(fileManager.fileExists(atPath: bundleURL.path(percentEncoded: false)))

        // Verify Info.plist
        let plistURL = bundleURL.appending(path: "Contents/Info.plist")
        #expect(fileManager.fileExists(atPath: plistURL.path(percentEncoded: false)))

        let plistData = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        #expect(plist != nil)
        #expect(plist?["CFBundleName"] as? String == "Notion HQ")
        #expect(plist?["CFBundleExecutable"] as? String == "launcher")
        #expect(plist?["KylmoraWebAppURL"] as? String == "https://notion.so")
        #expect(plist?["KylmoraWebAppID"] as? String == app.id.uuidString)

        // Verify launcher executable
        let launcherURL = bundleURL.appending(path: "Contents/MacOS/launcher")
        #expect(fileManager.fileExists(atPath: launcherURL.path(percentEncoded: false)))

        let attrs = try fileManager.attributesOfItem(atPath: launcherURL.path(percentEncoded: false))
        let permissions = attrs[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o755)

        let scriptContent = try String(contentsOf: launcherURL, encoding: .utf8)
        #expect(scriptContent.contains("https://notion.so"))
        #expect(scriptContent.contains("kylmora-webapp://open"))

        // Verify AppIcon
        let iconURL = bundleURL.appending(path: "Contents/Resources/AppIcon.icns")
        #expect(fileManager.fileExists(atPath: iconURL.path(percentEncoded: false)))
    }

    @Test("WebAppGenerator safely sanitizes filenames and bundle IDs")
    func filenameSanitization() {
        #expect(WebAppGenerator.sanitizeFilename("My / App: Special*") == "My - App- Special-")
        #expect(WebAppGenerator.sanitizeFilename("") == "Web App")
        #expect(WebAppGenerator.safeBundleID(from: "Notion App 2026!") == "notionapp2026")
    }

    @Test("WebAppManager URL scheme and CLI argument parsing")
    func webAppDispatch() {
        let tempDir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = WebAppStore(fileURL: tempDir.appending(path: "webapps.json"))
        let manager = WebAppManager(store: store)

        // 1. URL Scheme with target url and name
        let urlScheme = URL(string: "kylmora-webapp://open?url=https%3A%2F%2Flinear.app&name=Linear")!
        let handled = manager.handleURLScheme(urlScheme)
        #expect(handled == true)
        #expect(manager.activeWindows.count == 1)

        let window = manager.activeWindows.values.first
        #expect(window?.app.name == "Linear")
        #expect(window?.app.url == URL(string: "https://linear.app")!)

        // 2. CLI arguments handling
        let args = ["Kylmora", "--web-app-url", "https://discord.com", "--web-app-name", "Discord"]
        let cliHandled = manager.handleCommandLineArguments(args)
        #expect(cliHandled == true)
        #expect(manager.activeWindows.count == 2)

        let discordWindow = manager.activeWindows.values.first { $0.app.name == "Discord" }
        #expect(discordWindow != nil)
        #expect(discordWindow?.app.url == URL(string: "https://discord.com")!)

        // Clean up open windows
        for win in manager.activeWindows.values {
            win.close()
        }
        #expect(manager.activeWindows.isEmpty)
    }

    @Test("WebAppTopBar updates navigation and display state accurately")
    func webAppTopBar() {
        let bar = WebAppTopBar()
        let testURL = URL(string: "https://github.com/pulls")!

        bar.update(
            title: "Pull Requests",
            url: testURL,
            canGoBack: true,
            canGoForward: false,
            isLoading: true,
            isDark: true
        )

        #expect(bar.titleLabel.stringValue == "Pull Requests")
        #expect(bar.hostLabel.stringValue == "github.com")
        #expect(bar.backButton.isEnabled == true)
        #expect(bar.forwardButton.isEnabled == false)
        #expect(bar.darkModeButton.isActive == true)
    }
}
