import Foundation

/// What Kylmora can bring in from another browser.
enum ImportKind: Sendable {
    case bookmarks
    case history
    case tabs
    /// Logged-in sessions: another browser's cookies, so the sites the user is
    /// signed into stay signed in.
    case cookies
}

/// A browser Kylmora can import from, and how to reach its files.
///
/// Two shapes recur. A Chromium browser keeps its data in known files inside a
/// profile folder -- `Bookmarks` (JSON) and `History` (SQLite) -- so the open
/// panel can be pointed straight at them. Everything else is reached through an
/// export the user saves (bookmarks, as Netscape HTML) or is not reachable at
/// all (Safari's history lives in a container macOS protects).
///
/// Either way the file is one the *user* picks in an open panel: a sandboxed
/// app cannot wander into another browser's profile folder on its own (D60,
/// D62). This type only describes where to aim the panel and what to tell the
/// user; `BookmarkImporter` and `HistoryImporter` do the reading.
enum BrowserImportSource: String, CaseIterable, Sendable {
    case safari
    case chrome
    case edge
    case brave
    case firefox
    case htmlFile

    /// The name shown in the pop-up.
    var title: String {
        switch self {
        case .safari: return "Safari"
        case .chrome: return "Google Chrome"
        case .edge: return "Microsoft Edge"
        case .brave: return "Brave"
        case .firefox: return "Firefox"
        case .htmlFile: return "Bookmarks HTML file"
        }
    }

    /// The short name to drop into a sentence ("Imported 20 bookmarks from
    /// Chrome").
    var sentenceName: String {
        switch self {
        case .safari: return "Safari"
        case .chrome: return "Chrome"
        case .edge: return "Edge"
        case .brave: return "Brave"
        case .firefox: return "Firefox"
        case .htmlFile: return "the file"
        }
    }

    /// The profile folder, relative to home, that a Chromium browser keeps both
    /// its `Bookmarks` and `History` files in. Nil for the export browsers.
    var chromiumProfile: String? {
        switch self {
        case .chrome: return "Library/Application Support/Google/Chrome/Default"
        case .edge: return "Library/Application Support/Microsoft Edge/Default"
        case .brave: return "Library/Application Support/BraveSoftware/Brave-Browser/Default"
        case .safari, .firefox, .htmlFile: return nil
        }
    }

    /// Whether Kylmora can import this kind from this source at all. Safari's
    /// history is protected by macOS; an HTML file has no history in it; open
    /// tabs are only reachable from Firefox's documented session format.
    func supports(_ kind: ImportKind) -> Bool {
        switch kind {
        case .bookmarks:
            return true
        case .history:
            switch self {
            case .chrome, .edge, .brave, .firefox: return true
            case .safari, .htmlFile: return false
            }
        case .tabs:
            return self == .firefox
        case .cookies:
            // Chromium cookies are decrypted with a Keychain key; Firefox's are
            // stored in the clear. Safari's are in a protected container.
            switch self {
            case .chrome, .edge, .brave, .firefox: return true
            case .safari, .htmlFile: return false
            }
        }
    }

    /// The login-Keychain item a Chromium browser encrypts its cookies with,
    /// as (service, account). Nil for Firefox (unencrypted) and the rest.
    var cookieKeychain: (service: String, account: String)? {
        switch self {
        case .chrome: return ("Chrome Safe Storage", "Chrome")
        case .edge: return ("Microsoft Edge Safe Storage", "Microsoft Edge")
        case .brave: return ("Brave Safe Storage", "Brave")
        case .safari, .firefox, .htmlFile: return nil
        }
    }

    /// Whether the user picks an exported bookmarks HTML file (Safari, Firefox,
    /// any browser) rather than a data file Kylmora reads directly.
    func picksHTMLExport(for kind: ImportKind) -> Bool {
        kind == .bookmarks && chromiumProfile == nil
    }

    /// Where the open panel should open for a kind: a Chromium profile folder
    /// holds both files; Firefox history is picked from its profiles folder.
    /// Nil lets the panel open wherever the user last was.
    func startDirectory(for kind: ImportKind) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let profile = chromiumProfile {
            return home.appending(path: profile)
        }
        if self == .firefox, kind == .history || kind == .tabs {
            return home.appending(path: "Library/Application Support/Firefox/Profiles")
        }
        return nil
    }

    /// What to tell the user to select for a kind.
    func instructions(for kind: ImportKind) -> String {
        switch kind {
        case .bookmarks:
            switch self {
            case .safari:
                return "In Safari, choose File \u{2192} Export \u{2192} Bookmarks to save an HTML file, then choose that file here."
            case .firefox:
                return "In Firefox, open Bookmarks \u{2192} Manage Bookmarks \u{2192} Import and Backup \u{2192} Export Bookmarks to HTML, then choose that file here."
            case .chrome, .edge, .brave:
                return "Kylmora opens \(sentenceName)\u{2019}s profile folder. Choose the file named \u{201c}Bookmarks\u{201d} \u{2014} it has no extension."
            case .htmlFile:
                return "Choose a bookmarks HTML file exported by any browser."
            }
        case .history:
            switch self {
            case .chrome, .edge, .brave:
                return "Kylmora opens \(sentenceName)\u{2019}s profile folder. Choose the file named \u{201c}History\u{201d} \u{2014} it has no extension. Quitting \(sentenceName) first gives the most complete history."
            case .firefox:
                return "Choose \u{201c}places.sqlite\u{201d} in your Firefox profile folder."
            case .safari:
                return "Safari\u{2019}s history is protected by macOS, so it can\u{2019}t be imported. Its bookmarks can, above."
            case .htmlFile:
                return "An HTML file holds no history \u{2014} choose a browser above to import history."
            }
        case .tabs:
            switch self {
            case .firefox:
                return "Open the folder \u{201c}sessionstore-backups\u{201d} in your Firefox profile and choose \u{201c}recovery.jsonlz4\u{201d}. The tabs open in a new group."
            case .chrome, .edge, .brave:
                return "\(sentenceName)\u{2019}s open tabs are in an undocumented format that changes between versions, so they can\u{2019}t be imported reliably. Bookmarks and history can, above."
            case .safari:
                return "Safari\u{2019}s open tabs are protected by macOS, so they can\u{2019}t be imported. Its bookmarks can, above."
            case .htmlFile:
                return "An HTML file holds no open tabs \u{2014} only Firefox\u{2019}s session can be imported."
            }
        case .cookies:
            switch self {
            case .chrome, .edge, .brave:
                return "Brings your logged-in sessions over. macOS asks once to allow reading \(sentenceName)\u{2019}s key, then the sites you\u{2019}re signed into stay signed in. Quit \(sentenceName) first."
            case .firefox:
                return "Reads your Firefox cookies directly, so the sites you\u{2019}re signed into stay signed in. Quit Firefox first."
            case .safari:
                return "Safari\u{2019}s cookies are in a container macOS protects, so logins can\u{2019}t be imported."
            case .htmlFile:
                return "An HTML file holds no logins \u{2014} choose a browser above."
            }
        }
    }
}
