import Foundation

/// What a side panel is set to, for one extension.
///
/// The manifest says where the panel starts; everything after that is the
/// extension's to change at runtime, per tab if it likes. Chrome's
/// `sidePanel.setOptions` and Firefox's `sidebarAction.setPanel` both land
/// here, so the two spellings share one model and the panel does not care
/// which was used.
struct ExtensionSidebarState: Equatable, Codable, Sendable {
    /// What one tab was told, over the top of the defaults.
    struct TabOptions: Equatable, Codable, Sendable {
        var path: String?
        var isEnabled: Bool?
    }

    /// The page the manifest named. Kept so a `setOptions` that clears its
    /// path can fall back to it.
    var manifestPath: String?
    var manifestTitle: String?
    /// The path set for every tab that has no say of its own.
    var defaultPath: String?
    var defaultTitle: String?
    /// Chrome's panels can be switched off; Firefox's cannot, and there a
    /// panel of `null` is how an extension says "not on this tab".
    var isEnabledByDefault: Bool = true
    /// `sidePanel.setPanelBehavior({ openPanelOnActionClick })`. When set,
    /// clicking the extension's button opens the panel rather than a popup.
    var opensOnActionClick: Bool = false
    /// Keyed by the tab identifier the extension itself uses. Kylmora never
    /// invents these: they arrive from the extension and go back unchanged.
    var perTab: [Int: TabOptions] = [:]

    init(manifestPath: String? = nil, manifestTitle: String? = nil) {
        self.manifestPath = manifestPath
        self.manifestTitle = manifestTitle
    }

    /// The page to show for a tab, or `nil` when the extension has switched
    /// the panel off there.
    func path(forTab tabID: Int?) -> String? {
        guard isEnabled(forTab: tabID) else { return nil }
        if let tabID, let tab = perTab[tabID], let path = tab.path, !path.isEmpty {
            return path
        }
        if let defaultPath, !defaultPath.isEmpty { return defaultPath }
        return manifestPath
    }

    func isEnabled(forTab tabID: Int?) -> Bool {
        if let tabID, let enabled = perTab[tabID]?.isEnabled { return enabled }
        return isEnabledByDefault
    }

    var title: String? {
        defaultTitle ?? manifestTitle
    }

    /// Applies `sidePanel.setOptions`. A `nil` field is one the caller did not
    /// mention, which Chrome leaves alone; a path of `""` is how the API says
    /// "back to the manifest's".
    mutating func setOptions(tabID: Int?, path: String?, isEnabled: Bool?) {
        if let tabID {
            var options = perTab[tabID] ?? TabOptions()
            if let path { options.path = path.isEmpty ? nil : path }
            if let isEnabled { options.isEnabled = isEnabled }
            // A tab that has nothing left to say is forgotten rather than
            // kept as an empty row, so a long session does not grow one entry
            // per tab the extension has ever touched.
            if options.path == nil && options.isEnabled == nil {
                perTab[tabID] = nil
            } else {
                perTab[tabID] = options
            }
            return
        }
        if let path { defaultPath = path.isEmpty ? nil : path }
        if let isEnabled { isEnabledByDefault = isEnabled }
    }

    /// Applies Firefox's `sidebarAction.setPanel`, where `null` means "no
    /// panel here" rather than "back to the default".
    mutating func setPanel(tabID: Int?, panel: String?) {
        guard let panel, !panel.isEmpty else {
            if let tabID {
                var options = perTab[tabID] ?? TabOptions()
                options.isEnabled = false
                perTab[tabID] = options
            } else {
                isEnabledByDefault = false
            }
            return
        }
        setOptions(tabID: tabID, path: panel, isEnabled: true)
    }

    mutating func setTitle(tabID: Int?, title: String?) {
        // Firefox scopes titles per tab too. One title is enough here: the
        // panel shows one name at a time and the tab it belongs to is the one
        // in front.
        defaultTitle = (title?.isEmpty == true) ? nil : title
    }

    /// Forgets a tab that has gone away.
    mutating func forgetTab(_ tabID: Int) {
        perTab[tabID] = nil
    }
}

/// Every extension's side panel settings, kept across launches.
///
/// Small enough for `UserDefaults`: a handful of paths and flags per
/// extension, written when an extension changes them, which is rare.
@MainActor
final class ExtensionSidebarStore {
    static let shared = ExtensionSidebarStore()

    private let defaults: UserDefaults
    private let key = "extensionSidebarState"
    private var states: [UUID: ExtensionSidebarState]
    /// Told when anything changes, so an open panel can follow.
    var onChange: ((UUID) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        states = Self.read(from: defaults, key: key)
    }

    func state(for id: UUID) -> ExtensionSidebarState {
        states[id] ?? ExtensionSidebarState()
    }

    func update(_ id: UUID, _ change: (inout ExtensionSidebarState) -> Void) {
        var state = states[id] ?? ExtensionSidebarState()
        change(&state)
        states[id] = state
        save()
        onChange?(id)
    }

    /// The manifest's own values, refreshed whenever the extension loads: an
    /// update may move the panel's page, and what the extension set at runtime
    /// should survive that.
    func adopt(_ definition: ExtensionSidebarDefinition?, for id: UUID) {
        update(id) { state in
            state.manifestPath = definition?.path
            state.manifestTitle = definition?.title
        }
    }

    func forget(_ id: UUID) {
        states[id] = nil
        save()
        onChange?(id)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(states.map { Entry(id: $0.key, state: $0.value) }) else { return }
        defaults.set(data, forKey: key)
    }

    private struct Entry: Codable {
        let id: UUID
        let state: ExtensionSidebarState
    }

    private static func read(from defaults: UserDefaults, key: String) -> [UUID: ExtensionSidebarState] {
        guard let data = defaults.data(forKey: key),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.state) })
    }
}
