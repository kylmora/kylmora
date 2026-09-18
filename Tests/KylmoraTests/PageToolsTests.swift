import AppKit
import Foundation
import Testing
import WebKit
@testable import Kylmora

@Suite("Print, export, view source, copy as text")
@MainActor
struct PageToolsTests {
    @Test("The print job is named after the page, then its host, then 'Page'")
    func jobTitle() {
        #expect(PagePrinting.jobTitle(title: " Release notes ", url: URL(string: "https://kylmora.com/x")) == "Release notes")
        #expect(PagePrinting.jobTitle(title: "", url: URL(string: "https://kylmora.com/x")) == "kylmora.com")
        #expect(PagePrinting.jobTitle(title: nil, url: nil) == "Page")
    }

    @Test("The suggested PDF name is safe for the file system")
    func pdfName() {
        #expect(PagePrinting.suggestedPDFName(title: "Q3 / Plan: draft?", url: nil) == "Q3 - Plan- draft-.pdf")
        #expect(PagePrinting.suggestedPDFName(title: nil, url: URL(string: "https://example.org/a")) == "example.org.pdf")
        #expect(PagePrinting.suggestedPDFName(title: "...", url: nil) == "Page.pdf")
        let long = String(repeating: "x", count: 200)
        #expect(PagePrinting.suggestedPDFName(title: long, url: nil).count == 84)
    }

    @Test("The print operation gets a sized view, so it does not print blank pages")
    func printOperationIsSized() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let webView = WKWebView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(webView)
        // Nothing loaded: nothing to print, and the action says so instead
        // of running an empty job.
        #expect(PagePrinting.operation(for: webView) == nil)

        webView.loadHTMLString("<html><head><title>Print me</title></head><body><p>Text</p></body></html>", baseURL: nil)
        for _ in 0..<200 where webView.isLoading { try await Task.sleep(for: .milliseconds(25)) }
        // The title is published separately from the load finishing, so a
        // fixed pause here is a race: on a loaded CI runner it ran out while
        // the web view still reported no title, and the job was named by the
        // fallback ("Page") rather than by the page.
        for _ in 0..<200 where (webView.title ?? "").isEmpty {
            try await Task.sleep(for: .milliseconds(25))
        }

        let operation = try #require(PagePrinting.operation(for: webView))
        #expect(operation.view?.frame.size == NSSize(width: 640, height: 480))
        #expect(operation.showsPrintPanel)
        #expect(operation.printInfo.horizontalPagination == .fit)
        #expect(operation.jobTitle == "Print me")
    }

    @Test("Export as PDF produces a PDF of the page")
    func exportPDF() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let webView = WKWebView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(webView)
        webView.loadHTMLString("<html><body><h1>Hello PDF</h1><p>Some text.</p></body></html>", baseURL: nil)
        for _ in 0..<200 where webView.isLoading { try await Task.sleep(for: .milliseconds(25)) }
        try await Task.sleep(for: .milliseconds(100))

        let data = try await PagePrinting.pdfData(of: webView)
        #expect(data.count > 100)
        #expect(String(decoding: data.prefix(5), as: UTF8.self) == "%PDF-")
    }

    @Test("View Source escapes markup and numbers every line")
    func pageSource() throws {
        let html = "<html>\n<body class=\"a\">&amp; <b>x</b></body>\n</html>"
        let rendered = PageSource.render(source: html, of: URL(string: "https://example.org/page"))
        #expect(rendered.contains("<title>Source of https://example.org/page</title>"))
        #expect(rendered.contains("3 lines"))
        #expect(rendered.contains("&lt;body class=&quot;a&quot;&gt;&amp;amp; &lt;b&gt;x&lt;/b&gt;"))
        // The page's own tags never survive as tags.
        #expect(!rendered.contains("<body class=\"a\">"))
        #expect(rendered.components(separatedBy: "<li>").count - 1 == 3)

        let file = try PageSource.write(source: html, of: URL(string: "https://example.org/page"))
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(file.pathExtension == "html")
        #expect(file.lastPathComponent.hasPrefix("example.org-"))
        #expect(try String(contentsOf: file, encoding: .utf8).contains("Source of https://example.org/page"))
    }

    @Test("Copy as Markdown and as title-and-address")
    func linkFormats() {
        let url = URL(string: "https://en.wikipedia.org/wiki/Foo_(bar)")!
        #expect(LinkFormatter.markdown(title: "Foo [bar]", url: url) == "[Foo \\[bar\\]](https://en.wikipedia.org/wiki/Foo_%28bar%29)")
        #expect(LinkFormatter.markdown(title: "  ", url: URL(string: "https://a.b/")!) == "[https://a.b/](https://a.b/)")
        #expect(LinkFormatter.titleAndURL(title: "Kylmora", url: URL(string: "https://kylmora.com")!) == "Kylmora\nhttps://kylmora.com")
        #expect(LinkFormatter.titleAndURL(title: nil, url: URL(string: "https://kylmora.com")!) == "https://kylmora.com")
    }

    @Test("Print is in the File menu on ⌘P, with Page Setup and Export as PDF beside it")
    func fileMenu() {
        let stub = MenuDelegateStub()
        let menu = MainMenu.build(bookmarks: stub, history: stub, tabs: stub, pinnedSites: stub, spaces: stub)
        let file = menu.items.first(where: { $0.title == "File" })?.submenu
        let print = file?.items.first(where: { $0.title == "Print\u{2026}" })
        #expect(print?.keyEquivalent == "p")
        #expect(print?.keyEquivalentModifierMask == [.command])
        #expect(print?.action == #selector(BrowserWindowController.printPage(_:)))
        #expect(file?.items.contains(where: { $0.title == "Page Setup\u{2026}" }) == true)
        #expect(file?.items.contains(where: { $0.title == "Export as PDF\u{2026}" }) == true)

        let edit = menu.items.first(where: { $0.title == "Edit" })?.submenu
        #expect(edit?.items.contains(where: { $0.title == "Copy as Markdown Link" }) == true)
        #expect(edit?.items.contains(where: { $0.title == "Copy Title and URL" }) == true)

        // Nothing else in the menu bar claims ⌘P.
        var holders: [String] = []
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if item.keyEquivalent == "p", item.keyEquivalentModifierMask == [.command] { holders.append(item.title) }
                if let sub = item.submenu { walk(sub) }
            }
        }
        walk(menu)
        #expect(holders == ["Print\u{2026}"])
    }

    @Test("The palette and the shortcut list know the new commands, and the window answers them")
    func commandsAreWired() {
        for id in ["print-page", "export-pdf", "view-source", "copy-markdown-link", "copy-title-url"] {
            #expect(CommandCatalog.all.contains(where: { $0.id == id }), "\(id) missing from the palette")
        }
        for id in ["print-page", "export-pdf", "view-source", "copy-markdown-link"] {
            let definition = ShortcutManager.shared.definition(for: id)
            #expect(definition != nil, "\(id) missing from shortcuts")
            if let definition {
                #expect(BrowserWindowController.instancesRespond(to: definition.selector), "\(id) has no action")
            }
        }
        #expect(ShortcutManager.shared.definition(for: "print-page")?.defaultDisplayString == "⌘P")
    }
}
