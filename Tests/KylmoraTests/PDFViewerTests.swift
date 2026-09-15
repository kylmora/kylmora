import AppKit
import Foundation
import PDFKit
import Testing
import WebKit
@testable import Kylmora

@Suite("PDF viewer")
@MainActor
struct PDFViewerTests {
    /// A real PDF with searchable text, rendered by WebKit into a temp file.
    private func makePDF(text: String = "Hello PDF world. Second sentence about apples.") async throws -> URL {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let webView = WKWebView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(webView)
        webView.loadHTMLString("<html><body><p>\(text)</p></body></html>", baseURL: nil)
        for _ in 0..<200 where webView.isLoading { try await Task.sleep(for: .milliseconds(25)) }
        try await Task.sleep(for: .milliseconds(100))
        let data = try await PagePrinting.pdfData(of: webView)
        let dir = FileManager.default.temporaryDirectory.appending(path: "kylmora-pdf-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "Quarterly report.pdf")
        try data.write(to: file)
        return file
    }

    @Test("A PDF is recognised by type, or by extension when the type is opaque")
    func recognition() {
        #expect(PDFViewing.isPDF(mimeType: "application/pdf", url: URL(string: "https://a.b/x")))
        #expect(PDFViewing.isPDF(mimeType: "Application/PDF", url: nil))
        #expect(PDFViewing.isPDF(mimeType: "application/octet-stream", url: URL(string: "https://a.b/file.PDF")))
        #expect(!PDFViewing.isPDF(mimeType: "application/octet-stream", url: URL(string: "https://a.b/file.zip")))
        #expect(!PDFViewing.isPDF(mimeType: "text/html", url: URL(string: "https://a.b/file.pdf")))
        #expect(PDFViewing.isPDF(mimeType: nil, url: URL(string: "https://a.b/file.pdf")))
    }

    @Test("The temporary file keeps the document's name, made safe, in a folder of its own")
    func temporaryFile() {
        let a = PDFViewing.temporaryFile(named: "../../etc/report")
        let b = PDFViewing.temporaryFile(named: "report.pdf")
        #expect(a.pathExtension == "pdf")
        #expect(!a.path.contains(".."))
        #expect(b.lastPathComponent == "report.pdf")
        #expect(a.deletingLastPathComponent() != b.deletingLastPathComponent())
        #expect(a.path.contains("Kylmora PDFs"))
    }

    @Test("A document is titled by its file name, or its host")
    func documentTitle() {
        #expect(TabDocument.title(for: URL(string: "https://a.b/docs/Annual%20Report.pdf")!) == "Annual Report")
        #expect(TabDocument.title(for: URL(string: "https://a.b/")!) == "a.b")
    }

    @Test("PDF Documents is a per-site setting that defaults to Kylmora's viewer")
    func siteSetting() {
        #expect(SiteSettingCategory.pdfDocuments.builtInDefault == "viewer")
        #expect(SiteSettingCategory.pdfDocuments.options.map(\.id) == PDFViewing.Handling.allCases.map(\.rawValue))
        #expect(!SiteSettingCategory.pdfDocuments.title.isEmpty)
        #expect(!SiteSettingCategory.pdfDocuments.instruction.isEmpty)
        let url = URL(string: "https://pdf-test.example/x.pdf")!
        let before = SiteSettings.shared.pdfHandling(for: url)
        SiteSettings.shared.update { $0.set("download", for: "pdf-test.example", in: .pdfDocuments) }
        #expect(SiteSettings.shared.pdfHandling(for: url) == .download)
        SiteSettings.shared.update { $0.set(before.rawValue, for: "pdf-test.example", in: .pdfDocuments) }
    }

    @Test("The viewer shows pages, moves between them and finds text")
    func viewer() async throws {
        let file = try await makePDF()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let document = try #require(PDFDocument(url: file))
        let view = PDFDocumentView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.showLoading(url: file)
        #expect(view.pageCount == 0)
        view.show(document, fileURL: file)
        #expect(view.pageCount == document.pageCount)
        #expect(view.currentPageNumber == 1)
        #expect(view.find("apples") == 1)
        #expect(view.find("zzzz-nothing") == 0)
        #expect(view.find("") == 0)
        #expect(!view.showsThumbnails)
        view.toggleThumbnails()
        #expect(view.showsThumbnails)
        view.showFailure("nope")
    }

    @Test("A tab showing a document reports its address and title, and drops it on the next load")
    func tabDocumentState() async throws {
        let file = try await makePDF()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let tab = Tab(url: URL(string: "https://example.com/page")!, identity: .standard)
        let pdfURL = URL(string: "https://example.com/files/Quarterly%20report.pdf")!

        tab.beginDocument(at: pdfURL)
        #expect(tab.document?.state == .loading)
        #expect(tab.isLoading)
        #expect(tab.displayURL == pdfURL)
        #expect(tab.documentView != nil)

        // The viewer's own copy lives in a folder that is deleted with it.
        let copyDir = FileManager.default.temporaryDirectory.appending(path: "kylmora-pdf-copy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: copyDir, withIntermediateDirectories: true)
        let copy = copyDir.appending(path: "Quarterly report.pdf")
        try FileManager.default.copyItem(at: file, to: copy)

        tab.documentArrived(at: copy, from: pdfURL)
        #expect(tab.document?.isReady == true)
        #expect(!tab.isLoading)
        #expect(tab.displayTitle == "Quarterly report")
        #expect(tab.documentView?.pageCount ?? 0 >= 1)
        let snapshot = tab.snapshot()
        #expect(snapshot.url == pdfURL)
        #expect(snapshot.title == "Quarterly report")
        #expect(snapshot.interactionState == nil)

        // A stale arrival for another address is ignored.
        tab.documentArrived(at: copy, from: URL(string: "https://example.com/other.pdf")!)
        #expect(tab.document?.url == pdfURL)

        tab.clearDocument()
        #expect(tab.document == nil)
        #expect(tab.documentView == nil)
        #expect(!FileManager.default.fileExists(atPath: copy.path))

        tab.beginDocument(at: pdfURL)
        tab.documentFailed(TabDocument.Failure.unreadable, from: pdfURL)
        if case .failed(let message) = tab.document?.state { #expect(message.contains("readable")) } else { Issue.record("expected failure") }
        tab.load(URL(string: "https://example.com/next")!)
        #expect(tab.document == nil)
    }

    @Test("Navigating a live tab to a PDF shows it in the viewer with the tab's address")
    func endToEnd() async throws {
        let file = try await makePDF()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = WebContainerView(frame: window.contentView!.bounds)
        container.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(container)

        let tab = Tab(url: file, identity: .standard)
        let webView = tab.webView()
        container.show(webView, document: tab.documentView, failure: nil, url: file, onRetry: nil)
        tab.load(file)

        for _ in 0..<400 where tab.document?.isReady != true {
            try await Task.sleep(for: .milliseconds(25))
        }
        let document = try #require(tab.document)
        #expect(document.isReady)
        #expect(document.url == file)
        #expect(tab.displayTitle == "Quarterly report")
        #expect(tab.displayURL == file)
        container.show(webView, document: tab.documentView, failure: nil, url: file, onRetry: nil)
        #expect(container.visibleContent === tab.documentView)
        #expect(tab.documentView?.pageCount ?? 0 >= 1)

        // Back returns to the page underneath, and the viewer goes away.
        tab.goBack()
        #expect(tab.document == nil)
        container.show(webView, document: tab.documentView, failure: nil, url: tab.displayURL, onRetry: nil)
        #expect(container.visibleContent === webView)
    }
}
