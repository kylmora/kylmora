import Foundation

/// The current page as text for pasting somewhere else.
enum LinkFormatter {
    /// `[Title](https://…)`, with the characters Markdown would misread
    /// escaped. A page with no title uses its address as the text.
    static func markdown(title: String?, url: URL) -> String {
        let address = url.absoluteString
        var text = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty { text = address }
        text = text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        let target = address.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
        return "[\(text)](\(target))"
    }

    /// Title on one line, address on the next: how a link is pasted into a
    /// message or a note.
    static func titleAndURL(title: String?, url: URL) -> String {
        let text = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? url.absoluteString : "\(text)\n\(url.absoluteString)"
    }
}
