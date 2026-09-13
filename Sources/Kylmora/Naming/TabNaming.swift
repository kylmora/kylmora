import Foundation

/// What a tab is called, as pure logic.
///
/// The interesting part of renaming is not the text field: it is the ladder
/// that decides which of three possible names a row shows, and the rule that an
/// empty box means "go back to the page title" rather than "call this tab
/// nothing". Both belong somewhere they can be tested without a sidebar, in the
/// same way `URLResolver` holds the omnibox decision.
enum TabNaming {
    /// A name longer than this is not a name, it is a paragraph pasted into the
    /// field by accident. The sidebar truncates anyway; the cap stops the
    /// session file from carrying the rest of it forever.
    static let maximumLength = 120

    /// Turns what the user typed into a name, or nil for "clear it".
    ///
    /// Whitespace is collapsed rather than merely trimmed: a name pasted from a
    /// page title often carries a newline or a run of spaces in the middle, and
    /// those draw as a gap the user cannot see the reason for.
    static func normalized(_ input: String) -> String? {
        let collapsed = input
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maximumLength))
    }

    /// The title to show for a tab.
    ///
    /// The custom name wins over everything, which is the entire point: it has
    /// to survive the page title changing under it, whether that is a
    /// navigation, a notification counter, or a single-page app rewriting
    /// `document.title` every few seconds.
    static func displayTitle(customName: String?, pageTitle: String?, url: URL) -> String {
        if let customName, !customName.isEmpty { return customName }
        if let pageTitle, !pageTitle.isEmpty { return pageTitle }
        if let host = url.host() { return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host }
        return url.absoluteString
    }
}
