import AppKit
import WebKit
import Foundation
import Testing
@testable import Kylmora

@Suite("Extension packages")
struct ExtensionPackageTests {
    private func temporaryRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "kylmora-ext-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makePackageFolder(in root: URL, wrapped: Bool) throws -> URL {
        let folder = root.appending(path: wrapped ? "source/inner" : "source", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest = """
            {"manifest_version": 3, "name": "Test Extension", "version": "1.2.3"}
            """
        try Data(manifest.utf8).write(to: folder.appending(path: "manifest.json"))
        return root.appending(path: "source", directoryHint: .isDirectory)
    }

    private func zip(_ folder: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", folder.path(percentEncoded: false), destination.path(percentEncoded: false)]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test("An unpacked folder is copied and its manifest read")
    func installsFolder() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makePackageFolder(in: root, wrapped: false)
        let id = UUID()
        let installed = try ExtensionPackage.install(from: source, id: id, under: root.appending(path: "extensions"))
        #expect(installed.lastPathComponent == id.uuidString)
        let summary = ExtensionPackage.manifestSummary(in: installed)
        #expect(summary?.name == "Test Extension")
        #expect(summary?.version == "1.2.3")
    }

    @Test("A zip whose contents sit one folder down still installs")
    func installsWrappedZip() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makePackageFolder(in: root, wrapped: true)
        let archive = root.appending(path: "package.zip")
        try zip(source, to: archive)
        let installed = try ExtensionPackage.install(from: archive, id: UUID(), under: root.appending(path: "extensions"))
        #expect(FileManager.default.fileExists(atPath: installed.appending(path: "manifest.json").path(percentEncoded: false)))
    }

    @Test("A CRX is a zip behind a header, for both header versions")
    func stripsCRXHeaders() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makePackageFolder(in: root, wrapped: false)
        let archive = root.appending(path: "package.zip")
        try zip(source, to: archive)
        let zipData = try Data(contentsOf: archive)

        var crx3 = Data("Cr24".utf8)
        crx3.append(contentsOf: [3, 0, 0, 0])
        let header = Data(repeating: 0xAB, count: 20)
        crx3.append(contentsOf: [20, 0, 0, 0])
        crx3.append(header)
        crx3.append(zipData)
        #expect(ExtensionPackage.zipData(fromCRX: crx3) == zipData)

        var crx2 = Data("Cr24".utf8)
        crx2.append(contentsOf: [2, 0, 0, 0])
        crx2.append(contentsOf: [4, 0, 0, 0])
        crx2.append(contentsOf: [2, 0, 0, 0])
        crx2.append(Data([1, 2, 3, 4]))
        crx2.append(Data([5, 6]))
        crx2.append(zipData)
        #expect(ExtensionPackage.zipData(fromCRX: crx2) == zipData)

        #expect(ExtensionPackage.zipData(fromCRX: zipData) == nil)

        let crxFile = root.appending(path: "package.crx")
        try crx3.write(to: crxFile)
        let installed = try ExtensionPackage.install(from: crxFile, id: UUID(), under: root.appending(path: "extensions"))
        #expect(ExtensionPackage.manifestSummary(in: installed)?.name == "Test Extension")
    }

    @Test("A package with no manifest is refused")
    func refusesWithoutManifest() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = root.appending(path: "empty", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(throws: ExtensionPackage.Failure.noManifest) {
            try ExtensionPackage.install(from: empty, id: UUID(), under: root.appending(path: "extensions"))
        }
    }

    @Test("The index round-trips")
    func indexRoundTrips() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = ExtensionIndex(root: root)
        #expect(index.load().isEmpty)
        let record = InstalledExtension(id: UUID(), name: "Test", version: "1", isEnabled: false, installedAt: .now)
        try index.save([record])
        let loaded = index.load()
        #expect(loaded.count == 1)
        #expect(loaded[0].id == record.id)
        #expect(loaded[0].isEnabled == false)
        #expect(index.folder(for: record).lastPathComponent == record.id.uuidString)
    }
}

