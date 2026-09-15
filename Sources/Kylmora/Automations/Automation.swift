import Foundation

/// When a rule fires.
///
/// URL patterns reuse the routing rules' matching (`SpaceRouteMatch`), so a
/// pattern means the same thing here as in a Space route. An empty pattern
/// matches every address.
enum AutomationTrigger: Equatable, Codable {
    /// A page finished loading in a tab.
    case pageLoaded(pattern: String, match: SpaceRouteMatch)
    /// A tab has not been looked at for this many minutes.
    case tabIdle(minutes: Int, pattern: String, match: SpaceRouteMatch)
    /// Audio or video started playing in a tab.
    case mediaStarted(pattern: String, match: SpaceRouteMatch)
    /// A download finished. `fileExtension` narrows it (`pdf`); empty is any.
    case downloadFinished(fileExtension: String)
    /// Only when run by hand, from the command palette, on the active tab.
    /// A custom command, in other words.
    case manual

    enum Kind: String, CaseIterable, Codable {
        case pageLoaded, tabIdle, mediaStarted, downloadFinished, manual

        var title: String {
            switch self {
            case .pageLoaded: return "A page loads"
            case .tabIdle: return "A tab sits idle"
            case .mediaStarted: return "Media starts playing"
            case .downloadFinished: return "A download finishes"
            case .manual: return "Run from the command palette"
            }
        }

        /// Whether this trigger has a tab to act on.
        var concernsATab: Bool { self != .downloadFinished }

        /// Whether the trigger names an address pattern.
        var takesPattern: Bool { self == .pageLoaded || self == .tabIdle || self == .mediaStarted }
    }

    var kind: Kind {
        switch self {
        case .pageLoaded: return .pageLoaded
        case .tabIdle: return .tabIdle
        case .mediaStarted: return .mediaStarted
        case .downloadFinished: return .downloadFinished
        case .manual: return .manual
        }
    }

    var pattern: String {
        switch self {
        case .pageLoaded(let pattern, _), .tabIdle(_, let pattern, _), .mediaStarted(let pattern, _): return pattern
        case .downloadFinished(let ext): return ext
        case .manual: return ""
        }
    }

    var match: SpaceRouteMatch {
        switch self {
        case .pageLoaded(_, let match), .tabIdle(_, _, let match), .mediaStarted(_, let match): return match
        case .downloadFinished, .manual: return .contains
        }
    }

    var idleMinutes: Int? {
        if case .tabIdle(let minutes, _, _) = self { return minutes }
        return nil
    }

    /// One line for the list: "When a page loads matching github.com".
    var summary: String {
        let scope: String
        switch self {
        case .pageLoaded(let pattern, _), .mediaStarted(let pattern, _):
            scope = pattern.isEmpty ? "anywhere" : "matching \(pattern)"
        case .tabIdle(let minutes, let pattern, _):
            scope = "for \(minutes) min" + (pattern.isEmpty ? "" : ", matching \(pattern)")
        case .downloadFinished(let ext):
            scope = ext.isEmpty ? "of any kind" : "of a .\(ext) file"
        case .manual:
            return "When run from the command palette"
        }
        return "When \(kind.title.lowercased()) \(scope)"
    }
}

/// What a rule does. Tab actions need a tab, which the download trigger does
/// not have; `worksWithoutTab` says which apply there.
enum AutomationAction: Equatable, Codable {
    case moveToSpace(UUID)
    case pinTab
    case muteTab
    case keepAwake
    case readerMode
    case setZoom(String)
    case archiveTab
    case closeTab
    case notify(String)
    case runShortcut(String)
    case runAppleScript(String)
    case openURL(String)

    enum Kind: String, CaseIterable, Codable {
        case moveToSpace, pinTab, muteTab, keepAwake, readerMode, setZoom, archiveTab, closeTab
        case notify, runShortcut, runAppleScript, openURL

        var title: String {
            switch self {
            case .moveToSpace: return "Move the tab to a Space"
            case .pinTab: return "Pin the tab"
            case .muteTab: return "Mute the tab"
            case .keepAwake: return "Keep the tab awake"
            case .readerMode: return "Open in Reader"
            case .setZoom: return "Set the page zoom"
            case .archiveTab: return "Archive the tab"
            case .closeTab: return "Close the tab"
            case .notify: return "Show a message"
            case .runShortcut: return "Run an Apple Shortcut"
            case .runAppleScript: return "Run an AppleScript"
            case .openURL: return "Open an address"
            }
        }

