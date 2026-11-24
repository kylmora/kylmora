import AppKit
import Foundation
import WebKit

/// Carries out agent requests on the live browser.
///
/// The model is ego lite's task space, mapped onto Kylmora's profiles. A
/// profile is a space: it carries its own identity, so a tab opened in it is
/// signed in wherever that profile is.
/// - the agent works in its own tab, in the profile it was asked for (the
///   current one by default), in the main window;
/// - every action first checks control, and fails at once while the user holds
///   the page;
/// - the target is brought on screen, the page is fenced, and input arrives as
///   real events from a cursor the user can watch.
@MainActor
final class AgentController {
    static let shared = AgentController()

    weak var session: BrowserSession?

    /// The tab the agent opened or chose last; its default target.
    private(set) var agentTabID: UUID?
    /// Short ego-lite-style page labels ("p1", "p2", ...) mapped to tab UUIDs.
    private var pageLabels: [String: UUID] = [:]
    private var nextPageNumber = 1
    /// The document each tab's refs belong to, from its last snapshot.
    private var snapshotDocuments: [UUID: String] = [:]
    private let shields = NSMapTable<WKWebView, AgentInputShieldView>.weakToStrongObjects()
    /// Tabs created by the agent (via openTab or popups) so finish(keep:) protects user tabs.
    private var agentOpenedTabIDs: Set<UUID> = []

    struct PendingDialog {
        let id: String
        let tabId: UUID
        let type: String
        let message: String
        let defaultText: String?
        let resolve: (_ accepted: Bool, _ promptText: String?) -> Void
    }
    private var pendingDialogs: [UUID: PendingDialog] = [:]

    struct PendingFileChooser: @unchecked Sendable {
        let id: String
        let tabId: UUID
        let allowsMultiple: Bool
        let allowsDirectories: Bool
        let completion: ([URL]?) -> Void
    }
    private var armedFiles: [UUID: [URL]] = [:]
    private var pendingChoosers: [String: PendingFileChooser] = [:]
    private var chooserWaiters: [UUID: [(id: UUID, continuation: CheckedContinuation<PendingFileChooser, Error>)]] = [:]

    private var recentPopups: [UUID: [[String: Any]]] = [:]
    private var popupWaiters: [UUID: [(id: UUID, continuation: CheckedContinuation<Tab, Error>)]] = [:]

    init(session: BrowserSession? = nil) {
        self.session = session
    }

    func label(for tabID: UUID) -> String {
        if let existing = pageLabels.first(where: { $0.value == tabID })?.key {
            return existing
        }
        let label = "p\(nextPageNumber)"
        nextPageNumber += 1
        pageLabels[label] = tabID
        return label
    }

    /// Resolves either a short page label ("p1") or a UUID string to a tab UUID.
    func resolveTabID(_ raw: String?) -> UUID? {
        guard let raw, !raw.isEmpty else { return nil }
        if let mapped = pageLabels[raw.lowercased()] { return mapped }
        return UUID(uuidString: raw)
    }

    private func targetTab(id: UUID? = nil) -> Tab? {
        guard let session else { return nil }
        if let id { return session.allTabs.first { $0.id == id } }
        if let agentTabID, let tab = session.allTabs.first(where: { $0.id == agentTabID }) { return tab }
        return session.activeTab
    }

    /// Checks control, then gets the tab's page on screen and under the fence.
    private func prepare(_ task: String, tabId: UUID?) async throws -> (Tab, WKWebView) {
        try AgentHandoffManager.shared.beginAction(task)
        guard let tab = targetTab(id: tabId) else { throw AgentError.noActiveTab }
        agentTabID = tab.id
        tab.markActive()
        let webView = tab.webView()
        bringOnScreen(tab)
        await waitUntilOnScreen(webView)
        shield(for: webView).attach(to: webView)
        AgentInputSynthesizer.shared.overlay(for: webView).attach(to: webView)
        return (tab, webView)
    }

    /// Native input only reaches a page that is on screen, so the agent's tab
    /// is brought up in its profile, the way ego lite activates its target.
    /// The app is not activated: the user's focus stays where it is.
    private func bringOnScreen(_ tab: Tab) {
        guard let session, session.activeTab?.id != tab.id || tab.webView().window == nil else { return }
        if let space = profile(of: tab) {
            session.selectSpace(space)
            session.selectTab(tab)
        }
    }

