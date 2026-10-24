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
    /// The document each tab's refs belong to, from its last snapshot.
    private var snapshotDocuments: [UUID: String] = [:]
    private var shields: [ObjectIdentifier: AgentInputShieldView] = [:]

    init(session: BrowserSession? = nil) {
        self.session = session
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
        let key = ObjectIdentifier(webView)
        if let existing = shields[key] { return existing }
        let view = AgentInputShieldView()
        shields[key] = view
        return view
    }

    /// Waits for the tab to finish loading, up to `timeout`.
    private func waitForLoad(_ tab: Tab, timeout: TimeInterval = 15) async {
        let deadline = Date().addingTimeInterval(timeout)
        try? await Task.sleep(nanoseconds: 150_000_000)
        while tab.isLoading, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // MARK: - Tabs and spaces

    func listTabs() -> [[String: Any]] {
        guard let session else { return [] }
        return session.allTabs.map { tab in
            let spaceName = session.spaces.first { $0.tabs.contains { $0.id == tab.id } }?.name ?? "Default"
            return [
                "id": tab.id.uuidString,
                "title": tab.displayTitle,
                "url": tab.url.absoluteString,
                "active": tab.id == session.activeTab?.id,
                "agent": tab.id == agentTabID,
                "space": spaceName,
                "isLoading": tab.isLoading,
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
        bringOnScreen(tab)
        return [
            "success": true,
            "id": tab.id.uuidString,
            "url": tab.url.absoluteString,
            "title": tab.displayTitle,
            "profile": space.name,
        ]
    }

    /// Makes a tab the agent's target. The user's selection is left alone.
    func selectTab(id: UUID) -> [String: Any] {
        guard let session, session.allTabs.contains(where: { $0.id == id }) else {
            return ["success": false, "error": "Tab not found"]
        }
        agentTabID = id
        return ["success": true, "id": id.uuidString]
    }

    func closeTab(id: UUID) -> [String: Any] {
        guard let session, let tab = session.allTabs.first(where: { $0.id == id }) else {
            return ["success": false, "error": "Tab not found"]
        }
        if agentTabID == id { agentTabID = nil }
        snapshotDocuments[id] = nil
        session.closeTab(tab)
        return ["success": true, "id": id.uuidString]
    }

    func navigate(url: URL, tabId: UUID? = nil) async throws -> [String: Any] {
        let (tab, _) = try await prepare("Opening \(url.host() ?? url.absoluteString)", tabId: tabId)
        snapshotDocuments[tab.id] = nil
        tab.load(url)
        await waitForLoad(tab)
        return ["success": true, "url": tab.url.absoluteString, "title": tab.displayTitle]
    }

    // MARK: - Reading the page

    func takeSnapshot(scope: String? = nil, tabId: UUID? = nil) async throws -> [String: Any] {
        let (tab, webView) = try await prepare("Reading the page", tabId: tabId)
        let scopeName = scope == "full_page" ? "full_page" : "viewport"
        guard var result = try await AgentSnapshotScript.call(
            "return agent.snapshot(scope);", arguments: ["scope": scopeName], in: webView
        ) as? [String: Any] else {
            throw AgentError.snapshotFailed("The page returned no snapshot")
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
        let normalized = ref.hasPrefix("@") ? ref : "@\(ref)"
        for _ in 0..<6 {
            let response = try await AgentSnapshotScript.call(
                "return agent.target(ref, doc);",
                arguments: ["ref": normalized, "doc": snapshotDocuments[tab.id] ?? ""],
                in: webView
            ) as? [String: Any]
            guard let response else { throw AgentError.invalidTarget("Could not resolve \(normalized)") }
            if let message = response["message"] as? String { throw AgentError.invalidTarget(message) }
            if let scroll = response["scroll"] as? [String: Any] {
                let dx = (scroll["dx"] as? Double) ?? 0
                let dy = (scroll["dy"] as? Double) ?? 0
                _ = try await AgentInputSynthesizer.shared.humanScroll(deltaX: dx, deltaY: dy, in: webView)
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
        return result
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

    func scroll(deltaX: Double = 0, deltaY: Double = 400, tabId: UUID? = nil) async throws -> [String: Any] {
        let (_, webView) = try await prepare("Scrolling", tabId: tabId)
        return try await AgentInputSynthesizer.shared.humanScroll(deltaX: deltaX, deltaY: deltaY, in: webView)
    }

    // MARK: - Escape hatches

    /// Runs page JavaScript in the agent's isolated world. For reading state,
    /// not for acting: clicks and typing go through the real input above.
    func evaluate(script: String, tabId: UUID? = nil) async throws -> Any? {
        let (_, webView) = try await prepare("Reading the page", tabId: tabId)
        return try await webView.evaluateJavaScript(script, in: nil, contentWorld: AgentSnapshotScript.world)
    }

    func captureScreenshot(tabId: UUID? = nil) async throws -> [String: Any] {
        let (_, webView) = try await prepare("Taking a screenshot", tabId: tabId)
        let image = try await ScreenshotService.capture(webView: webView, scope: .visible)
        guard let tiffData = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiffData),
              let pngData = rep.representation(using: .png, properties: [:]) else {
            throw AgentError.screenshotFailed
        }
        return ["success": true, "format": "image/png", "base64": pngData.base64EncodedString()]
    }

    // MARK: - Control

    func handOff(reason: String) -> [String: Any] {
        AgentHandoffManager.shared.handOff(reason: reason, session: session)
    }

    func resume() -> [String: Any] {
        AgentHandoffManager.shared.resume(session: session)
    }

    func finish() -> [String: Any] {
        AgentInputSynthesizer.shared.dismissCursors()
        return AgentHandoffManager.shared.finish()
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
    case userInControl(String)
    case controlWaitTimedOut(TimeInterval)

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
        case .userInControl(let reason):
            return "USER_IN_CONTROL: the user has control of the task (\(reason)). Stop, and wait for them to give it back (waitForControl), or resume once they confirm."
        case .controlWaitTimedOut(let timeout):
            return "The user still has control after \(Int(timeout))s."
        }
    }
}
