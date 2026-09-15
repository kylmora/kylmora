import AppKit
import WebKit

/// Printing a page, and saving it as a PDF, through WebKit's own layout.
@MainActor
enum PagePrinting {
    /// The print operation for `webView`, ready to run with the standard
    /// panel, or nil while the page has nothing WebKit can print yet (no
    /// document loaded, or a web view that is not on screen).
    ///
    /// WebKit hands back an operation whose print view has no size, and an
    /// unsized view prints as blank pages; giving it the web view's bounds is
    /// the documented way to make it paginate the page.
    static func operation(for webView: WKWebView, info: NSPrintInfo = .shared) -> NSPrintOperation? {
        guard webView.window != nil, webView.url != nil || webView.title?.isEmpty == false else { return nil }
        let printInfo = (info.copy() as? NSPrintInfo) ?? info
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isVerticallyCentered = false
        printInfo.isHorizontallyCentered = false
        let operation = webView.printOperation(with: printInfo)
        guard let view = operation.view else { return nil }
        view.frame = NSRect(origin: .zero, size: webView.bounds.size)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.jobTitle = jobTitle(title: webView.title, url: webView.url)
        return operation
    }

    /// The page rendered as a PDF by WebKit, whole and unpaginated.
    static func pdfData(of webView: WKWebView) async throws -> Data {
        try await webView.pdf()
    }

    /// The name the print system and the Save panel show: the page title,
    /// then the host, then "Page".
    static func jobTitle(title: String?, url: URL?) -> String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        if let host = url?.host(), !host.isEmpty { return host }
        return "Page"
    }

    /// A file name for the PDF: the job title with anything a file system
    /// dislikes replaced, kept to a sane length.
    static func suggestedPDFName(title: String?, url: URL?) -> String {
        var name = jobTitle(title: title, url: url)
        let disallowed = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines).union(.controlCharacters)
        name = String(String.UnicodeScalarView(name.unicodeScalars.map { disallowed.contains($0) ? "-" : $0 }))
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if name.count > 80 { name = String(name.prefix(80)) }
        if name.isEmpty { name = "Page" }
        return name + ".pdf"
    }
}
