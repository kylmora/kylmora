import Foundation

/// A document a tab shows in place of a web page. Only PDFs so far.
struct TabDocument: Equatable {
    enum State: Equatable {
        case loading
        case ready(fileURL: URL, pageCount: Int)
        case failed(String)
    }

    enum Failure: LocalizedError {
        case unreadable
        var errorDescription: String? { "The file is not a readable PDF." }
    }

    let url: URL
    let title: String
    var state: State

    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    /// The document's name for the sidebar: the file name without its
    /// extension, or the host when the address has no file name.
    static func title(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
            .removingPercentEncoding?.trimmingCharacters(in: .whitespaces) ?? ""
        if name.isEmpty || name == "/" { return url.host() ?? "PDF" }
        return name
    }
}
