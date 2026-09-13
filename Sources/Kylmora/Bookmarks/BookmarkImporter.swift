import Foundation

/// Reads the bookmark files other browsers export.
///
/// Two formats cover every browser: the Netscape bookmark HTML that Safari,
/// Chrome, Firefox and Edge all export, and Chrome's own `Bookmarks` JSON
/// file. Both are read from a file the user picks, because a browser's
/// profile folder is not somewhere a sandboxed app can wander into on its
/// own -- and it should not be.
enum BookmarkImporter {
    struct Entry: Equatable, Sendable {
        let title: String
        let url: URL
        /// The folders the bookmark sat under in the source, outermost first;
        /// empty at the top level. Kept so Kylmora can rebuild the tree the user
        /// had rather than flatten it.
        let folderPath: [String]

        init(title: String, url: URL, folderPath: [String] = []) {
            self.title = title
            self.url = url
            self.folderPath = folderPath
        }
    }

    enum Failure: Error, Equatable {
        case unreadable
        case unrecognised
    }

    /// Whatever the file turns out to be.
    static func entries(in data: Data) throws -> [Entry] {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let roots = json["roots"] as? [String: Any] {
            return chromeEntries(roots: roots)
        }
        let text = String(decoding: data, as: UTF8.self)
        guard text.range(of: "<a ", options: .caseInsensitive) != nil || text.range(of: "<dl", options: .caseInsensitive) != nil else {
            throw Failure.unrecognised
        }
        return htmlEntries(text)
    }

    /// Chrome's `Bookmarks`: folders of `children`, leaves of type `url`. The
    /// bookmarks-bar contents come in at the top level, as a bar's do; the
    /// "other" and "synced" roots keep a folder of their own so nothing from
    /// them lands loose among the bar's.
    static func chromeEntries(roots: [String: Any]) -> [Entry] {
        var result: [Entry] = []
        func walk(_ node: [String: Any], path: [String]) {
            switch node["type"] as? String {
            case "url":
                if let text = node["url"] as? String, let url = URL(string: text),
                   url.scheme == "http" || url.scheme == "https" {
                    result.append(Entry(title: node["name"] as? String ?? text, url: url, folderPath: path))
                }
            case "folder":
                let name = node["name"] as? String ?? ""
                let childPath = name.isEmpty ? path : path + [name]
                for child in node["children"] as? [[String: Any]] ?? [] { walk(child, path: childPath) }
            default:
                break
            }
        }
        let starts: [(key: String, base: [String])] = [
            ("bookmark_bar", []), ("other", ["Other Bookmarks"]), ("synced", ["Mobile Bookmarks"])
        ]
        for start in starts {
            if let node = roots[start.key] as? [String: Any] {
                for child in node["children"] as? [[String: Any]] ?? [] { walk(child, path: start.base) }
            }
        }
        return result
    }

    /// Netscape bookmark HTML: `<DT><H3>Folder</H3>` opens a folder whose `<DL>`
    /// holds its bookmarks and closes with `</DL>`; `<DT><A HREF>` is a leaf.
    /// The tokens are read in order, a folder stack tracking the current path,
    /// so the tree Safari/Chrome/Firefox exported is kept rather than flattened.
    static func htmlEntries(_ html: String) -> [Entry] {
        var result: [Entry] = []
        // One alternation, matched in document order: a folder heading, a link,
        // or a list close. The document's outer `<DL>` has no `<H3>`, so its
        // closing `</DL>` is absorbed by the empty-stack guard below.
        let pattern = #"<h3[^>]*>(.*?)</h3>|<a\s[^>]*href\s*=\s*"([^"]+)"[^>]*>(.*?)</a>|</dl>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(html.startIndex..., in: html)
        var stack: [String] = []
        for match in regex.matches(in: html, range: range) {
            if let headingRange = Range(match.range(at: 1), in: html) {
                stack.append(plainText(String(html[headingRange])))
            } else if let hrefRange = Range(match.range(at: 2), in: html),
                      let titleRange = Range(match.range(at: 3), in: html) {
                guard let url = URL(string: String(html[hrefRange])),
                      url.scheme == "http" || url.scheme == "https" else { continue }
                let title = plainText(String(html[titleRange]))
                result.append(Entry(title: title.isEmpty ? url.absoluteString : title, url: url, folderPath: stack))
            } else if !stack.isEmpty {
                stack.removeLast()
            }
        }
        return result
    }

    /// Strips any tags and decodes entities from a heading or link's inner text.
    private static func plainText(_ html: String) -> String {
        decodeEntities(html.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }
}

/// When finished downloads leave the list.
enum DownloadRemoval: String, CaseIterable, Sendable {
    case manually
    case afterDay
    case onQuit
    case uponSuccess

    var title: String {
        switch self {
        case .manually: return "Manually"
        case .afterDay: return "After one day"
        case .onQuit: return "When Kylmora quits"
        case .uponSuccess: return "Upon successful download"
        }
    }

    /// Whether a row that finished at `finishedAt` should go now. "When
    /// Kylmora quits" is honoured at the next launch, like the cookie schedule.
    func removes(finishedAt: Date?, now: Date = .now, atLaunch: Bool) -> Bool {
        switch self {
        case .manually: return false
        case .onQuit: return atLaunch
        case .afterDay:
            guard let finishedAt else { return false }
            return now.timeIntervalSince(finishedAt) > 24 * 60 * 60
        case .uponSuccess: return true
        }
    }
}

/// Where downloads go.
enum DownloadLocation: String, CaseIterable, Sendable {
    case downloads
    case ask

    var title: String {
        switch self {
        case .downloads: return "Downloads"
        case .ask: return "Ask for each download"
        }
    }
}

/// Where a link from another app opens.
enum ExternalLinkTarget: String, CaseIterable, Sendable {
    case currentSpace
    case defaultSpace

    var title: String {
        switch self {
        case .currentSpace: return "Current space"
        case .defaultSpace: return "Default space"
        }
    }
}
