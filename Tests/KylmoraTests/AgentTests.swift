import AppKit
import Foundation
import Testing
import WebKit
@testable import Kylmora

@Suite("AI Agent Control and Semantic Automation", .serialized)
@MainActor
struct AgentTests {

    @Test("AgentSnapshotScript formats raw snapshot dictionaries into clean semantic markdown")
    func snapshotFormatting() {
        let raw: [String: Any] = [
            "title": "GitHub",
            "url": "https://github.com",
            "viewport": ["width": 1280, "height": 800],
            "elements": [
                [
                    "ref": "@1",
                    "role": "link",
                    "text": "Pull requests",
                    "x": 120,
                    "y": 45,
                    "disabled": false,
                    "focused": false
                ],
                [
                    "ref": "@2",
                    "role": "textbox",
                    "text": "Search or jump to...",
                    "x": 350,
                    "y": 45,
                    "disabled": false,
                    "focused": true
                ],
                [
                    "ref": "@3",
                    "role": "button",
                    "text": "Sign in",
                    "x": 900,
                    "y": 45,
                    "disabled": true,
                    "focused": false
                ]
            ]
        ]

        let formatted = AgentSnapshotScript.formatSemanticSnapshot(raw: raw)

        #expect(formatted.contains("[Page: \"GitHub\"]"))
        #expect(formatted.contains("[URL: https://github.com]"))
        #expect(formatted.contains("[Viewport: 1280x800]"))
        #expect(formatted.contains("- [@1] link \"Pull requests\" (x: 120, y: 45)"))
        #expect(formatted.contains("- [@2] textbox \"Search or jump to...\" (x: 350, y: 45) [focused]"))
        #expect(formatted.contains("- [@3] button \"Sign in\" (x: 900, y: 45) [disabled]"))
    }

    @Test("AgentInputSynthesizer generates natural human curved paths with Bézier waypoints")
    func bezierCurveGeneration() {
        let synthesizer = AgentInputSynthesizer.shared
        let start = CGPoint(x: 100, y: 100)
        let end = CGPoint(x: 600, y: 400)

        let path = synthesizer.generateCurvedPath(from: start, to: end)

        // Must produce intermediate waypoints
        #expect(path.count >= 6)

        // First point should be moving away from start toward end
        let firstStep = path[0]
        #expect(firstStep.x > start.x)
        #expect(firstStep.y > start.y)

        // Final landing point should be near destination within jitter radius
        let landing = path.last!
        #expect(abs(landing.x - end.x) <= 3.0)
        #expect(abs(landing.y - end.y) <= 3.0)
    }

    @Test("AgentHandoffManager handles user handoff and resume transitions")
    func handoffLifecycle() async {
        let (session, _) = TestSession.make()
        let manager = AgentHandoffManager.shared
        manager.reset()
        defer { manager.reset() }

        #expect(!manager.isUserControlling)

        let handoffResult = manager.handOff(reason: "Cloudflare Turnstile Captcha", session: session)
        #expect(manager.isUserControlling)
        #expect(handoffResult["status"] as? String == "handed_off_to_user")

        let resumeResult = manager.resume(session: session)
        #expect(!manager.isUserControlling)
        #expect(manager.isAgentDriving)
        #expect(resumeResult["status"] as? String == "agent_driving")

        _ = manager.finish()
        #expect(manager.currentState == .idle)
    }

    @Test("Agent actions fail at once while the user holds the page, as in ego lite")
    func userControlFailsFast() async throws {
        let manager = AgentHandoffManager.shared
        manager.reset()
        defer { manager.reset() }

        try manager.beginAction("Clicking")
        manager.takeOverByUser()
        #expect(throws: AgentError.self) { try manager.beginAction("Clicking again") }

        // waitForControl returns once the user gives the page back.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            manager.giveBackToAgent()
        }
        try await manager.waitForControl(timeout: 5)
        #expect(manager.isAgentDriving)

