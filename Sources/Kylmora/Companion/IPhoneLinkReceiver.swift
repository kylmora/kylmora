import AppKit
import Foundation

/// Handles routing of links sent from iPhone / iPad into Kylmora's Spaces and Tabs (F-35).
@MainActor
final class IPhoneLinkReceiver {
    static let shared = IPhoneLinkReceiver()

    /// Delegate callback for tests and external monitors.
    var onLinkReceived: ((IPhoneLink, Space) -> Void)?

    private init() {}

    /// Ingests and opens an incoming link into the target Space.
    @discardableResult
    func receive(
        link: IPhoneLink,
        session: BrowserSession,
        windowController: BrowserWindowController? = nil
    ) -> Space {
        let settings = Settings.shared

        // 1. Resolve target space
        let targetSpace: Space
        let requestedName = link.spaceName?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let requestedName, !requestedName.isEmpty,
           let matched = findSpace(named: requestedName, in: session) {
            targetSpace = matched
        } else if let requestedName, !requestedName.isEmpty, settings.iCloudInboxAutoCreateSpace {
            // Auto-create space (e.g. "Read Later" or specific project name)
            targetSpace = session.addSpace(named: requestedName)
        } else {
            // Check default configured space
            let defaultName = settings.iCloudInboxDefaultSpace.trimmingCharacters(in: .whitespacesAndNewlines)
            if !defaultName.isEmpty, let matched = findSpace(named: defaultName, in: session) {
                targetSpace = matched
            } else if !defaultName.isEmpty, settings.iCloudInboxAutoCreateSpace {
                targetSpace = session.addSpace(named: defaultName)
            } else {
                targetSpace = session.activeSpace
            }
        }

        // 2. Open link according to mode
        let effectiveMode = (link.mode == .tab && settings.iCloudInboxTargetMode != "tab")
            ? (IPhoneLink.TargetMode(rawValue: settings.iCloudInboxTargetMode) ?? .tab)
            : link.mode

        switch effectiveMode {
        case .pinned:
            let pinned = PinnedSite(url: link.url, title: link.displayTitle)
            targetSpace.addPinnedSite(pinned)
            session.changes.send(.structure)
            session.saveNow()

        case .littleArc:
            if let windowController {
                windowController.openLittleArc(url: link.url)
            } else {
                let coordinator = LittleArcCoordinator(session: session)
                coordinator.open(url: link.url, in: targetSpace)
            }

        case .tab:
            let tab = Tab(url: link.url, identity: targetSpace.identity)
            targetSpace.insert(tab, at: targetSpace.tabs.count)
            session.selectTab(tab)

            session.changes.send(.tabs)
            session.changes.send(.activeTab)
            session.saveNow()

            // If target space is not active, activate it so the user sees their link
            if targetSpace.id != session.activeSpaceID {
                session.selectSpace(targetSpace)
            }
        }

        // 3. User feedback
        if settings.iCloudInboxNotify {
            let sender = link.sender ?? "iPhone"
            let modeDesc = effectiveMode == .pinned ? "pinned in" : "opened in"
            let message = "\(sender): “\(link.displayTitle)” \(modeDesc) \(targetSpace.name)"
            session.showToast?(Toast(symbolName: "iphone", message: message))
        }

        onLinkReceived?(link, targetSpace)
        return targetSpace
    }

    private func findSpace(named name: String, in session: BrowserSession) -> Space? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }

        return session.spaces.first { space in
            space.name.lowercased() == trimmed || space.id.uuidString.lowercased() == trimmed
        }
    }
}