    /// Waits for a just-selected tab's page to land in the window.
    private func waitUntilOnScreen(_ webView: WKWebView) async {
        for _ in 0..<40 where webView.window == nil {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func profile(of tab: Tab) -> Space? {
        session?.spaces.first { $0.tabs.contains { $0.id == tab.id } }
    }

    /// A profile by name or id; the active one when nil.
    private func profile(named name: String?) throws -> Space {
        guard let session else { throw AgentError.noActiveTab }
        guard let name, !name.isEmpty else { return session.activeSpace }
        if let match = session.spaces.first(where: {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame || $0.id.uuidString == name
        }) {
            return match
        }
        let names = session.spaces.map(\.name).joined(separator: ", ")
        throw AgentError.invalidTarget("No profile named '\(name)'. Profiles: \(names)")
    }

    private func shield(for webView: WKWebView) -> AgentInputShieldView {
        if let existing = shields.object(forKey: webView) { return existing }
        let view = AgentInputShieldView()
        shields.setObject(view, forKey: webView)
        return view
    }

    /// Waits for the tab to finish loading, up to `timeout`, stopping uncommitted loads on timeout.
    private func waitForLoad(_ tab: Tab, timeout: TimeInterval = 30, pendingURL: String? = nil) async throws {
        let deadline = Date().addingTimeInterval(max(0.5, timeout))
        try? await Task.sleep(nanoseconds: 150_000_000)
        while tab.isLoading, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if tab.isLoading {
            tab.webView().stopLoading()
            throw AgentError.pageUnresponsive(
                currentURL: tab.url.absoluteString,
                pendingURL: pendingURL ?? tab.url.absoluteString
            )
        }
    }

    private func attachReceipt(to result: [String: Any], for tabId: UUID) -> [String: Any] {
        var out = result
        if let dialog = pendingDialogInfo(for: tabId) {
            out["dialog"] = dialog
        }
        if let popups = recentPopups.removeValue(forKey: tabId), !popups.isEmpty {
            out["popups"] = popups
        }
        return out
    }

    // MARK: - Tabs and spaces

    func listTabs() -> [[String: Any]] {
        guard let session else { return [] }
        return session.allTabs.map { tab in
            let spaceName = session.spaces.first { $0.tabs.contains { $0.id == tab.id } }?.name ?? "Default"
            return [
                "id": tab.id.uuidString,
                "page": label(for: tab.id),
                "title": tab.displayTitle,
                "url": tab.url.absoluteString,
                "active": tab.id == session.activeTab?.id,
                "agent": tab.id == agentTabID,
                "space": spaceName,
                "isLoading": tab.isLoading,
                "openedBy": agentOpenedTabIDs.contains(tab.id) ? "agent" : "user",
            ]
        }
    }

    /// Which login store a profile uses, in words.
    static func describe(_ identity: Space.Identity) -> String {
        switch identity {
        case .standard: return "standard"
        case .isolated: return "own logins"
        case .ephemeral: return "private"
        }
    }

    func listSpaces() -> [[String: Any]] {
        guard let session else { return [] }
        return session.spaces.map { space in
            [
                "id": space.id.uuidString,
                "name": space.name,
                "isPrivate": space.isPrivate,
                "identity": Self.describe(space.identity),
                "active": space.id == session.activeSpace.id,
                "tabCount": space.tabs.count,
                "activeTabId": space.activeTab?.id.uuidString ?? "",
            ]
        }
    }

    /// Opens a page for the agent in a profile (the current one by default),
    /// signed in wherever that profile is.
    func openTab(url: URL, profile name: String? = nil) throws -> [String: Any] {
        guard let session else { throw AgentError.noActiveTab }
        if case .userInControl(let reason, _) = AgentHandoffManager.shared.currentState {
            throw AgentError.userInControl(reason)
        }
        let space = try profile(named: name)
        let tab = session.newTab(url: url, inSpace: space, select: false, origin: .external)
        agentTabID = tab.id
        agentOpenedTabIDs.insert(tab.id)
        bringOnScreen(tab)
        return [
            "success": true,
            "id": tab.id.uuidString,
            "page": label(for: tab.id),
            "url": tab.url.absoluteString,
            "title": tab.displayTitle,
            "profile": space.name,
            "openedBy": "agent",
        ]
    }

    /// Makes a tab the agent's target. The user's selection is left alone.
    func selectTab(id: UUID) throws -> [String: Any] {
        try AgentHandoffManager.shared.beginAction("Selecting tab")
        guard let session, session.allTabs.contains(where: { $0.id == id }) else {
            return ["success": false, "error": "Tab not found"]
        }
        agentTabID = id
        return ["success": true, "id": id.uuidString, "page": label(for: id)]
    }

    func closeTab(id: UUID) throws -> [String: Any] {
        try AgentHandoffManager.shared.beginAction("Closing tab")
        guard let session, let tab = session.allTabs.first(where: { $0.id == id }) else {
            return ["success": false, "error": "Tab not found"]
        }
        dismissPendingResources(for: id)
        if agentTabID == id { agentTabID = nil }
        snapshotDocuments[id] = nil
        agentOpenedTabIDs.remove(id)
        pageLabels = pageLabels.filter { $0.value != id }
        session.closeTab(tab)
        return ["success": true, "id": id.uuidString]
    }

    func navigate(url: URL, timeout: TimeInterval = 30, tabId: UUID? = nil) async throws -> [String: Any] {
        let (tab, _) = try await prepare("Opening \(url.host() ?? url.absoluteString)", tabId: tabId)
        snapshotDocuments[tab.id] = nil
        tab.load(url)
        try await waitForLoad(tab, timeout: timeout, pendingURL: url.absoluteString)
        return attachReceipt(to: ["success": true, "url": tab.url.absoluteString, "title": tab.displayTitle, "page": label(for: tab.id)], for: tab.id)
    }

    func pageInfo(tabId: UUID? = nil) throws -> [String: Any] {
        guard let tab = targetTab(id: tabId) else { throw AgentError.noActiveTab }
        let wv = tab.webView()
        var info: [String: Any] = [
            "id": tab.id.uuidString,
            "page": label(for: tab.id),
            "url": tab.url.absoluteString,
            "title": tab.displayTitle,
            "isLoading": tab.isLoading,
            "canGoBack": wv.canGoBack,
            "canGoForward": wv.canGoForward,
            "profile": profile(of: tab)?.name ?? "",
            "openedBy": agentOpenedTabIDs.contains(tab.id) ? "agent" : "user",
        ]
        if let dialog = pendingDialogInfo(for: tab.id) { info["dialog"] = dialog }
        return info
    }

    // MARK: - Reading the page

    func takeSnapshot(scope: String? = nil, root: String? = nil, tabId: UUID? = nil) async throws -> [String: Any] {
        let (tab, webView) = try await prepare("Reading the page", tabId: tabId)
        let scopeName: String
        switch scope {
        case "full_page": scopeName = "full_page"
        case "subtree": scopeName = "subtree"
        default: scopeName = "viewport"
        }
        var args: [String: Any] = ["scope": scopeName]
        if let root, !root.isEmpty { args["root"] = root }
        guard var result = try await AgentSnapshotScript.call(
            "return agent.snapshot(scope, typeof root === 'undefined' ? null : root);", arguments: args, in: webView
        ) as? [String: Any] else {
            throw AgentError.snapshotFailed("The page returned no snapshot")
        }
        if let error = result["error"] as? String {
            throw AgentError.invalidTarget((result["message"] as? String) ?? error)
        }
        snapshotDocuments[tab.id] = result["doc"] as? String
        let space = session?.spaces.first { $0.tabs.contains { $0.id == tab.id } }?.name ?? ""
        result["markdown"] = "[tab \(tab.id.uuidString) | space \"\(space)\"]\n"
            + AgentSnapshotScript.formatSemanticSnapshot(raw: result)
        result["tabId"] = tab.id.uuidString
        return result
    }

    /// The page's readable text, for questions about its content. Very long
    /// pages are cut at a limit, and the result says so.
    func pageText(tabId: UUID? = nil, limit: Int = 120_000) async throws -> String {
        let (tab, webView) = try await prepare("Reading the page", tabId: tabId)
        let text = try await webView.evaluateJavaScript(
            "(document.body ? document.body.innerText : '')", in: nil, contentWorld: AgentSnapshotScript.world
        ) as? String ?? ""
        let clipped = text.count > limit
        return "Title: \(tab.displayTitle)\nURL: \(tab.url.absoluteString)\n\n"
            + (clipped ? String(text.prefix(limit)) + "\n\n[Text cut at \(limit) of \(text.count) characters.]" : text)
    }

    /// Where to click for `ref`, scrolling it into view with the wheel first.
    private func resolve(ref: String, tab: Tab, webView: WKWebView) async throws -> CGPoint {
        let normalized = ref.allSatisfy(\.isNumber) && !ref.isEmpty ? "@\(ref)" : ref
        var lastDist = Double.greatestFiniteMagnitude
        var usedProgrammaticScroll = false
        for attempt in 0..<6 {
            let response = try await AgentSnapshotScript.call(
                "return agent.target(ref, doc);",
                arguments: ["ref": normalized, "doc": snapshotDocuments[tab.id] ?? ""],
                in: webView
            ) as? [String: Any]
            guard let response else { throw AgentError.invalidTarget("Could not resolve \(normalized)") }
            if let error = response["error"] as? String {
                let msg = (response["message"] as? String) ?? error
                if error == "ambiguous" { throw AgentError.ambiguousSelector(msg) }
                if error == "stale" { throw AgentError.staleRef(msg) }
                throw AgentError.invalidTarget(msg)
            }
            if let message = response["message"] as? String { throw AgentError.invalidTarget(message) }
            if let scroll = response["scroll"] as? [String: Any] {
                let dx = (scroll["dx"] as? Double) ?? 0
                let dy = (scroll["dy"] as? Double) ?? 0
                let dist = abs(dx) + abs(dy)
                if !usedProgrammaticScroll && (attempt >= 2 || dist >= lastDist - 20) {
                    usedProgrammaticScroll = true
                    _ = try? await AgentSnapshotScript.call(
                        "return agent.scrollIntoView(ref, doc);",
                        arguments: ["ref": normalized, "doc": snapshotDocuments[tab.id] ?? ""],
                        in: webView
                    )
                    try? await Task.sleep(nanoseconds: 80_000_000)
                } else {
                    lastDist = dist
                    _ = try await AgentInputSynthesizer.shared.humanScroll(deltaX: dx, deltaY: dy, in: webView)
                }
                continue
            }
            if (response["disabled"] as? Bool) == true {
                throw AgentError.invalidTarget("\(normalized) is disabled")
            }
            if let x = response["x"] as? Double, let y = response["y"] as? Double {
                return CGPoint(x: x, y: y)
            }
        }
        throw AgentError.invalidTarget("\(normalized) did not scroll into view")
    }

    // MARK: - Acting on the page

    func click(ref: String? = nil, x: Double? = nil, y: Double? = nil, label: String? = nil, clickCount: Int = 1, tabId: UUID? = nil) async throws -> [String: Any] {
        let task = label ?? (ref.map { "Clicking \($0)" } ?? "Clicking")
        let (tab, webView) = try await prepare(task, tabId: tabId)
        let point: CGPoint
        if let ref {
            point = try await resolve(ref: ref, tab: tab, webView: webView)
        } else if let x, let y {
            point = CGPoint(x: x, y: y)
        } else {
            throw AgentError.invalidTarget("Give a ref such as @3, or x and y")
        }
        var result = try await AgentInputSynthesizer.shared.humanClick(at: point, in: webView, label: task, clickCount: clickCount)
        result["ref"] = ref ?? ""
        return attachReceipt(to: result, for: tab.id)
    }

    func hover(ref: String? = nil, x: Double? = nil, y: Double? = nil, label: String? = nil, tabId: UUID? = nil) async throws -> [String: Any] {
        let task = label ?? (ref.map { "Pointing at \($0)" } ?? "Pointing")
        let (tab, webView) = try await prepare(task, tabId: tabId)
        let point: CGPoint
        if let ref {
            point = try await resolve(ref: ref, tab: tab, webView: webView)
        } else if let x, let y {
            point = CGPoint(x: x, y: y)
        } else {
            throw AgentError.invalidTarget("Give a ref such as @3, or x and y")
        }
        try await AgentInputSynthesizer.shared.humanMove(to: point, in: webView, label: task)
        return ["success": true, "x": point.x, "y": point.y, "ref": ref ?? ""]
    }

    func type(text: String, ref: String? = nil, clear: Bool = false, tabId: UUID? = nil) async throws -> [String: Any] {
        let (tab, webView) = try await prepare("Typing", tabId: tabId)
        if let ref {
            let point = try await resolve(ref: ref, tab: tab, webView: webView)
            _ = try await AgentInputSynthesizer.shared.humanClick(at: point, in: webView, label: "Typing into \(ref)")
        }
        if clear {
            try await AgentInputSynthesizer.shared.clearFocusedField(in: webView)
        }
        return try await AgentInputSynthesizer.shared.humanType(text: text, in: webView)
    }

    func press(key: String, tabId: UUID? = nil) async throws -> [String: Any] {
        let (_, webView) = try await prepare("Pressing \(key)", tabId: tabId)
        return try await AgentInputSynthesizer.shared.humanPress(key: key, in: webView)
    }

    func scroll(deltaX: Double = 0, deltaY: Double = 400, label: String? = nil, tabId: UUID? = nil) async throws -> [String: Any] {
        let (_, webView) = try await prepare(label ?? "Scrolling", tabId: tabId)
        return try await AgentInputSynthesizer.shared.humanScroll(deltaX: deltaX, deltaY: deltaY, in: webView, label: label)
    }

    func doubleClick(ref: String? = nil, x: Double? = nil, y: Double? = nil, label: String? = nil, tabId: UUID? = nil) async throws -> [String: Any] {
        try await click(ref: ref, x: x, y: y, label: label ?? "Double-clicking", clickCount: 2, tabId: tabId)
    }

    func dragAndDrop(from: String, to: String, label: String? = nil, tabId: UUID? = nil) async throws -> [String: Any] {
        let (tab, webView) = try await prepare(label ?? "Dragging \(from) to \(to)", tabId: tabId)
        let startPt = try await resolve(ref: from, tab: tab, webView: webView)
        let endPt = try await resolve(ref: to, tab: tab, webView: webView)
        let res = try await AgentInputSynthesizer.shared.humanDragAndDrop(from: startPt, to: endPt, in: webView, label: label)
        return attachReceipt(to: res, for: tab.id)
    }

    func paste(text: String, html: String? = nil, ref: String? = nil, clear: Bool = false, tabId: UUID? = nil) async throws -> [String: Any] {
        let (tab, webView) = try await prepare("Pasting text", tabId: tabId)
        if let ref {
            let point = try await resolve(ref: ref, tab: tab, webView: webView)
            _ = try await AgentInputSynthesizer.shared.humanClick(at: point, in: webView, label: "Focusing \(ref)")
        }
        if clear {
            try await AgentInputSynthesizer.shared.clearFocusedField(in: webView)
        }
        let res = try await AgentInputSynthesizer.shared.humanPaste(text: text, html: html, in: webView)
        return attachReceipt(to: res, for: tab.id)
    }

    func focus(ref: String, tabId: UUID? = nil) async throws -> [String: Any] {
        let (tab, webView) = try await prepare("Focusing \(ref)", tabId: tabId)
        let expectedDoc = snapshotDocuments[tab.id] ?? ""
        guard let result = try await AgentSnapshotScript.call(
            "return agent.focusElement(ref, doc);",
            arguments: ["ref": ref, "doc": expectedDoc],
            in: webView
        ) as? [String: Any] else {
            throw AgentError.invalidTarget("Could not focus \(ref)")
        }
        if let error = result["error"] as? String {
            let msg = (result["message"] as? String) ?? error
            if error == "ambiguous" { throw AgentError.ambiguousSelector(msg) }
            throw AgentError.invalidTarget(msg)
        }
        return attachReceipt(to: result, for: tab.id)
    }

    func fill(ref: String, value: String, tabId: UUID? = nil) async throws -> [String: Any] {
        let (tab, webView) = try await prepare("Filling \(ref)", tabId: tabId)
        _ = try await focus(ref: ref, tabId: tab.id)
        try await AgentInputSynthesizer.shared.clearFocusedField(in: webView)
        let res = try await AgentInputSynthesizer.shared.insertText(value, in: webView)
        return attachReceipt(to: res, for: tab.id)
    }

    func insertText(text: String, tabId: UUID? = nil) async throws -> [String: Any] {
        let (tab, webView) = try await prepare("Inserting text", tabId: tabId)
        let res = try await AgentInputSynthesizer.shared.insertText(text, in: webView)
        return attachReceipt(to: res, for: tab.id)
    }

    func mouseDown(button: String = "left", tabId: UUID? = nil) async throws -> [String: Any] {
        let (_, webView) = try await prepare("Mouse down", tabId: tabId)
        return try await AgentInputSynthesizer.shared.humanMouseDown(button: button, in: webView)
    }

    func mouseUp(button: String = "left", tabId: UUID? = nil) async throws -> [String: Any] {
        let (_, webView) = try await prepare("Mouse up", tabId: tabId)
        return try await AgentInputSynthesizer.shared.humanMouseUp(button: button, in: webView)
    }

    func keyDown(key: String, tabId: UUID? = nil) async throws -> [String: Any] {
        let (_, webView) = try await prepare("Key down \(key)", tabId: tabId)
        return try AgentInputSynthesizer.shared.humanKeyDown(key: key, in: webView)
    }

    func keyUp(key: String, tabId: UUID? = nil) async throws -> [String: Any] {
        let (_, webView) = try await prepare("Key up \(key)", tabId: tabId)
        return try AgentInputSynthesizer.shared.humanKeyUp(key: key, in: webView)
    }

    func selectOption(ref: String, value: String? = nil, label: String? = nil, index: Int? = nil, values: [String]? = nil, clear: Bool = false, tabId: UUID? = nil) async throws -> [String: Any] {
        let (tab, webView) = try await prepare("Selecting option", tabId: tabId)
        let expectedDoc = snapshotDocuments[tab.id] ?? ""
        var opt: [String: Any] = [:]
        if let value { opt["value"] = value }
        if let label { opt["label"] = label }
        if let index { opt["index"] = index }
        if let values { opt["values"] = values }
        if clear { opt["clear"] = true }
        guard let result = try await AgentSnapshotScript.call(
            "return agent.selectOption(ref, doc, opt);",
            arguments: ["ref": ref, "doc": expectedDoc, "opt": opt],
            in: webView
        ) as? [String: Any] else {
            throw AgentError.invalidTarget("Could not select option on \(ref)")
        }
        if let error = result["error"] as? String {
            let msg = (result["message"] as? String) ?? error
            if error == "ambiguous" { throw AgentError.ambiguousSelector(msg) }
            throw AgentError.invalidTarget(msg)
        }
        return attachReceipt(to: result, for: tab.id)
    }

    func waitForSelector(selector: String, state: String = "visible", timeout: TimeInterval = 10, tabId: UUID? = nil) async throws -> [String: Any] {
        let (tab, webView) = try await prepare("Waiting for \(selector)", tabId: tabId)
        let expectedDoc = snapshotDocuments[tab.id] ?? ""
        let deadline = Date().addingTimeInterval(max(0.1, timeout))
        while Date() < deadline {
            if let res = try? await AgentSnapshotScript.call(
                "return agent.checkSelector(sel, doc, st);",
                arguments: ["sel": selector, "doc": expectedDoc, "st": state],
                in: webView
            ) as? [String: Any] {
                if let err = res["error"] as? String, err == "invalid" {
                    throw AgentError.invalidTarget((res["message"] as? String) ?? "Invalid selector")
                }
                if (res["matched"] as? Bool) == true {
                    return ["success": true, "selector": selector, "state": state]
                }
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        throw AgentError.invalidTarget("Timed out after \(Int(timeout))s waiting for \(selector) to be \(state)")
    }

    func waitForFunction(expression: String, timeout: TimeInterval = 10, tabId: UUID? = nil) async throws -> [String: Any] {
        let (_, webView) = try await prepare("Waiting for condition", tabId: tabId)
        let deadline = Date().addingTimeInterval(max(0.1, timeout))
        while Date() < deadline {
            let val = try await webView.callAsyncJavaScript(
                "return Boolean(\(expression));",
                arguments: [:],
                in: nil,
                contentWorld: .page
            )
            if (val as? Bool) == true {
                return ["success": true]
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        throw AgentError.invalidTarget("Timed out after \(Int(timeout))s waiting for function condition")
    }

    func waitForURL(pattern: String, timeout: TimeInterval = 10, tabId: UUID? = nil) async throws -> [String: Any] {
        let (tab, _) = try await prepare("Waiting for URL", tabId: tabId)
        let deadline = Date().addingTimeInterval(max(0.1, timeout))
        let regex: NSRegularExpression? = {
            if pattern.hasPrefix("/") && pattern.hasSuffix("/") && pattern.count >= 2 {
                let inner = String(pattern.dropFirst().dropLast())
                return try? NSRegularExpression(pattern: inner)
            }
            if pattern.contains("*") {
                let escaped = NSRegularExpression.escapedPattern(for: pattern).replacingOccurrences(of: "\\*", with: ".*")
                return try? NSRegularExpression(pattern: "^" + escaped + "$")
            }
            return nil
        }()
        while Date() < deadline {
            let current = tab.url.absoluteString
            let matched: Bool
            if let regex {
                let range = NSRange(current.startIndex..<current.endIndex, in: current)
                matched = regex.firstMatch(in: current, range: range) != nil
            } else {
                matched = current.contains(pattern)
            }
            if matched {
                return ["success": true, "url": current]
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw AgentError.invalidTarget("Timed out after \(Int(timeout))s waiting for URL matching \(pattern) (current: \(tab.url.absoluteString))")
    }

    func waitForLoadState(state: String = "load", timeout: TimeInterval = 15, tabId: UUID? = nil) async throws -> [String: Any] {
        let (tab, webView) = try await prepare("Waiting for \(state)", tabId: tabId)
        let deadline = Date().addingTimeInterval(max(0.2, timeout))
        var lastResourceCount = -1
        var stableTicks = 0
        while Date() < deadline {
            let ready = (try? await webView.callAsyncJavaScript("return document.readyState;", arguments: [:], in: nil, contentWorld: .page) as? String) ?? ""
            switch state {
            case "domcontentloaded":
                if ready == "interactive" || ready == "complete" {
                    return ["success": true, "state": state, "url": tab.url.absoluteString]
                }
            case "networkidle":
                if !tab.isLoading && ready == "complete" {
                    let count = (try? await webView.callAsyncJavaScript("return performance.getEntriesByType('resource').length;", arguments: [:], in: nil, contentWorld: .page) as? Int) ?? 0
                    if count == lastResourceCount {
                        stableTicks += 1
                        if stableTicks >= 4 {
                            return ["success": true, "state": state, "url": tab.url.absoluteString]
                        }
                    } else {
                        lastResourceCount = count
                        stableTicks = 0
                    }
                }
            default:
                if !tab.isLoading && ready == "complete" {
                    return ["success": true, "state": "load", "url": tab.url.absoluteString]
                }
            }
            try await Task.sleep(nanoseconds: 125_000_000)
        }
        throw AgentError.pageUnresponsive(currentURL: tab.url.absoluteString, pendingURL: tab.url.absoluteString)
    }

    func waitForTimeout(ms: Int) async throws -> [String: Any] {
        let clamped = max(0, min(ms, 60_000))
        try await Task.sleep(nanoseconds: UInt64(clamped) * 1_000_000)
        return ["success": true, "waitedMs": clamped]
    }

    func goBack(tabId: UUID? = nil) async throws -> [String: Any] {
        let (tab, webView) = try await prepare("Going back", tabId: tabId)
        guard webView.canGoBack else { return ["success": false, "message": "Cannot go back"] }
        webView.goBack()
        try await waitForLoad(tab)
        snapshotDocuments.removeValue(forKey: tab.id)
        return attachReceipt(to: ["success": true, "url": tab.url.absoluteString, "title": tab.displayTitle], for: tab.id)
    }

    func goForward(tabId: UUID? = nil) async throws -> [String: Any] {
        let (tab, webView) = try await prepare("Going forward", tabId: tabId)
        guard webView.canGoForward else { return ["success": false, "message": "Cannot go forward"] }
        webView.goForward()
        try await waitForLoad(tab)
        snapshotDocuments.removeValue(forKey: tab.id)
        return attachReceipt(to: ["success": true, "url": tab.url.absoluteString, "title": tab.displayTitle], for: tab.id)
    }

    func reload(timeout: TimeInterval = 30, tabId: UUID? = nil) async throws -> [String: Any] {
        let (tab, webView) = try await prepare("Reloading page", tabId: tabId)
        webView.reload()
        try await waitForLoad(tab, timeout: timeout)
        snapshotDocuments.removeValue(forKey: tab.id)
        return attachReceipt(to: ["success": true, "url": tab.url.absoluteString, "title": tab.displayTitle], for: tab.id)
    }

    // MARK: - Dialogs, File Uploads, Popups & Downloads

    func interceptDialog(
        tabId: UUID,
        type: String,
        message: String,
        defaultText: String? = nil,
        resolve: @escaping (_ accepted: Bool, _ promptText: String?) -> Void
    ) -> Bool {
        guard AgentHandoffManager.shared.isAgentDriving || agentOpenedTabIDs.contains(tabId) || agentTabID == tabId else {
            return false
        }
        if let prev = pendingDialogs.removeValue(forKey: tabId) {
            prev.resolve(false, nil)
        }
        pendingDialogs[tabId] = PendingDialog(
            id: UUID().uuidString,
            tabId: tabId,
            type: type,
            message: message,
            defaultText: defaultText,
            resolve: resolve
        )
        return true
    }

    func pendingDialogInfo(for tabId: UUID) -> [String: Any]? {
        guard let d = pendingDialogs[tabId] else { return nil }
        var out: [String: Any] = ["type": d.type, "message": d.message]
        if let def = d.defaultText { out["defaultText"] = def }
        return out
    }

    func acceptDialog(promptText: String? = nil, tabId: UUID? = nil) throws -> [String: Any] {
        guard let tab = targetTab(id: tabId) else { throw AgentError.noActiveTab }
        guard let dialog = pendingDialogs.removeValue(forKey: tab.id) else {
            throw AgentError.invalidTarget("No active JavaScript dialog on this tab")
        }
        dialog.resolve(true, promptText)
        return ["success": true, "type": dialog.type, "message": dialog.message, "accepted": true]
    }

    func dismissDialog(tabId: UUID? = nil) throws -> [String: Any] {
        guard let tab = targetTab(id: tabId) else { throw AgentError.noActiveTab }
        guard let dialog = pendingDialogs.removeValue(forKey: tab.id) else {
            throw AgentError.invalidTarget("No active JavaScript dialog on this tab")
        }
        dialog.resolve(false, nil)
        return ["success": true, "type": dialog.type, "message": dialog.message, "accepted": false]
    }

    func interceptOpenPanel(
        tabId: UUID,
        allowsMultiple: Bool,
        allowsDirectories: Bool,
        completionHandler: @escaping ([URL]?) -> Void
    ) -> Bool {
        if let files = armedFiles.removeValue(forKey: tabId) {
            let valid = allowsMultiple ? files : Array(files.prefix(1))
            completionHandler(valid)
            return true
        }
        if let waiters = chooserWaiters.removeValue(forKey: tabId), !waiters.isEmpty {
            let cid = "fc-" + UUID().uuidString.prefix(8).lowercased()
            let chooser = PendingFileChooser(id: cid, tabId: tabId, allowsMultiple: allowsMultiple, allowsDirectories: allowsDirectories, completion: completionHandler)
            pendingChoosers[cid] = chooser
            for w in waiters { w.continuation.resume(returning: chooser) }
            return true
        }
        if AgentHandoffManager.shared.isAgentDriving {
            let cid = "fc-" + UUID().uuidString.prefix(8).lowercased()
            pendingChoosers[cid] = PendingFileChooser(id: cid, tabId: tabId, allowsMultiple: allowsMultiple, allowsDirectories: allowsDirectories, completion: completionHandler)
            return true
        }
        return false
    }

    private func validateFilePaths(_ files: [String]) throws -> [URL] {
        let fm = FileManager.default
        return try files.map { path in
            guard path.hasPrefix("/") else {
                throw AgentError.invalidTarget("File path must be absolute: \(path)")
            }
            guard fm.fileExists(atPath: path) else {
                throw AgentError.invalidTarget("File does not exist: \(path)")
            }
            return URL(fileURLWithPath: path)
        }
    }

    func setInputFiles(ref: String, files: [String], tabId: UUID? = nil) async throws -> [String: Any] {
        let urls = try validateFilePaths(files)
        let (tab, webView) = try await prepare("Uploading \(urls.count) file(s)", tabId: tabId)
        armedFiles[tab.id] = urls
        defer { armedFiles.removeValue(forKey: tab.id) }
        let point = try await resolve(ref: ref, tab: tab, webView: webView)
        _ = try await AgentInputSynthesizer.shared.humanClick(at: point, in: webView, label: "Choosing file")
        let deadline = Date().addingTimeInterval(3)
        while armedFiles[tab.id] != nil && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return attachReceipt(to: ["success": true, "files": urls.map(\.path)], for: tab.id)
    }

    func waitForFileChooser(timeout: TimeInterval = 10, tabId: UUID? = nil) async throws -> [String: Any] {
        let (tab, _) = try await prepare("Waiting for file chooser", tabId: tabId)
        if let existing = pendingChoosers.values.first(where: { $0.tabId == tab.id }) {
            return ["chooserId": existing.id, "allowsMultiple": existing.allowsMultiple, "allowsDirectories": existing.allowsDirectories]
        }
        let waiterId = UUID()
        let chooser = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var list = chooserWaiters[tab.id] ?? []
                list.append((id: waiterId, continuation: continuation))
                chooserWaiters[tab.id] = list
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(max(0.1, timeout) * 1_000_000_000))
                    self?.failChooserWaiter(tabId: tab.id, waiterId: waiterId, error: AgentError.invalidTarget("Timed out waiting for file chooser"))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.failChooserWaiter(tabId: tab.id, waiterId: waiterId, error: CancellationError())
            }
        }
        return ["chooserId": chooser.id, "allowsMultiple": chooser.allowsMultiple, "allowsDirectories": chooser.allowsDirectories]
    }

    private func failChooserWaiter(tabId: UUID, waiterId: UUID, error: Error) {
        guard var list = chooserWaiters[tabId], let idx = list.firstIndex(where: { $0.id == waiterId }) else { return }
        let item = list.remove(at: idx)
        if list.isEmpty { chooserWaiters.removeValue(forKey: tabId) } else { chooserWaiters[tabId] = list }
        item.continuation.resume(throwing: error)
    }

    func setChooserFiles(chooserId: String, files: [String]) throws -> [String: Any] {
        let urls = try validateFilePaths(files)
        guard let chooser = pendingChoosers.removeValue(forKey: chooserId) else {
            throw AgentError.invalidTarget("Unknown file chooser: \(chooserId)")
        }
        if urls.count > 1 && !chooser.allowsMultiple {
            chooser.completion(nil)
            throw AgentError.invalidTarget("File chooser does not allow multiple files")
        }
        chooser.completion(urls)
        return ["success": true, "files": urls.map(\.path)]
    }

    func cancelFileChooser(chooserId: String) throws -> [String: Any] {
        guard let chooser = pendingChoosers.removeValue(forKey: chooserId) else {
            throw AgentError.invalidTarget("Unknown file chooser: \(chooserId)")
        }
        chooser.completion(nil)
        return ["success": true, "cancelled": true]
    }

    func recordPopup(from parentTabId: UUID, childTab: Tab) {
        agentOpenedTabIDs.insert(childTab.id)
        let lbl = label(for: childTab.id)
        let entry: [String: Any] = ["id": childTab.id.uuidString, "page": lbl, "url": childTab.url.absoluteString]
        var list = recentPopups[parentTabId] ?? []
        list.append(entry)
        recentPopups[parentTabId] = list
        if let waiters = popupWaiters.removeValue(forKey: parentTabId) {
            for w in waiters { w.continuation.resume(returning: childTab) }
        }
    }

    func waitForPopup(timeout: TimeInterval = 10, tabId: UUID? = nil) async throws -> [String: Any] {
        let (tab, _) = try await prepare("Waiting for popup", tabId: tabId)
        if let list = recentPopups.removeValue(forKey: tab.id), let first = list.first {
            return first
        }
        let waiterId = UUID()
        let child = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var list = popupWaiters[tab.id] ?? []
                list.append((id: waiterId, continuation: continuation))
                popupWaiters[tab.id] = list
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(max(0.1, timeout) * 1_000_000_000))
                    self?.failPopupWaiter(tabId: tab.id, waiterId: waiterId, error: AgentError.invalidTarget("Timed out waiting for popup"))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.failPopupWaiter(tabId: tab.id, waiterId: waiterId, error: CancellationError())
            }
        }
        return ["id": child.id.uuidString, "page": label(for: child.id), "url": child.url.absoluteString, "title": child.displayTitle]
    }

    private func failPopupWaiter(tabId: UUID, waiterId: UUID, error: Error) {
        guard var list = popupWaiters[tabId], let idx = list.firstIndex(where: { $0.id == waiterId }) else { return }
        let item = list.remove(at: idx)
        if list.isEmpty { popupWaiters.removeValue(forKey: tabId) } else { popupWaiters[tabId] = list }
        item.continuation.resume(throwing: error)
    }

    func waitForDownload(timeout: TimeInterval = 30, tabId: UUID? = nil) async throws -> [String: Any] {
        let (tab, _) = try await prepare("Waiting for download", tabId: tabId)
        let record = try await AgentDownloadManager.shared.waitForDownload(tabId: tab.id, timeout: timeout)
        return record.toDictionary()
    }

    func saveDownload(downloadId: String, path: String) async throws -> [String: Any] {
        try await AgentDownloadManager.shared.saveAs(downloadId: downloadId, destinationPath: path)
    }

    func cancelDownload(downloadId: String) throws -> [String: Any] {
        try AgentDownloadManager.shared.cancel(downloadId: downloadId)
    }

    private func dismissPendingResources(for tabId: UUID) {
        if let d = pendingDialogs.removeValue(forKey: tabId) { d.resolve(false, nil) }
        armedFiles.removeValue(forKey: tabId)
        for (cid, chooser) in pendingChoosers where chooser.tabId == tabId {
            pendingChoosers.removeValue(forKey: cid)
            chooser.completion(nil)
        }
        recentPopups.removeValue(forKey: tabId)
    }

    // MARK: - Reading the page, In-Page Fetch & WebKit-Native CDP Replacements

    /// Runs a script in the page's main world (so window.* globals are readable) with optional arg and timeout.
    private struct AnySendableBox: @unchecked Sendable { let value: Any? }

    func evaluate(script: String, arg: Any? = nil, timeout: TimeInterval = 15, tabId: UUID? = nil) async throws -> Any? {
        let (_, webView) = try await prepare("Reading the page", tabId: tabId)
        let args: [String: Any] = arg != nil ? ["arg": arg!] : [:]
        let body = script.contains("return ") ? script : "return (\(script));"
        var settled = false
        let boxed: AnySendableBox = try await withCheckedThrowingContinuation { continuation in
            let timerTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(0.2, timeout) * 1_000_000_000))
                if !settled {
                    settled = true
                    continuation.resume(throwing: AgentError.evalTimedOut(timeout))
                }
            }
            Task { @MainActor in
                do {
                    let val = try await webView.callAsyncJavaScript(body, arguments: args, in: nil, contentWorld: .page)
                    timerTask.cancel()
                    if !settled {
                        settled = true
                        continuation.resume(returning: AnySendableBox(value: val))
                    }
                } catch {
                    timerTask.cancel()
                    if !settled {
                        settled = true
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
        return boxed.value
    }

    /// Runs window.fetch() in the page with its cookies/session/CORS; supports binary saveAs.
    func pageFetch(
        url: String,
        method: String = "GET",
        headers: [String: String] = [:],
        body: String? = nil,
        saveAs: String? = nil,
        timeout: TimeInterval = 15,
        tabId: UUID? = nil
    ) async throws -> [String: Any] {
        if let saveAs, !saveAs.hasPrefix("/") {
            throw AgentError.invalidTarget("fetch saveAs path must be absolute: \(saveAs)")
        }
        let (_, webView) = try await prepare("Fetching \(url)", tabId: tabId)
        let js = """
        const ctrl = new AbortController();
        const timer = setTimeout(() => ctrl.abort(), timeoutMs);
        try {
          const init = { method, headers, signal: ctrl.signal };
          if (body !== null && body !== undefined && method !== 'GET' && method !== 'HEAD') init.body = body;
          const res = await fetch(url, init);
          const hdrs = {};
          res.headers.forEach((v, k) => { hdrs[k] = v; });
          if (binary) {
            const buf = new Uint8Array(await res.arrayBuffer());
            let bin = '';
            for (let i = 0; i < buf.length; i += 8192) {
              bin += String.fromCharCode(...buf.subarray(i, i + 8192));
            }
            return { ok: res.ok, status: res.status, statusText: res.statusText, url: res.url, headers: hdrs, base64: btoa(bin) };
          } else {
            const text = await res.text();
            return { ok: res.ok, status: res.status, statusText: res.statusText, url: res.url, headers: hdrs, body: text };
          }
        } finally {
          clearTimeout(timer);
        }
        """
        var args: [String: Any] = [
            "url": url,
            "method": method.uppercased(),
            "headers": headers,
            "timeoutMs": Int(max(100, timeout * 1000)),
            "binary": saveAs != nil,
        ]
        if let body { args["body"] = body }
        guard var result = try await webView.callAsyncJavaScript(js, arguments: args, in: nil, contentWorld: .page) as? [String: Any] else {
            throw AgentError.invalidTarget("Fetch returned no result")
        }
        if let saveAs, let b64 = result.removeValue(forKey: "base64") as? String, let data = Data(base64Encoded: b64) {
            let dst = URL(fileURLWithPath: saveAs)
            try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: dst, options: .atomic)
            result["savedTo"] = dst.path
            result["bytes"] = data.count
        }
        return result
    }

    func listCookies(url: String? = nil, tabId: UUID? = nil) async throws -> [String: Any] {
        let (_, webView) = try await prepare("Reading cookies", tabId: tabId)
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let all = await store.allCookies()
        let filterHost = url.flatMap { URL(string: $0)?.host?.lowercased() }
        let filtered = all.filter { cookie in
            guard let filterHost else { return true }
            let dom = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return filterHost == dom || filterHost.hasSuffix("." + dom)
        }
        let items: [[String: Any]] = filtered.map { c in
            [
                "name": c.name,
                "value": c.value,
                "domain": c.domain,
                "path": c.path,
                "secure": c.isSecure,
                "httpOnly": c.isHTTPOnly,
            ]
        }
        return ["cookies": items, "count": items.count]
    }

    func setCookie(name: String, value: String, domain: String, path: String = "/", secure: Bool = true, tabId: UUID? = nil) async throws -> [String: Any] {
        let (_, webView) = try await prepare("Setting cookie", tabId: tabId)
        var props: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: value, .domain: domain, .path: path,
        ]
        if secure { props[.secure] = "TRUE" }
        guard let cookie = HTTPCookie(properties: props) else {
            throw AgentError.invalidTarget("Invalid cookie properties")
        }
        await webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        return ["success": true, "name": name, "domain": domain]
    }

    func deleteCookie(name: String, domain: String? = nil, tabId: UUID? = nil) async throws -> [String: Any] {
        let (_, webView) = try await prepare("Deleting cookie", tabId: tabId)
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let all = await store.allCookies()
        var deleted = 0
        for c in all where c.name == name {
            if let domain, !c.domain.lowercased().contains(domain.lowercased()) { continue }
            await store.deleteCookie(c)
            deleted += 1
        }
        return ["success": true, "deleted": deleted]
    }

    func exportPDF(path: String, tabId: UUID? = nil) async throws -> [String: Any] {
        guard path.hasPrefix("/") else {
            throw AgentError.invalidTarget("PDF path must be absolute: \(path)")
        }
        let (_, webView) = try await prepare("Exporting PDF", tabId: tabId)
        let data = try await webView.pdf(configuration: WKPDFConfiguration())
        let dst = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: dst, options: .atomic)
        return ["success": true, "path": dst.path, "bytes": data.count]
    }

