import AppKit
import WebKit

/// Side panels, from the app's side.
///
/// It owns the one panel the window can show, decides which extension is in
/// it, and carries the API calls from wherever they were made to the broker
/// that answers them. Extensions reach it two ways and both end up here: a
/// page Kylmora hosts posts to a message handler, and a background worker
/// opens what it thinks is a native messaging port -- a name Kylmora reserves
/// and answers itself, so no program is started and nothing leaves the app.
@available(macOS 15.4, *)
@MainActor
final class ExtensionSidebarService {
    static let shared = ExtensionSidebarService()

    /// What the panel needs to show an extension. Filled in by the extension
    /// manager, which is the only thing that knows about loaded contexts.
    struct Presentation {
        let context: WKWebExtensionContext
        let title: String
        let icon: NSImage?
    }

    let broker: ExtensionSidebarBroker
    /// Asked for what an extension looks like when its panel opens.
    var presents: ((UUID) -> Presentation?)?
    /// The window's docked panel, and the switch that shows or hides it.
    weak var panel: ExtensionPanelViewController?
    var setsPanelVisible: ((Bool) -> Void)?
    /// Told whenever the open panel changes, so buttons and menus can follow.
    var onChange: (() -> Void)?

    private(set) var openExtensionID: UUID?
    /// One port per extension whose background code is talking to us.
    private var ports: [UUID: any NativeMessagingPort] = [:]

    init(store: ExtensionSidebarStore = .shared) {
        broker = ExtensionSidebarBroker(store: store)
        broker.opensPanel = { [weak self] id, tabID in self?.open(id, tabID: tabID) }
        broker.closesPanel = { [weak self] id in
            guard self?.openExtensionID == id else { return }
            self?.close()
        }
        broker.isPanelOpen = { [weak self] id in self?.openExtensionID == id }
    }

    // MARK: - Showing a panel

    /// Whether this extension has a panel worth offering right now.
    func hasPanel(_ id: UUID) -> Bool {
        broker.panelPath(for: id) != nil
    }

    func opensOnActionClick(_ id: UUID) -> Bool {
        broker.opensOnActionClick(id)
    }

    func open(_ id: UUID, tabID: Int? = nil) {
        guard let path = broker.panelPath(for: id), let presentation = presents?(id) else { return }
        guard let panel else { return }
        panel.handles = { [weak self] id, method, arguments in
            self?.broker.perform(method, arguments: arguments, for: id) ?? .failure("Kylmora is not ready.")
        }
        panel.onClose = { [weak self] in self?.close() }
        panel.show(extensionID: id, context: presentation.context, path: path,
                   title: presentation.title, icon: presentation.icon)
        openExtensionID = id
        setsPanelVisible?(true)
        onChange?()
    }

    func close() {
        guard openExtensionID != nil else { return }
        openExtensionID = nil
        setsPanelVisible?(false)
        panel?.clear()
        onChange?()
    }

    func toggle(_ id: UUID) {
        if openExtensionID == id {
            close()
        } else {
            open(id)
        }
    }

    /// The extension is gone or switched off: its panel should not outlive it.
    func forget(_ id: UUID) {
        ports[id] = nil
        if openExtensionID == id { close() }
    }

    /// The panel follows the active tab, because a panel path can be set per
    /// tab and the page for one tab is not the page for another.
    func activeTabChanged() {
        guard let id = openExtensionID else { return }
        guard let path = broker.panelPath(for: id) else {
            close()
            return
        }
        guard let presentation = presents?(id) else { return }
        panel?.show(extensionID: id, context: presentation.context, path: path,
                    title: presentation.title, icon: presentation.icon)
    }

    /// Anything the extension changed may have moved its own panel.
    func stateChanged(for id: UUID) {
        guard openExtensionID == id else { return }
        activeTabChanged()
    }

    // MARK: - The background worker's channel

    /// Takes over a port the extension opened to Kylmora's reserved host name.
    func attach(_ port: any NativeMessagingPort, for id: UUID) {
        ports[id] = port
        port.receive = { [weak self, weak port] message in
            guard let self, let port, let body = message as? [String: Any] else { return }
            let callID = body["id"]
            let method = body["method"] as? String ?? ""
            let arguments = (body["args"] as? [String: Any]) ?? [:]
            var reply: [String: Any] = [:]
            if let callID { reply["id"] = callID }
            switch self.broker.perform(method, arguments: arguments, for: id) {
            case .done:
                reply["ok"] = true
            case .value(let values):
                reply["ok"] = true
                reply["value"] = values.mapValues(\.json)
            case .failure(let message):
                reply["ok"] = false
                reply["error"] = message
            }
            port.deliver(reply)
        }
        port.closed = { [weak self] in
            self?.ports[id] = nil
        }
    }

    /// Whether this is the name Kylmora answers itself rather than a program
    /// on the Mac. Checked before anything is looked up on disk, so a manifest
    /// claiming the name cannot take it.
    static func isBrokerHost(_ name: String?) -> Bool {
        name?.caseInsensitiveCompare(ExtensionSidebarShim.brokerHostName) == .orderedSame
    }
}
