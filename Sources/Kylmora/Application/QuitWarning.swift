import Foundation

/// What the quit warning says, if anything.
///
/// Pure, because the rule has three cases that matter -- nothing to lose, tabs
/// to lose, and pages that are not coming back -- and each of them should be
/// arguable in a test rather than by quitting the browser to see.
enum QuitWarning {
    /// The sentence to show, or nil when quitting costs the user nothing.
    ///
    /// One tab on a start page is nothing to lose, so it does not count. A
    /// Little Arc window does: its page is never restored, and a warning that
    /// counted only tabs while quietly dropping one would be a lie.
    static func message(tabs: Int, littleArcs: Int) -> String? {
        var sentences: [String] = []

        if tabs > 1 {
            sentences.append("\(tabs) tabs are open. They come back next time if restoring is on.")
        }
        switch littleArcs {
        case 0:
            break
        case 1:
            sentences.append("A Little Arc window is open. Its page is not kept.")
        default:
            sentences.append("\(littleArcs) Little Arc windows are open. Their pages are not kept.")
        }

        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }
}
