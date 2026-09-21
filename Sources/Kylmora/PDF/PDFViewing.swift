import Foundation
import WebKit

/// What to do with a PDF a page navigates to, and the fetch that feeds the
/// viewer.
///
/// WebKit can show a PDF itself, but its viewer has no thumbnails, search
/// box or page control an embedding browser can reach. Kylmora's own viewer
/// needs the bytes, and the only fetch that carries the tab's cookies is a
/// WebKit download of the same response. So a PDF navigation becomes a
/// download to a temporary file, and the tab shows that file in PDFKit.
enum PDFViewing {
    /// The per-site choices, as stored in `SiteSettingCategory.pdfDocuments`.
    enum Handling: String, CaseIterable, Sendable {
        /// Kylmora's viewer, in the tab.
        case viewer
        /// WebKit's own viewer, in the tab.
        case webkit
        /// Save to the downloads folder like any other file.
        case download
        /// Fetch it and hand it to Preview (or whatever opens PDFs).
        case preview
    }

    /// Whether `response` is a PDF document for the tab's own frame.
    ///
    /// Main-actor only: `WKNavigationResponse`'s own properties are, and this
    /// reads them. The `mimeType`/`url` overload below stays callable from
    /// anywhere -- it only touches the two values it is handed.
    @MainActor
    static func isPDF(_ response: WKNavigationResponse) -> Bool {
        guard response.isForMainFrame else { return false }
        return isPDF(mimeType: response.response.mimeType, url: response.response.url)
    }

    static func isPDF(mimeType: String?, url: URL?) -> Bool {
        if let mimeType = mimeType?.lowercased() {
            if mimeType == "application/pdf" || mimeType == "application/x-pdf" { return true }
            if mimeType != "application/octet-stream" { return false }
        }
        return url?.pathExtension.lowercased() == "pdf"
    }

    /// Where a fetched PDF lives while a tab shows it. One folder per fetch,
    /// so the file keeps its own name and two tabs never collide.
    static func temporaryFile(named suggestedName: String) -> URL {
        let safe = DownloadDestination.sanitized(suggestedName)
        let name = safe.lowercased().hasSuffix(".pdf") ? safe : safe + ".pdf"
        return FileManager.default.temporaryDirectory
            .appending(path: "Kylmora PDFs", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: name)
    }
}

/// The delegate for one inline PDF fetch. Writes the file where
/// `PDFViewing.temporaryFile` says and reports the outcome to the tab.
final class InlinePDFDownload: NSObject, WKDownloadDelegate {
    let url: URL
    private var destination: URL?
    private let onFinish: @MainActor (URL) -> Void
    private let onFail: @MainActor (Error) -> Void

    init(url: URL, onFinish: @escaping @MainActor (URL) -> Void, onFail: @escaping @MainActor (Error) -> Void) {
        self.url = url
        self.onFinish = onFinish
        self.onFail = onFail
    }

    @MainActor
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping @MainActor (URL?) -> Void
    ) {
        let file = PDFViewing.temporaryFile(named: suggestedFilename)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            destination = file
            completionHandler(file)
        } catch {
            completionHandler(nil)
            onFail(error)
        }
    }

    @MainActor
    func download(
        _ download: WKDownload,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        completionHandler(.performDefaultHandling, nil)
    }

    @MainActor
    func downloadDidFinish(_ download: WKDownload) {
        guard let destination else { return }
        onFinish(destination)
    }

    @MainActor
    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        onFail(error)
    }
}