    func clearStorage(origin: String, types: [String] = ["cookies", "localStorage", "cache", "indexedDB"], tabId: UUID? = nil) async throws -> [String: Any] {
        let (_, webView) = try await prepare("Clearing storage for \(origin)", tabId: tabId)
        let host = (URL(string: origin)?.host ?? origin).lowercased()
        let store = webView.configuration.websiteDataStore
        var dataTypes = Set<String>()
        for t in types {
            switch t.lowercased() {
            case "cookies": dataTypes.insert(WKWebsiteDataTypeCookies)
            case "localstorage": dataTypes.insert(WKWebsiteDataTypeLocalStorage)
            case "sessionstorage": dataTypes.insert(WKWebsiteDataTypeSessionStorage)
            case "indexeddb": dataTypes.insert(WKWebsiteDataTypeIndexedDBDatabases)
            case "cache":
                dataTypes.insert(WKWebsiteDataTypeDiskCache)
                dataTypes.insert(WKWebsiteDataTypeMemoryCache)
                dataTypes.insert(WKWebsiteDataTypeFetchCache)
            default: break
            }
        }
        if dataTypes.isEmpty { dataTypes = WKWebsiteDataStore.allWebsiteDataTypes() }
        let records = await store.dataRecords(ofTypes: dataTypes)
        let matching = records.filter { host == $0.displayName.lowercased() || host.hasSuffix("." + $0.displayName.lowercased()) }
        await store.removeData(ofTypes: dataTypes, for: matching)
        return ["success": true, "origin": host, "clearedRecords": matching.count]
    }

