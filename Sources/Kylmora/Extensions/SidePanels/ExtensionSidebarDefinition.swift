import Foundation

/// What an extension's manifest says about its side panel.
///
/// Two browsers, two spellings of the same idea. Chrome's `side_panel` names
/// one page and leaves everything else to `chrome.sidePanel` at runtime;
/// Firefox's `sidebar_action` names the page, a title and an icon up front.
/// Kylmora reads both and keeps whichever it found, because an extension
/// written for either should behave the same here.
struct ExtensionSidebarDefinition: Equatable, Sendable {
    /// The page the panel opens, relative to the extension's own root.
    let path: String
    /// The name shown on the panel. Firefox's manifest supplies one; Chrome's
    /// does not, so the extension's own name is used.
    let title: String?
    /// The icon the manifest offers for the panel, largest first.
    let iconPaths: [String]
    /// Firefox opens its sidebar on install unless the manifest says not to.
    let opensOnInstall: Bool
    /// Which spelling it was written in, which decides the API the extension
    /// expects to find.
    let flavour: Flavour

    enum Flavour: String, Equatable, Sendable {
        /// `side_panel` and `chrome.sidePanel`.
        case chrome
        /// `sidebar_action` and `browser.sidebarAction`.
        case firefox
    }

    /// Reads the manifest WebKit parsed for us.
    ///
    /// `nil` when the extension has no panel, which is most of them: nothing
    /// is set up, no shim is written, and the extension is left exactly as it
    /// was.
    static func read(from manifest: [String: Any]) -> ExtensionSidebarDefinition? {
        if let sidebar = manifest["sidebar_action"] as? [String: Any] {
            let path = (sidebar["default_panel"] as? String) ?? (sidebar["default_page"] as? String)
            if let path, !path.isEmpty {
                return ExtensionSidebarDefinition(
                    path: normalise(path),
                    title: (sidebar["default_title"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                    iconPaths: icons(from: sidebar["default_icon"]),
                    // Firefox opens a new sidebar the first time unless told
                    // otherwise, which is the one behavioural difference
                    // between the two spellings worth keeping.
                    opensOnInstall: (sidebar["open_at_install"] as? Bool) ?? true,
                    flavour: .firefox
                )
            }
        }
        if let panel = manifest["side_panel"] as? [String: Any],
           let path = panel["default_path"] as? String, !path.isEmpty {
            return ExtensionSidebarDefinition(
                path: normalise(path),
                title: nil,
                iconPaths: [],
                opensOnInstall: false,
                flavour: .chrome
            )
        }
        return nil
    }

    /// Whether the extension asks for the side panel API even without naming a
    /// page, which an extension that sets its path at runtime does.
    static func wantsSidebarAPI(_ manifest: [String: Any]) -> Bool {
        if read(from: manifest) != nil { return true }
        let permissions = (manifest["permissions"] as? [String]) ?? []
        let optional = (manifest["optional_permissions"] as? [String]) ?? []
        return permissions.contains("sidePanel") || optional.contains("sidePanel")
    }

    /// A manifest path as a URL under the extension's root.
    func url(under base: URL) -> URL {
        base.appending(path: path)
    }

    private static func normalise(_ path: String) -> String {
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasPrefix("/") { trimmed.removeFirst() }
        if trimmed.hasPrefix("./") { trimmed.removeFirst(2) }
        return trimmed
    }

    /// `default_icon` is a string or a map of size to path; both are allowed
    /// and both appear in the wild.
    private static func icons(from value: Any?) -> [String] {
        if let single = value as? String, !single.isEmpty { return [normalise(single)] }
        guard let sizes = value as? [String: Any] else { return [] }
        return sizes
            .compactMap { key, path -> (Int, String)? in
                guard let path = path as? String, !path.isEmpty else { return nil }
                return (Int(key) ?? 0, normalise(path))
            }
            .sorted { $0.0 > $1.0 }
            .map(\.1)
    }
}
