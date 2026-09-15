import Foundation

/// "View Page Source": the page's markup shown as text, with line numbers,
/// in a tab of its own.
enum PageSource {
    /// The HTML that presents `source` (the page's markup) as a listing.
    static func render(source: String, of url: URL?) -> String {
        let subject = url?.absoluteString ?? "page"
        let lines = source.components(separatedBy: "\n")
        let listing = lines.map { "<li>\(escape($0.isEmpty ? " " : $0))</li>" }.joined(separator: "\n")
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta name="color-scheme" content="light dark">
        <title>Source of \(escape(subject))</title>
        <style>
        :root { color-scheme: light dark; }
        body { margin: 0; font: 12px/1.5 ui-monospace, Menlo, monospace; background: Canvas; color: CanvasText; }
        header { position: sticky; top: 0; padding: 8px 16px; border-bottom: 1px solid color-mix(in srgb, CanvasText 15%, transparent); background: Canvas; font: 12px -apple-system, system-ui; color: color-mix(in srgb, CanvasText 60%, transparent); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        ol { margin: 0; padding: 12px 16px 24px 5.5em; counter-reset: line; }
        li { list-style: none; counter-increment: line; white-space: pre-wrap; word-break: break-all; position: relative; }
        li::before { content: counter(line); position: absolute; left: -5em; width: 4em; text-align: right; color: color-mix(in srgb, CanvasText 35%, transparent); user-select: none; }
        </style></head>
        <body><header>Source of \(escape(subject)) · \(lines.count) lines</header>
        <ol>
        \(listing)
        </ol></body></html>
        """
    }

    /// Writes the listing to a file WebKit can open, and returns it.
    static func write(source: String, of url: URL?) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Kylmora Page Source", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = url?.host() ?? "page"
        let file = directory.appending(path: "\(stem)-\(UUID().uuidString.prefix(8)).html")
        try render(source: source, of: url).data(using: .utf8)?.write(to: file, options: .atomic)
        return file
    }

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(character)
            }
        }
        return out
    }
}
