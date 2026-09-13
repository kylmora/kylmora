import Foundation

/// Turns a filename a web page suggested into a path Kylmora is willing to write.
///
/// This is the security boundary for downloads, so it is pure logic with the
/// file system injected: every rule below is a unit test rather than something
/// that has to be reproduced by clicking a malicious link. A page controls both
/// the URL and the `Content-Disposition` header, which means it controls the
/// string WebKit hands to `decideDestinationUsing:suggestedFilename:`. Treated
/// naively that string is a path traversal — `../../../.zshenv` is a perfectly
/// legal thing for a server to suggest.
enum DownloadDestination {
    /// Result of resolving a suggested name inside a directory.
    struct Resolution: Equatable {
        let url: URL
        /// True when the plain name was taken and a numbered variant was used.
        let renamed: Bool
    }

    /// What a name collapses to when the page suggests nothing usable.
    static let fallbackName = "download"

    /// APFS and HFS+ both cap a single name at 255 UTF-8 bytes. Anything longer
    /// fails at `open(2)`, so it is trimmed here where the extension can be
    /// preserved rather than in the middle of a write.
    static let maximumNameBytes = 255

    /// Reduces a page-supplied name to a single, safe path component.
    ///
    /// Order matters: separators are removed before the leading dots are, so
    /// `../..%2Fevil` cannot reassemble itself after trimming.
    static func sanitized(_ suggested: String) -> String {
        var name = suggested

        // A percent-encoded separator is still a separator once something else
        // decodes it, so decode first and then strip.
        if let decoded = name.removingPercentEncoding { name = decoded }

        // `/` is the POSIX separator and `:` is the Finder's; both are what a
        // traversal is built from. Splitting on them and dropping every empty
        // component, and every component that is only dots, removes the
        // directory references at the same time: `../../x` becomes `x`, not
        // `..-..-x`.
        let forbidden = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        name = name
            .components(separatedBy: forbidden)
            .filter { !$0.isEmpty && $0.contains { $0 != "." } }
            .joined(separator: "-")

        // A leading dot would still make the file invisible in Finder.
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !name.isEmpty else { return fallbackName }
        return truncated(name)
    }

    /// Trims to the file system's byte limit while keeping the extension, so a
    /// pathological name still opens with the right application.
    private static func truncated(_ name: String) -> String {
        guard name.utf8.count > maximumNameBytes else { return name }

        let suffix = (name as NSString).pathExtension
        // An "extension" of forty characters is not one; do not spend the
        // budget preserving it.
        let keptSuffix = suffix.utf8.count <= 16 && !suffix.isEmpty ? "." + suffix : ""
        var stem = String(name.dropLast(keptSuffix.isEmpty ? 0 : keptSuffix.count))

        while stem.utf8.count + keptSuffix.utf8.count > maximumNameBytes, !stem.isEmpty {
            stem.removeLast()
        }
        let result = stem + keptSuffix
        return result.isEmpty || result == keptSuffix ? fallbackName : result
    }

    /// Picks the file the download will be written to.
    ///
    /// `WKDownload` refuses a destination that already exists, so a name that is
    /// taken has to become a new one rather than an overwrite — which is also
    /// the behaviour that stops a page from clobbering a file the user already
    /// has. The numbered form is the platform's: a space and an index before
    /// the extension, starting at two, which is what Finder produces for a
    /// duplicate and what DuckDuckGo's browser reimplements to match it.
    ///
    /// Returns nil when the resolved path escapes `directory`. That should be
    /// impossible after `sanitized`, but it is checked rather than assumed:
    /// this is the one place a page could reach outside the Downloads folder.
    static func resolve(
        suggested: String,
        in directory: URL,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    ) -> Resolution? {
        let name = sanitized(suggested)
        let base = directory.standardizedFileURL

        guard let candidate = contained(name, in: base) else { return nil }
        if !exists(candidate) { return Resolution(url: candidate, renamed: false) }

        let stem = (name as NSString).deletingPathExtension
        let suffix = (name as NSString).pathExtension
        let extended = suffix.isEmpty ? "" : "." + suffix

        // Bounded rather than open-ended: a directory holding a thousand
        // variants of one name is a bug, not a user, and an unbounded loop here
        // would be a page-triggered hang.
        for counter in 2...1000 {
            let numbered = truncated("\(stem) \(counter)\(extended)")
            guard let url = contained(numbered, in: base) else { return nil }
            if !exists(url) { return Resolution(url: url, renamed: true) }
        }
        return nil
    }

    /// Appends one component and proves the result is still inside `directory`.
    private static func contained(_ name: String, in directory: URL) -> URL? {
        let url = directory.appending(path: name, directoryHint: .notDirectory).standardizedFileURL
        guard url.deletingLastPathComponent().standardizedFileURL.path() == directory.path(),
              url.lastPathComponent == name else { return nil }
        return url
    }

    /// The user's Downloads folder, created if it is missing.
    ///
    /// It normally exists, but it is an ordinary directory a user can delete,
    /// and a download failing because of that would be a confusing way to find
    /// out.
    static func downloadsDirectory(fileManager: FileManager = .default) -> URL? {
        guard let url = try? fileManager.url(
            for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        return url
    }
}
