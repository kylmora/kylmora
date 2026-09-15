import Testing
import AppKit
import WebKit
@testable import Kylmora

private final class MockMenuDelegate: NSObject, NSMenuDelegate {}

@Suite("Screenshots and Page Capture (F-18)")
@MainActor
struct ScreenshotTests {

    @Test("Filename generation sanitizes page titles and generates clean names")
    func testFilenameGeneration() {
        let fixedDate = Date(timeIntervalSince1970: 1700000000)
        let name = ScreenshotService.generateFilename(title: "My Site / Documentation: Guide?", timestamp: fixedDate)
        #expect(!name.contains("/"))
        #expect(!name.contains(":"))
        #expect(!name.contains("?"))
        #expect(name.hasSuffix(".png"))
        #expect(name.contains("My Site Documentation Guide"))

        // Nil / empty title fallback
        let fallback = ScreenshotService.generateFilename(title: "", timestamp: fixedDate)
        #expect(fallback.hasPrefix("Screenshot "))
        #expect(fallback.hasSuffix(".png"))
    }

    @Test("Filename sanitization strips illegal filesystem characters and collapses whitespace")
    func testSanitization() {
        let raw = "Test  \\ / : * ? \" < > | # % &  Page Name "
        let sanitized = ScreenshotService.sanitizeFilename(raw)
        #expect(sanitized == "Test Page Name")
    }

    @Test("PNG data conversion produces valid PNG format bytes")
    func testPNGConversion() {
        let image = NSImage(size: NSSize(width: 50, height: 50))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 50, height: 50).fill()
        image.unlockFocus()

        let pngData = ScreenshotService.pngData(from: image)
        #expect(pngData != nil)
        #expect((pngData?.count ?? 0) > 8)

        // Standard PNG 8-byte header: 137 80 78 71 13 10 26 10
        if let data = pngData {
            let header = [UInt8](data.prefix(8))
            #expect(header == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        }
    }

    @Test("Copying screenshot to clipboard sets image and PNG data on general pasteboard")
    func testClipboardCopy() {
        let image = NSImage(size: NSSize(width: 20, height: 20))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 20, height: 20).fill()
        image.unlockFocus()

        ScreenshotService.copyImageToClipboard(image: image)

        let pboard = NSPasteboard.general
        let types = pboard.types ?? []
        #expect(types.contains(.png) || types.contains(.tiff))
    }

    @Test("Saving screenshot to disk creates file and avoids filename collisions")
    func testSaveImageToDisk() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let image = NSImage(size: NSSize(width: 40, height: 40))
        image.lockFocus()
        NSColor.green.setFill()
        NSRect(x: 0, y: 0, width: 40, height: 40).fill()
        image.unlockFocus()

        let file1 = try ScreenshotService.saveImageToDownloads(
            image: image,
            tabTitle: "CollisionTest",
            url: nil,
            customDirectory: tempDir
        )
        #expect(FileManager.default.fileExists(atPath: file1.path))
        #expect(((try? Data(contentsOf: file1))?.count ?? 0) > 0)

        // Save again with same title: must create unique name with (1)
        let file2 = try ScreenshotService.saveImageToDownloads(
            image: image,
            tabTitle: "CollisionTest",
            url: nil,
            customDirectory: tempDir
        )
        #expect(file1 != file2)
        #expect(FileManager.default.fileExists(atPath: file2.path))
        #expect(file2.lastPathComponent.contains("(1)"))
    }

    @Test("CommandCatalog includes screenshot candidates")
    func testCommandCatalogCandidates() {
        let ids = CommandCatalog.all.map(\.id)
        #expect(ids.contains("capture-visible-area"))
        #expect(ids.contains("copy-visible-area"))
        #expect(ids.contains("capture-full-page"))
        #expect(ids.contains("copy-full-page"))
    }

    @Test("ShortcutManager defines configurable shortcuts for screenshot actions")
    func testShortcutManagerDefinitions() {
        let manager = ShortcutManager.shared
        #expect(manager.definition(for: "capture-visible-area") != nil)
        #expect(manager.definition(for: "copy-visible-area") != nil)
        #expect(manager.definition(for: "capture-full-page") != nil)
        #expect(manager.definition(for: "copy-full-page") != nil)
    }

    @Test("MainMenu contains Capture Screenshot submenu under File menu")
    func testMainMenuSubmenu() {
        let mock = MockMenuDelegate()
        let menu = MainMenu.build(
            bookmarks: mock,
            history: mock,
            tabs: mock,
            pinnedSites: mock,
            spaces: mock
        )
        let fileMenu = menu.items.first(where: { $0.title == "File" })
        let screenshotItem = fileMenu?.submenu?.items.first(where: { $0.title == "Capture Screenshot" })
        #expect(screenshotItem != nil)
        let subItems = screenshotItem?.submenu?.items.map(\.title) ?? []
        #expect(subItems.contains("Capture Visible Area"))
        #expect(subItems.contains("Copy Visible Area to Clipboard"))
        #expect(subItems.contains("Capture Full Page"))
        #expect(subItems.contains("Copy Full Page to Clipboard"))
    }

    @Test("GlanceWebView adds Capture Screenshot submenu to context menu")
    func testGlanceWebViewContextMenu() {
        let webView = GlanceWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let menu = NSMenu()
        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: NSPoint(x: 50, y: 50),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1.0
        )!

        webView.willOpenMenu(menu, with: event)
        let screenshotItem = menu.items.first(where: { $0.title == "Capture Screenshot" })
        #expect(screenshotItem != nil)
        let titles = screenshotItem?.submenu?.items.map(\.title) ?? []
        #expect(titles.contains("Capture Visible Area"))
        #expect(titles.contains("Copy Visible Area to Clipboard"))
        #expect(titles.contains("Capture Full Page"))
        #expect(titles.contains("Copy Full Page to Clipboard"))
    }

    @Test("Capturing visible area snapshot on a loaded web view yields valid image")
    func testLiveWebViewSnapshot() async throws {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let html = "<html><body style='background-color: blue;'><h1>Kylmora</h1></body></html>"
        webView.loadHTMLString(html, baseURL: nil)

        // Allow runloop a cycle for view setup
        try? await Task.sleep(nanoseconds: 150_000_000)

        let image = try await ScreenshotService.capture(webView: webView, scope: .visible)
        #expect(image.size.width > 0)
        #expect(image.size.height > 0)
    }
}