        manager.takeOverByUser()
        await #expect(throws: AgentError.self) { try await manager.waitForControl(timeout: 0.1) }
    }

    @Test("Keys map to US key codes, with shift for capitals and symbols")
    func keyMapping() {
        #expect(AgentKey.forCharacter("a").code == 0)
        #expect(AgentKey.forCharacter("A").needsShift)
        #expect(AgentKey.forCharacter("A").characters == "a")
        #expect(AgentKey.forCharacter("@").code == 19)
        #expect(AgentKey.forCharacter("@").needsShift)
        #expect(AgentKey.forCharacter("é").code == 0)
        #expect(AgentKey.named["Enter"]?.code == 36)
        #expect(AgentKey.named["ArrowDown"]?.code == 125)
    }

    @Test("The cursor's travel time follows the magic cursor's speed and clamps")
    func cursorTravelDuration() {
        let near = AgentCursorOverlayView.travelDuration(from: .zero, to: CGPoint(x: 5, y: 0))
        let far = AgentCursorOverlayView.travelDuration(from: .zero, to: CGPoint(x: 5000, y: 0))
        #expect(near == AgentCursorOverlayView.minTravel)
        #expect(far == AgentCursorOverlayView.maxTravel)
    }

    @Test("Real input reaches the page as trusted events; stale refs are caught")
    func trustedInputOnLivePage() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        window.contentView = webView
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let html = """
        <html><body style="height:2600px;margin:0">
        <h1>Sign in</h1>
        <input id=name aria-label="Name" style="position:absolute;left:40px;top:120px;width:220px;height:28px">
        <button id=go style="position:absolute;left:40px;top:1800px;width:120px;height:36px">Continue</button>
        <script>
        window.log = [];
        ['click', 'keydown', 'input', 'mousemove'].forEach(t =>
          document.addEventListener(t, e => log.push(t + ':' + e.isTrusted + ':' + (e.target.id || '')), true));
        </script></body></html>
        """
        func waitFor(_ condition: String) async throws {
            for _ in 0..<100 {
                if (try? await webView.evaluateJavaScript(condition) as? Bool) == true { return }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        webView.loadHTMLString(html, baseURL: URL(string: "https://agent.test/"))
        try await waitFor("document.readyState === 'complete' && !!document.getElementById('go')")

        let raw = try #require(try await AgentSnapshotScript.call("return agent.snapshot('full_page');", in: webView) as? [String: Any])
        let elements = try #require(raw["elements"] as? [[String: Any]])
        let input = try #require(elements.first { $0["text"] as? String == "Name" })
        let button = try #require(elements.first { $0["text"] as? String == "Continue" })
        let doc = try #require(raw["doc"] as? String)
        #expect(elements.contains { $0["role"] as? String == "heading" && ($0["ref"] as? String)?.isEmpty == true })

        // The input is on screen: click it and type.
        let inputTarget = try #require(try await AgentSnapshotScript.call(
            "return agent.target(ref, doc);", arguments: ["ref": input["ref"]!, "doc": doc], in: webView
        ) as? [String: Any])
        let synth = AgentInputSynthesizer.shared
        _ = try await synth.humanClick(at: CGPoint(x: inputTarget["x"] as! Double, y: inputTarget["y"] as! Double), in: webView)
        _ = try await synth.humanType(text: "Ada L", in: webView)
        // Keys reach the page's process asynchronously; under load the last
        // ones can still be in flight.
        try await waitFor("document.getElementById('name').value === 'Ada L'")
        let value = try await webView.evaluateJavaScript("document.getElementById('name').value") as? String
        #expect(value == "Ada L")

        // The button is below the fold: the target asks for a scroll first.
        let buttonTarget = try #require(try await AgentSnapshotScript.call(
            "return agent.target(ref, doc);", arguments: ["ref": button["ref"]!, "doc": doc], in: webView
        ) as? [String: Any])
        #expect(buttonTarget["scroll"] != nil)

        let log = try #require(try await webView.evaluateJavaScript("log.join(' ')") as? String)
        #expect(log.contains("click:true:name"))
        #expect(log.contains("keydown:true:name"))
        #expect(log.contains("input:true:name"))
        #expect(!log.contains(":false:"))

        // The page can't see the agent's helper.
        let leaked = try await webView.evaluateJavaScript("typeof globalThis.__kylmoraAgent") as? String
        #expect(leaked == "undefined")

        // After a navigation the old refs are stale, not silently retargeted.
        webView.loadHTMLString("<html><body><button id=other>Other</button></body></html>", baseURL: URL(string: "https://agent.test/next"))
        try await waitFor("document.readyState === 'complete' && !!document.getElementById('other')")
        let stale = try #require(try await AgentSnapshotScript.call(
            "return agent.target(ref, doc);", arguments: ["ref": button["ref"]!, "doc": doc], in: webView
        ) as? [String: Any])
        #expect(stale["error"] as? String == "stale")
    }

    @Test("AgentController manages tabs, spaces, and returns correct statuses")
    func controllerTabManagement() throws {
        let (session, _) = TestSession.make()
        let controller = AgentController(session: session)

        let spaces = controller.listSpaces()
        #expect(!spaces.isEmpty)

        // Open a new tab
        let openResult = try controller.openTab(url: URL(string: "https://example.com")!)
        #expect(openResult["profile"] as? String == session.activeSpace.name)
        #expect(throws: AgentError.self) { try controller.openTab(url: URL(string: "https://example.com")!, profile: "No such profile") }
        #expect(openResult["success"] as? Bool == true)
        let tabIdStr = openResult["id"] as? String
        #expect(tabIdStr != nil)

        let tabs = controller.listTabs()
        #expect(tabs.contains { ($0["id"] as? String) == tabIdStr })

        // Check status payload
        let status = controller.status()
        #expect(status["status"] as? String == "ready")
        #expect(status["browser"] as? String == "Kylmora")
        #expect((status["tabCount"] as? Int ?? 0) >= 1)

        // Close the tab
        let uuid = UUID(uuidString: tabIdStr!)!
        let closeResult = controller.closeTab(id: uuid)
        #expect(closeResult["success"] as? Bool == true)
    }

    @Test("AgentServer generates secure runtime discovery config")
    func serverRuntimeConfig() {
        let server = AgentServer.shared
        let (session, _) = TestSession.make()

        server.start(session: session)
        defer { server.stop() }

        #expect(!server.token.isEmpty)

        let userHome = FileManager.default.homeDirectoryForCurrentUser
        let dotRuntimeFile = userHome.appending(path: ".kylmora/agent-runtime.json")
        #expect(FileManager.default.fileExists(atPath: dotRuntimeFile.path))

        if let data = try? Data(contentsOf: dotRuntimeFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            #expect(json["token"] as? String == server.token)
            #expect(json["version"] as? String == "1.0.0")
        }
    }
}