@Suite("Extensions run through WebKit")
@MainActor
struct ExtensionRuntimeTests {
    /// A page load, awaited.
    private final class LoadWaiter: NSObject, WKNavigationDelegate {
        var continuation: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            continuation?.resume()
            continuation = nil
        }
    }

    @Test("A content script runs in a web view made with the controller")
    func contentScriptRuns() async throws {
        guard #available(macOS 15.4, *) else { return }
        let root = FileManager.default.temporaryDirectory
            .appending(path: "kylmora-ext-run-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("""
            {"manifest_version": 3, "name": "Marker", "version": "1", "description": "Marks the page.",
             "content_scripts": [{"matches": ["<all_urls>"], "js": ["content.js"], "run_at": "document_end"}],
             "host_permissions": ["<all_urls>"]}
            """.utf8).write(to: root.appending(path: "manifest.json"))
        try Data("document.documentElement.setAttribute('data-kylmora-marker', 'ran');".utf8)
            .write(to: root.appending(path: "content.js"))
        let marker = try await Self.markerAfterLoading(root)
        #expect(marker == "ran")
    }

    @available(macOS 15.4, *)
    private static func markerAfterLoading(_ root: URL) async throws -> String? {
        let ext = try await WKWebExtension(resourceBaseURL: root)
        #expect(ext.errors.isEmpty, Comment(rawValue: ext.errors.map(\.localizedDescription).joined(separator: " | ")))
        let context = WKWebExtensionContext(for: ext)
        context.uniqueIdentifier = "kylmora-test-marker"
        for pattern in ext.allRequestedMatchPatterns {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
        let controller = WKWebExtensionController(configuration: .nonPersistent())
        try controller.load(context)
        #expect(context.hasAccess(to: URL(string: "https://example.test/")!))
        #expect(context.hasInjectedContent(for: URL(string: "https://example.test/")!))

        let configuration = WKWebViewConfiguration()
        configuration.webExtensionController = controller
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let waiter = LoadWaiter()
        webView.navigationDelegate = waiter
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiter.continuation = continuation
            webView.loadHTMLString("<html><body>hello</body></html>", baseURL: URL(string: "https://example.test/"))
        }

        var marker: String?
        for _ in 0..<20 {
            marker = try await webView.evaluateJavaScript("document.documentElement.getAttribute('data-kylmora-marker')") as? String
            if marker == "ran" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try controller.unload(context)
        return marker
    }
}

@Suite("Extensions through Kylmora's own web environment")
@MainActor
struct ExtensionEnvironmentTests {
    private final class LoadWaiter: NSObject, WKNavigationDelegate {
        var continuation: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            continuation?.resume()
            continuation = nil
        }
    }

    @Test("An installed extension's content script runs in a web view made the way tabs make theirs")
    func installedExtensionRunsInKylmoraWebView() async throws {
        guard #available(macOS 15.4, *) else { return }
        let root = FileManager.default.temporaryDirectory
            .appending(path: "kylmora-ext-env-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appending(path: "package", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("""
            {"manifest_version": 3, "name": "Marker", "version": "1", "description": "Marks the page.",
             "content_scripts": [{"matches": ["<all_urls>"], "js": ["content.js"]}],
             "permissions": ["activeTab"], "host_permissions": ["<all_urls>"]}
            """.utf8).write(to: package.appending(path: "manifest.json"))
        try Data("document.documentElement.setAttribute('data-kylmora-marker', 'ran');".utf8)
            .write(to: package.appending(path: "content.js"))
        let marker = try await Self.run(package: package, index: root.appending(path: "extensions"))
        #expect(marker == "ran")
    }

    @available(macOS 15.4, *)
    private static func run(package: URL, index: URL) async throws -> String? {
        let manager = ExtensionManager(index: ExtensionIndex(root: index), controllerConfiguration: .nonPersistent())
        let record = try await manager.install(from: package)
        #expect(manager.entries.first { $0.id == record.id }?.problems == [])

        // The configuration every tab gets, with this manager's controller in
        // place of the shared one.
        let configuration = WebEnvironment.shared.makeConfiguration(for: .standard)
        configuration.webExtensionController = manager.controller
        let webView = WebEnvironment.shared.makeWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let waiter = LoadWaiter()
        webView.navigationDelegate = waiter
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiter.continuation = continuation
            webView.loadHTMLString("<html><body>hello</body></html>", baseURL: URL(string: "https://example.test/"))
        }
        var marker: String?
        for _ in 0..<20 {
            marker = try await webView.evaluateJavaScript("document.documentElement.getAttribute('data-kylmora-marker')") as? String
            if marker == "ran" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        manager.remove(record.id)
        return marker
    }
}

@Suite("Chrome Web Store links")
struct ChromeWebStoreTests {
    private let id = "eimadpbcbfnmbkopoojfekhnkhdbieeh"

    @Test("The ID is read from both link forms, a bare ID, and nothing else")
    func parsesLinks() {
        #expect(ChromeWebStore.extensionID(from: "https://chromewebstore.google.com/detail/dark-reader/\(id)") == id)
        #expect(ChromeWebStore.extensionID(from: "https://chromewebstore.google.com/detail/\(id)?hl=en") == id)
        #expect(ChromeWebStore.extensionID(from: "https://chrome.google.com/webstore/detail/dark-reader/\(id)/related") == id)
        #expect(ChromeWebStore.extensionID(from: "  \(id.uppercased())  ") == id)
        #expect(ChromeWebStore.extensionID(from: "https://example.com/detail/\(id)") == nil)
        #expect(ChromeWebStore.extensionID(from: "dark reader") == nil)
        #expect(ChromeWebStore.extensionID(from: "https://chromewebstore.google.com/detail/dark-reader/not-an-id") == nil)
        // A hexadecimal hash written in letters: q and beyond never appear.
        #expect(ChromeWebStore.isID("qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq") == false)
    }

    @Test("The download address carries the ID the way the store expects")
    func downloadAddress() {
        let url = ChromeWebStore.downloadURL(for: id)
        #expect(url.host() == "clients2.google.com")
        #expect(url.absoluteString.contains("id%3D\(id)"))
        #expect(url.absoluteString.contains("acceptformat=crx2,crx3"))
    }
}

@Suite("Firefox add-on links")
struct FirefoxAddonsTests {
    @Test("The slug is read from a link in any language, or taken bare")
    func parsesLinks() {
        #expect(FirefoxAddons.slug(from: "https://addons.mozilla.org/en-US/firefox/addon/darkreader/") == "darkreader")
        #expect(FirefoxAddons.slug(from: "https://addons.mozilla.org/de/firefox/addon/ublock-origin/?utm_source=x") == "ublock-origin")
        #expect(FirefoxAddons.slug(from: "https://addons.mozilla.org/firefox/addon/darkreader") == "darkreader")
        #expect(FirefoxAddons.slug(from: "darkreader") == "darkreader")
        #expect(FirefoxAddons.slug(from: "https://example.com/firefox/addon/darkreader/") == nil)
        #expect(FirefoxAddons.slug(from: "https://addons.mozilla.org/en-US/firefox/") == nil)
        #expect(FirefoxAddons.slug(from: "not a slug at all!") == nil)
    }

    @Test("The package address comes from the record in either shape the API has used")
    func packageAddress() {
        let current = Data("""
            {"current_version": {"version": "1", "file": {"url": "https://addons.mozilla.org/firefox/downloads/file/1/a.xpi"}}}
            """.utf8)
        #expect(FirefoxAddons.packageURL(fromRecord: current)?.lastPathComponent == "a.xpi")
        let older = Data("""
            {"current_version": {"version": "1", "files": [{"url": "https://addons.mozilla.org/firefox/downloads/file/2/b.xpi"}]}}
            """.utf8)
        #expect(FirefoxAddons.packageURL(fromRecord: older)?.lastPathComponent == "b.xpi")
        #expect(FirefoxAddons.packageURL(fromRecord: Data("{}".utf8)) == nil)
    }
}

/// Real downloads from both stores. Off unless asked for, because the suite
/// must not need the network; run with `KYLMORA_NETWORK_TESTS=1`.
@Suite("Store downloads, against the real stores", .enabled(if: ProcessInfo.processInfo.environment["KYLMORA_NETWORK_TESTS"] == "1"))
@MainActor
struct StoreNetworkTests {
    @Test("Dark Reader installs from Firefox Add-ons and loads without errors")
    func firefoxDarkReader() async throws {
        guard #available(macOS 15.4, *) else { return }
        let root = FileManager.default.temporaryDirectory
            .appending(path: "kylmora-ext-amo-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ExtensionManager(index: ExtensionIndex(root: root), controllerConfiguration: .nonPersistent())
        let record = try await manager.install(fromFirefoxAddons: "https://addons.mozilla.org/en-US/firefox/addon/darkreader/")
        let entry = try #require(manager.entries.first { $0.id == record.id })
        #expect(entry.displayName == "Dark Reader")
        #expect(entry.problems.isEmpty, Comment(rawValue: entry.problems.joined(separator: " | ")))
        #expect(record.firefoxSlug == "darkreader")
        manager.remove(record.id)
    }

    @Test("Dark Reader installs from the Chrome Web Store and loads without errors")
    func chromeDarkReader() async throws {
        guard #available(macOS 15.4, *) else { return }
        let root = FileManager.default.temporaryDirectory
            .appending(path: "kylmora-ext-cws-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ExtensionManager(index: ExtensionIndex(root: root), controllerConfiguration: .nonPersistent())
        let record = try await manager.install(fromChromeWebStore: "https://chromewebstore.google.com/detail/dark-reader/eimadpbcbfnmbkopoojfekhnkhdbieeh")
        let entry = try #require(manager.entries.first { $0.id == record.id })
        #expect(entry.displayName == "Dark Reader")
        #expect(entry.problems.isEmpty, Comment(rawValue: entry.problems.joined(separator: " | ")))
        manager.remove(record.id)
    }
}