        var worksWithoutTab: Bool {
            switch self {
            case .notify, .runShortcut, .runAppleScript, .openURL: return true
            default: return false
            }
        }

        /// The placeholder text for the parameter field, or nil for none.
        var parameterPrompt: String? {
            switch self {
            case .notify: return "Message, may use {{title}} and {{url}}"
            case .runShortcut: return "Shortcut name; it receives {{url}} as text"
            case .runAppleScript: return "AppleScript source, may use {{url}} and {{title}}"
            case .openURL: return "Address, may use {{url}}"
            default: return nil
            }
        }
    }

    var kind: Kind {
        switch self {
        case .moveToSpace: return .moveToSpace
        case .pinTab: return .pinTab
        case .muteTab: return .muteTab
        case .keepAwake: return .keepAwake
        case .readerMode: return .readerMode
        case .setZoom: return .setZoom
        case .archiveTab: return .archiveTab
        case .closeTab: return .closeTab
        case .notify: return .notify
        case .runShortcut: return .runShortcut
        case .runAppleScript: return .runAppleScript
        case .openURL: return .openURL
        }
    }

    var parameter: String {
        switch self {
        case .moveToSpace(let id): return id.uuidString
        case .setZoom(let zoom): return zoom
        case .notify(let text), .runShortcut(let text), .runAppleScript(let text), .openURL(let text): return text
        default: return ""
        }
    }

    /// Builds an action of `kind` from what the editor holds.
    static func make(_ kind: Kind, parameter: String) -> AutomationAction? {
        switch kind {
        case .moveToSpace: return UUID(uuidString: parameter).map { .moveToSpace($0) }
        case .pinTab: return .pinTab
        case .muteTab: return .muteTab
        case .keepAwake: return .keepAwake
        case .readerMode: return .readerMode
        case .setZoom: return .setZoom(parameter.isEmpty ? "1" : parameter)
        case .archiveTab: return .archiveTab
        case .closeTab: return .closeTab
        case .notify: return .notify(parameter)
        case .runShortcut: return parameter.isEmpty ? nil : .runShortcut(parameter)
        case .runAppleScript: return parameter.isEmpty ? nil : .runAppleScript(parameter)
        case .openURL: return parameter.isEmpty ? nil : .openURL(parameter)
        }
    }

    func summary(spaceName: (UUID) -> String?) -> String {
        switch self {
        case .moveToSpace(let id): return "move to \(spaceName(id) ?? "a missing Space")"
        case .setZoom(let zoom): return "zoom \(Int(((Double(zoom) ?? 1) * 100).rounded()))%"
        case .notify(let text): return "say “\(text)”"
        case .runShortcut(let name): return "run Shortcut “\(name)”"
        case .runAppleScript: return "run AppleScript"
        case .openURL(let address): return "open \(address)"
        default: return kind.title.lowercased()
        }
    }
}

/// One rule: a trigger and what to do.
struct AutomationRule: Identifiable, Equatable, Codable {
    var id: UUID
    var name: String
    var isEnabled: Bool
    var trigger: AutomationTrigger
    var actions: [AutomationAction]

    init(id: UUID = UUID(), name: String, isEnabled: Bool = true, trigger: AutomationTrigger, actions: [AutomationAction]) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.trigger = trigger
        self.actions = actions
    }

    /// A rule with nothing to do is dropped on save, like an empty route.
    var isEmpty: Bool { actions.isEmpty }
}

/// The whole rule set, in the order it is evaluated.
struct AutomationRules: Equatable, Codable {
    var rules: [AutomationRule]

    static let empty = AutomationRules(rules: [])

    init(rules: [AutomationRule] = []) {
        self.rules = rules
    }

    func discardingEmptyRules() -> AutomationRules {
        AutomationRules(rules: rules.filter { !$0.isEmpty })
    }
}

/// `{{url}}`, `{{title}}` and `{{file}}` in an action's text.
enum AutomationPlaceholders {
    static func fill(_ text: String, url: URL?, title: String?, file: URL?) -> String {
        text.replacingOccurrences(of: "{{url}}", with: url?.absoluteString ?? "")
            .replacingOccurrences(of: "{{title}}", with: title ?? "")
            .replacingOccurrences(of: "{{file}}", with: file?.path ?? "")
    }
}
