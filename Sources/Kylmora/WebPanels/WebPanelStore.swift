import AppKit
import Foundation

extension Notification.Name {
    public static let webPanelsDidChange = Notification.Name("kylmora.webPanelsDidChange")
    public static let webPanelVisibilityDidChange = Notification.Name("kylmora.webPanelVisibilityDidChange")
    public static let webPanelSelectionDidChange = Notification.Name("kylmora.webPanelSelectionDidChange")
}

/// Stores and coordinates user web panels, persistent panel width, active selection, and visibility state.
@MainActor
public final class WebPanelStore {
    public static let shared = WebPanelStore()

    public static let minWidth: CGFloat = 260
    public static let maxWidth: CGFloat = 640
    public static let defaultWidth: CGFloat = 360

    private static let panelsDefaultsKey = "kylmora.webpanels.list"
    private static let activePanelIdKey = "kylmora.webpanels.active_id"
    private static let isOpenKey = "kylmora.webpanels.is_open"
    private static let panelWidthKey = "kylmora.webpanels.width"
    private static let alwaysOnTopKey = "kylmora.webpanels.floating_always_on_top"

    private let defaults: UserDefaults

    public private(set) var panels: [WebPanel] = [] {
        didSet {
            savePanels()
            NotificationCenter.default.post(name: .webPanelsDidChange, object: self)
        }
    }

    public var activePanelId: UUID? {
        didSet {
            if activePanelId != oldValue {
                defaults.set(activePanelId?.uuidString, forKey: Self.activePanelIdKey)
                NotificationCenter.default.post(name: .webPanelSelectionDidChange, object: self)
            }
        }
    }

    public var activePanel: WebPanel? {
        if let id = activePanelId, let found = panels.first(where: { $0.id == id }) {
            return found
        }
        return panels.first
    }

    public var isOpen: Bool {
        didSet {
            if isOpen != oldValue {
                defaults.set(isOpen, forKey: Self.isOpenKey)
                NotificationCenter.default.post(name: .webPanelVisibilityDidChange, object: self)
            }
        }
    }

    public var width: CGFloat {
        get {
            let val = CGFloat(defaults.double(forKey: Self.panelWidthKey))
            return (val >= Self.minWidth && val <= Self.maxWidth) ? val : Self.defaultWidth
        }
        set {
            let clamped = min(max(newValue, Self.minWidth), Self.maxWidth)
            defaults.set(Double(clamped), forKey: Self.panelWidthKey)
        }
    }

    public var alwaysOnTopFloating: Bool {
        get {
            if defaults.object(forKey: Self.alwaysOnTopKey) == nil { return true }
            return defaults.bool(forKey: Self.alwaysOnTopKey)
        }
        set {
            defaults.set(newValue, forKey: Self.alwaysOnTopKey)
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isOpen = defaults.bool(forKey: Self.isOpenKey)
        self.loadPanels()
        if let savedIdString = defaults.string(forKey: Self.activePanelIdKey),
           let savedUUID = UUID(uuidString: savedIdString),
           panels.contains(where: { $0.id == savedUUID }) {
            self.activePanelId = savedUUID
        } else {
            self.activePanelId = panels.first?.id
        }
    }

    private func loadPanels() {
        guard let data = defaults.data(forKey: Self.panelsDefaultsKey),
              let decoded = try? JSONDecoder().decode([WebPanel].self, from: data),
              !decoded.isEmpty else {
            self.panels = WebPanel.defaultPanels
            return
        }
        self.panels = decoded
    }

    private func savePanels() {
        if let encoded = try? JSONEncoder().encode(panels) {
            defaults.set(encoded, forKey: Self.panelsDefaultsKey)
        }
    }

    // MARK: - Mutations

    public func add(panel: WebPanel) {
        var copy = panel
        copy.order = (panels.map(\.order).max() ?? 0) + 1
        panels.append(copy)
        activePanelId = copy.id
    }

    public func add(title: String, url: URL, symbolName: String = "sidebar.right") {
        let panel = WebPanel(
            title: title,
            url: url,
            symbolName: symbolName,
            isPinned: true,
            order: (panels.map(\.order).max() ?? 0) + 1
        )
        add(panel: panel)
    }

    public func update(panel: WebPanel) {
        guard let index = panels.firstIndex(where: { $0.id == panel.id }) else { return }
        panels[index] = panel
    }

    public func remove(id: UUID) {
        panels.removeAll { $0.id == id }
        if activePanelId == id {
            activePanelId = panels.first?.id
        }
        if panels.isEmpty {
            resetToDefaults()
        }
    }

    public func select(id: UUID) {
        guard panels.contains(where: { $0.id == id }) else { return }
        activePanelId = id
        isOpen = true
    }

    public func togglePanel() {
        isOpen.toggle()
    }

    public func resetToDefaults() {
        panels = WebPanel.defaultPanels
        activePanelId = panels.first?.id
    }
}
