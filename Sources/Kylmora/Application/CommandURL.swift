import AppKit
import Foundation

/// The `kylmora://` addresses other programs can open to drive the browser:
///
///     kylmora://tab?url=https://a.example&space=Work&background=1
///     kylmora://space?name=Work
///     kylmora://command?id=print-page
///     kylmora://new-tab
///
/// The `kylmora` command-line tool in the app bundle builds these; anything
/// that can run `open` can use them directly.
enum CommandURL: Equatable {
    case tab(URL, space: String?, background: Bool)
    case space(String)
    case command(String)
    case newTab

    static let scheme = "kylmora"

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let action = (components.host ?? components.path).trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        switch action {
        case "tab":
            guard let text = value("url"), let target = URL(string: text), target.scheme != nil else { return nil }
            let background = ["1", "true", "yes"].contains((value("background") ?? "").lowercased())
            self = .tab(target, space: value("space").flatMap { $0.isEmpty ? nil : $0 }, background: background)
        case "space":
            guard let name = value("name"), !name.isEmpty else { return nil }
            self = .space(name)
        case "command":
            guard let id = value("id"), !id.isEmpty else { return nil }
            self = .command(id)
        case "new-tab", "newtab":
            self = .newTab
        default:
            return nil
        }
    }

    /// The address for this command, as the tool prints it.
    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .tab(let target, let space, let background):
            components.host = "tab"
            var items = [URLQueryItem(name: "url", value: target.absoluteString)]
            if let space { items.append(URLQueryItem(name: "space", value: space)) }
            if background { items.append(URLQueryItem(name: "background", value: "1")) }
            components.queryItems = items
        case .space(let name):
            components.host = "space"
            components.queryItems = [URLQueryItem(name: "name", value: name)]
        case .command(let id):
            components.host = "command"
            components.queryItems = [URLQueryItem(name: "id", value: id)]
        case .newTab:
            components.host = "new-tab"
        }
        return components.url!
    }

    /// Carries the command out. Returns false when it named a space or
    /// command that does not exist.
    @MainActor
    @discardableResult
    func perform(in session: BrowserSession, window: BrowserWindowController?) -> Bool {
        switch self {
        case .tab(let target, let spaceName, let background):
            if let spaceName {
                guard let space = session.spaces.first(where: { $0.name.localizedCaseInsensitiveCompare(spaceName) == .orderedSame }) else { return false }
                if session.activeSpace !== space { session.selectSpace(space) }
            }
            if !background { NSApplication.shared.activate(ignoringOtherApps: true) }
            _ = session.newTab(url: target, select: !background, origin: .external)
            return true
        case .space(let name):
            guard let space = session.spaces.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else { return false }
            NSApplication.shared.activate(ignoringOtherApps: true)
            session.selectSpace(space)
            return true
        case .command(let id):
            guard let window else { return false }
            NSApplication.shared.activate(ignoringOtherApps: true)
            return window.runPaletteCommand(id)
        case .newTab:
            NSApplication.shared.activate(ignoringOtherApps: true)
            _ = session.newTab()
            return true
        }
    }
}