    func captureScreenshot(path: String? = nil, includeBase64: Bool = false, tabId: UUID? = nil) async throws -> [String: Any] {
        let (_, webView) = try await prepare("Taking a screenshot", tabId: tabId)
        let image = try await ScreenshotService.capture(webView: webView, scope: .visible)
        guard let tiffData = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiffData),
              let pngData = rep.representation(using: .png, properties: [:]) else {
            throw AgentError.screenshotFailed
        }
        let targetURL: URL
        if let path, !path.isEmpty {
            guard path.hasPrefix("/") else {
                throw AgentError.invalidTarget("Screenshot path must be absolute")
            }
            targetURL = URL(fileURLWithPath: path)
        } else {
            targetURL = FileManager.default.temporaryDirectory
                .appending(path: "kylmora-screenshot-\(UUID().uuidString.prefix(8)).png")
        }
        try FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pngData.write(to: targetURL, options: .atomic)
        var result: [String: Any] = [
            "success": true,
            "format": "image/png",
            "path": targetURL.path(percentEncoded: false),
            "width": rep.pixelsWide,
            "height": rep.pixelsHigh,
        ]
        if includeBase64 {
            result["base64"] = pngData.base64EncodedString()
        }
        return result
    }

    // MARK: - Control

    func handOff(reason: String) -> [String: Any] {
        AgentHandoffManager.shared.handOff(reason: reason, session: session)
    }

    func resume() -> [String: Any] {
        AgentHandoffManager.shared.resume(session: session)
    }

    func finish(keep: [String]? = nil) -> [String: Any] {
        for tabId in Array(pendingDialogs.keys) { dismissPendingResources(for: tabId) }
        for (cid, chooser) in pendingChoosers {
            pendingChoosers.removeValue(forKey: cid)
            chooser.completion(nil)
        }
        var closedCount = 0
        var protectedUserTabs: [String] = []
        if let keep, let session {
            let keepIDs = Set(keep.compactMap { resolveTabID($0) })
            for id in Array(agentOpenedTabIDs) where !keepIDs.contains(id) {
                if let tab = session.allTabs.first(where: { $0.id == id }) {
                    session.closeTab(tab)
                    closedCount += 1
                }
                agentOpenedTabIDs.remove(id)
                snapshotDocuments.removeValue(forKey: id)
                pageLabels = pageLabels.filter { $0.value != id }
                if agentTabID == id { agentTabID = nil }
            }
            for tab in session.allTabs where !agentOpenedTabIDs.contains(tab.id) {
                protectedUserTabs.append(label(for: tab.id))
            }
        }
        AgentInputSynthesizer.shared.dismissCursors()
        var out = AgentHandoffManager.shared.finish()
        if keep != nil {
            out["closedAgentTabs"] = closedCount
            if !protectedUserTabs.isEmpty { out["protectedUserTabs"] = protectedUserTabs }
        }
        return out
    }

    func waitForControl(timeout: TimeInterval) async throws -> [String: Any] {
        try await AgentHandoffManager.shared.waitForControl(timeout: timeout)
        return status()
    }

    func status() -> [String: Any] {
        let manager = AgentHandoffManager.shared
        let control: String
        let detail: String
        switch manager.currentState {
        case .idle:
            control = "idle"
            detail = ""
        case .agentDriving(let task):
            control = "agent"
            detail = task
        case .userInControl(let reason, _):
            control = "user"
            detail = reason
        }
        return [
            "status": "ready",
            "browser": "Kylmora",
            "control": control,
            "detail": detail,
            "isUserControlling": manager.isUserControlling,
            "agentTab": targetTab()?.id.uuidString ?? "",
            "activeSpace": session?.activeSpace.name ?? "",
            "tabCount": session?.allTabs.count ?? 0,
        ]
    }
}

