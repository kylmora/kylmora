import Foundation

/// The side panel API, as far as an extension can tell.
///
/// WebKit's extension engine has no `chrome.sidePanel` and no
/// `browser.sidebarAction`; it does not know the idea exists. Kylmora hands
/// the extension a shim that speaks to this, and this is where the API's
/// meaning lives: what `setOptions` does to a tab, what `getPanel` answers,
/// when a panel opens. Everything above it is transport and everything below
/// it is a window.
///
/// One place, on purpose. The same calls arrive from three directions -- the
/// panel page, the background worker, a popup -- and an API that meant
/// slightly different things depending on where it was called from is worse
/// than no API at all.
@MainActor
final class ExtensionSidebarBroker {
    /// What the app must do when the API asks. Set by whoever owns the
    /// windows; absent in tests that only care about state.
    var opensPanel: ((UUID, Int?) -> Void)?
    var closesPanel: ((UUID) -> Void)?
    var isPanelOpen: ((UUID) -> Bool)?

    private let store: ExtensionSidebarStore
    /// The tab the extension last said was in front, in the extension's own
    /// numbering. Kylmora cannot know these -- WebKit gives tabs their
    /// identifiers and keeps them -- so the shim reports the current one and
    /// that is what per-tab options are matched against.
    private(set) var currentTabID: [UUID: Int] = [:]

    init(store: ExtensionSidebarStore) {
        self.store = store
    }

    enum Reply: Equatable {
        case done
        case value([String: SidebarValue])
        case failure(String)
    }

    /// The JSON an answer can hold. A small closed set rather than `Any`: it
    /// crosses to a web view, and the compiler should be able to see that
    /// everything in it can be written as JSON.
    enum SidebarValue: Equatable {
        case string(String)
        case bool(Bool)
        case number(Int)
        case null

        var json: Any {
            switch self {
            case .string(let value): return value
            case .bool(let value): return value
            case .number(let value): return value
            case .null: return NSNull()
            }
        }
    }

    /// Answers one call. `method` is the API's own name, so a reader can match
    /// what is here against Chrome's and Firefox's documentation line by line.
    func perform(_ method: String, arguments: [String: Any], for id: UUID) -> Reply {
        let tabID = resolveTab(arguments["tabId"], for: id)
        switch method {

        // MARK: Chrome

        case "sidePanel.setOptions":
            store.update(id) { $0.setOptions(tabID: tabID, path: arguments["path"] as? String,
                                             isEnabled: arguments["enabled"] as? Bool) }
            return .done

        case "sidePanel.getOptions":
            let state = store.state(for: id)
            var reply: [String: SidebarValue] = [
                "enabled": .bool(state.isEnabled(forTab: tabID)),
            ]
            reply["path"] = state.path(forTab: tabID).map(SidebarValue.string) ?? .null
            if let tabID { reply["tabId"] = .number(tabID) }
            return .value(reply)

        case "sidePanel.setPanelBehavior":
            let opens = arguments["openPanelOnActionClick"] as? Bool ?? false
            store.update(id) { $0.opensOnActionClick = opens }
            return .done

        case "sidePanel.getPanelBehavior":
            return .value(["openPanelOnActionClick": .bool(store.state(for: id).opensOnActionClick)])

        case "sidePanel.open":
            guard store.state(for: id).path(forTab: tabID) != nil else {
                return .failure("No side panel is set for this tab.")
            }
            opensPanel?(id, tabID)
            return .done

        // MARK: Firefox

        case "sidebarAction.setPanel":
            store.update(id) { $0.setPanel(tabID: tabID, panel: arguments["panel"] as? String) }
            return .done

        case "sidebarAction.getPanel":
            let path = store.state(for: id).path(forTab: tabID)
            return .value(["panel": path.map(SidebarValue.string) ?? .string("")])

        case "sidebarAction.setTitle":
            store.update(id) { $0.setTitle(tabID: tabID, title: arguments["title"] as? String) }
            return .done

        case "sidebarAction.getTitle":
            return .value(["title": .string(store.state(for: id).title ?? "")])

        case "sidebarAction.setIcon":
            // Taken and ignored on purpose: the panel wears the extension's
            // own icon, which is the one the rest of this browser shows for
            // it. Answering an error would fail extensions that always set an
            // icon on startup.
            return .done

        case "sidebarAction.open":
            guard store.state(for: id).path(forTab: tabID) != nil else {
                return .failure("This extension has no panel to open.")
            }
            opensPanel?(id, tabID)
            return .done

        case "sidebarAction.close":
            closesPanel?(id)
            return .done

        case "sidebarAction.toggle":
            if isPanelOpen?(id) == true {
                closesPanel?(id)
            } else {
                guard store.state(for: id).path(forTab: tabID) != nil else {
                    return .failure("This extension has no panel to open.")
                }
                opensPanel?(id, tabID)
            }
            return .done

        case "sidebarAction.isOpen":
            return .value(["isOpen": .bool(isPanelOpen?(id) ?? false)])

        // MARK: Kylmora's own

        case "kylmora.tabChanged":
            if let tabID = arguments["tabId"] as? Int { currentTabID[id] = tabID }
            return .done

        case "kylmora.tabRemoved":
            if let tabID = arguments["tabId"] as? Int {
                store.update(id) { $0.forgetTab(tabID) }
                if currentTabID[id] == tabID { currentTabID[id] = nil }
            }
            return .done

        case "kylmora.state":
            let state = store.state(for: id)
            return .value([
                "path": state.path(forTab: currentTabID[id]).map(SidebarValue.string) ?? .null,
                "title": state.title.map(SidebarValue.string) ?? .null,
                "isOpen": .bool(isPanelOpen?(id) ?? false),
            ])

        default:
            return .failure("\(method) is not something Kylmora's side panel support answers.")
        }
    }

    /// The panel page for an extension right now, if it has one.
    func panelPath(for id: UUID) -> String? {
        store.state(for: id).path(forTab: currentTabID[id])
    }

    func title(for id: UUID) -> String? {
        store.state(for: id).title
    }

    func opensOnActionClick(_ id: UUID) -> Bool {
        store.state(for: id).opensOnActionClick
    }

    /// `tabId` may be absent, which means "whatever tab is in front".
    private func resolveTab(_ raw: Any?, for id: UUID) -> Int? {
        if let tabID = raw as? Int { return tabID }
        if let number = raw as? NSNumber { return number.intValue }
        return nil
    }
}