public enum AgentError: LocalizedError {
    case noActiveTab
    case webViewNotLoaded
    case snapshotFailed(String)
    case screenshotFailed
    case invalidTarget(String)
    case ambiguousSelector(String)
    case staleRef(String)
    case pageUnresponsive(currentURL: String, pendingURL: String)
    case evalTimedOut(TimeInterval)
    case userInControl(String)
    case controlWaitTimedOut(TimeInterval)

    public var errorCode: String {
        switch self {
        case .noActiveTab: return "NO_ACTIVE_TAB"
        case .webViewNotLoaded: return "WEBVIEW_NOT_LOADED"
        case .snapshotFailed: return "SNAPSHOT_FAILED"
        case .screenshotFailed: return "SCREENSHOT_FAILED"
        case .invalidTarget: return "INVALID_TARGET"
        case .ambiguousSelector: return "AMBIGUOUS_SELECTOR"
        case .staleRef: return "STALE_REF"
        case .pageUnresponsive: return "KYLMORA_PAGE_UNRESPONSIVE"
        case .evalTimedOut: return "KYLMORA_EVAL_TIMEOUT"
        case .userInControl: return "USER_IN_CONTROL"
        case .controlWaitTimedOut: return "CONTROL_WAIT_TIMEOUT"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .noActiveTab:
            return "No tab for the agent to work in. Open one first."
        case .webViewNotLoaded:
            return "The tab's page is not loaded."
        case .snapshotFailed(let msg):
            return "Snapshot failed: \(msg)"
        case .screenshotFailed:
            return "Could not capture a screenshot of the page."
        case .invalidTarget(let msg):
            return msg
        case .ambiguousSelector(let msg):
            return "AMBIGUOUS_SELECTOR: \(msg)"
        case .staleRef(let msg):
            return "STALE_REF: \(msg)"
        case .pageUnresponsive(let cur, let pending):
            return "KYLMORA_PAGE_UNRESPONSIVE: navigation to \(pending) timed out and was stopped; page remains on \(cur)"
        case .evalTimedOut(let t):
            return "KYLMORA_EVAL_TIMEOUT: evaluation exceeded \(Int(t))s (mayHaveLateEffects=true)"
        case .userInControl(let reason):
            return "USER_IN_CONTROL: the user has control of the task (\(reason)). Stop, and wait for them to give it back (waitForControl), or resume once they confirm."
        case .controlWaitTimedOut(let timeout):
            return "The user still has control after \(Int(timeout))s."
        }
    }
}
