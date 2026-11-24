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

    @Test("One wait timing out does not release another while the user still holds the page")
    func timeoutWakesOnlyItsOwnWaiter() async throws {
        let manager = AgentHandoffManager.shared
        manager.reset()
        defer { manager.reset() }

        manager.takeOverByUser()
        let long = Task { @MainActor in try await manager.waitForControl(timeout: 60) }
        await #expect(throws: AgentError.self) { try await manager.waitForControl(timeout: 0.05) }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(manager.isUserControlling)

        manager.giveBackToAgent()
        try await long.value
        #expect(manager.isAgentDriving)
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
        let closeResult = try controller.closeTab(id: uuid)
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

        if let attrs = try? FileManager.default.attributesOfItem(atPath: dotRuntimeFile.path),
           let perms = attrs[.posixPermissions] as? Int {
            #expect(perms == 0o600)
        }
    }

    @Test("AgentServer sanitizes non-JSON values without crashing JSONSerialization")
    func serverSanitizesJSONValues() throws {
        let raw: [String: Any] = [
            "nan": Double.nan,
            "inf": Double.infinity,
            "date": Date(timeIntervalSince1970: 0),
            "url": URL(string: "https://example.com")!,
            "nested": [Double.nan, true, 42, "ok"] as [Any]
        ]
        let sanitized = AgentServer.sanitizeJSONValue(raw)
        #expect(JSONSerialization.isValidJSONObject(sanitized))
        let data = try JSONSerialization.data(withJSONObject: sanitized)
        let decoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(decoded["nan"] is NSNull)
        #expect(decoded["inf"] is NSNull)
        #expect(decoded["date"] as? String == "1970-01-01T00:00:00Z")
        #expect(decoded["url"] as? String == "https://example.com")
    }

    @Test("AgentHandoffManager.waitForControl respects cancellation and per-waiter timeouts")
    func waitForControlCancellationAndIndependentTimeouts() async throws {
        let (session, _) = TestSession.make()
        let manager = AgentHandoffManager.shared
        manager.reset()
        defer { manager.reset() }

        _ = manager.handOff(reason: "Login", session: session)

        // Two waiters with different timeouts: short timeout must NOT wake the longer waiter.
        let longWaiter = Task { @MainActor in
            try await manager.waitForControl(timeout: 60.0)
        }
        await #expect(throws: AgentError.self) {
            try await manager.waitForControl(timeout: 0.05)
        }
        #expect(manager.isUserControlling)

        // Cancelling the longer waiter must wake it immediately with CancellationError.
        longWaiter.cancel()
        await #expect(throws: CancellationError.self) {
            try await longWaiter.value
        }
    }

    @Test("Ego-lite selectors resolve Shadow DOM, text=, loc=role:, xpath=, nth, and selectOption")
    func egoLiteSelectorsAndShadowDOM() async throws {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView?.addSubview(webView)

        let html = """
        <html><body>
          <button id="save-btn">Save changes</button>
          <button class="dup">Item</button>
          <button class="dup">Item</button>
          <select id="month"><option value="9">September</option><option value="10">October</option></select>
          <div id="host"></div>
          <script>
            const shadow = document.getElementById("host").attachShadow({ mode: "open" });
            shadow.innerHTML = `<button id="shadow-btn">Shadow Action</button>`;
          </script>
        </body></html>
        """
        webView.loadHTMLString(html, baseURL: URL(string: "https://agent.test/"))
        for _ in 0..<40 {
            let ready = try? await webView.evaluateJavaScript("document.readyState === 'complete' && !!document.getElementById('host').shadowRoot") as? Bool
            if ready == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        // 1. Snapshot sees open Shadow DOM button
        let snap = try #require(try await AgentSnapshotScript.call("return agent.snapshot('viewport');", in: webView) as? [String: Any])
        let elements = try #require(snap["elements"] as? [[String: Any]])
        #expect(elements.contains { ($0["text"] as? String) == "Shadow Action" })

        // 2. Rich selectors resolve coordinates cleanly
        let byText = try #require(try await AgentSnapshotScript.call("return agent.target(sel, '');", arguments: ["sel": "text=\"Save changes\""], in: webView) as? [String: Any])
        #expect(byText["x"] != nil)

        let byRole = try #require(try await AgentSnapshotScript.call("return agent.target(sel, '');", arguments: ["sel": "loc=role:button[name='Shadow Action']"], in: webView) as? [String: Any])
        #expect(byRole["x"] != nil)

        let byNth = try #require(try await AgentSnapshotScript.call("return agent.target(sel, '');", arguments: ["sel": ".dup >> nth=1"], in: webView) as? [String: Any])
        #expect(byNth["x"] != nil)

        let byXPath = try #require(try await AgentSnapshotScript.call("return agent.target(sel, '');", arguments: ["sel": "xpath=//button[@id='save-btn']"], in: webView) as? [String: Any])
        #expect(byXPath["x"] != nil)

        // 3. selectOption selects by visible label
        let selRes = try #require(try await AgentSnapshotScript.call("return agent.selectOption(sel, '', opt);", arguments: ["sel": "#month", "opt": ["label": "October"]], in: webView) as? [String: Any])
        #expect(selRes["success"] as? Bool == true)
        #expect(selRes["value"] as? String == "10")
        let selectedVal = try await webView.evaluateJavaScript("document.getElementById('month').value") as? String
        #expect(selectedVal == "10")

        // 4. checkSelector verifies visible and hidden states
        let vis = try #require(try await AgentSnapshotScript.call("return agent.checkSelector(sel, '', 'visible');", arguments: ["sel": "#shadow-btn"], in: webView) as? [String: Any])
        #expect(vis["matched"] as? Bool == true)
        let hid = try #require(try await AgentSnapshotScript.call("return agent.checkSelector(sel, '', 'hidden');", arguments: ["sel": "#does-not-exist"], in: webView) as? [String: Any])
        #expect(hid["matched"] as? Bool == true)
    }

    @Test("EGM parity: ambiguity rejection, :has-text/:text-is, iframes, subtree snapshot, viewport footer, dialogs, and finish(keep:)")
    @MainActor
    func egmFullParitySuite() async throws {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let html = """
        <!doctype html>
        <html><body style="margin:0;height:2000px;">
          <button id="b1">Save</button>
          <button id="b2">Save</button>
          <button id="b3">Continue to Checkout</button>
          <a id="a1" href="#pricing">Pricing</a>
          <select id="multi" multiple>
            <option value="a">Alpha</option>
            <option value="b">Beta</option>
            <option value="c">Gamma</option>
          </select>
          <iframe id="fr" title="Inner Frame" srcdoc="<button id='inbtn'>Inside Frame</button>" style="width:200px;height:80px;border:0;"></iframe>
          <div style="margin-top:1400px;"><button id="far">Far Below</button></div>
          <script>window.__pageReady = 42;</script>
        </body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let ready = (try? await webView.evaluateJavaScript("Boolean(document.getElementById('b2') && document.getElementById('fr')?.contentDocument?.getElementById('inbtn'))") as? Bool) ?? false
            if ready { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        // 1. Ambiguity rejection vs >> nth=1
        let ambig = try await AgentSnapshotScript.call("return agent.target('text=Save', null);", in: webView) as? [String: Any]
        #expect(ambig?["error"] as? String == "ambiguous")
        let disambig = try await AgentSnapshotScript.call("return agent.target('text=Save >> nth=1', null);", in: webView) as? [String: Any]
        #expect(disambig?["error"] == nil)

        // 2. Terminal :has-text() and :text-is()
        let ht = try await AgentSnapshotScript.call("return agent.target('button:has-text(\"Checkout\")', null);", in: webView) as? [String: Any]
        #expect(ht?["error"] == nil)
        let ti = try await AgentSnapshotScript.call("return agent.target('a:text-is(\"Pricing\")', null);", in: webView) as? [String: Any]
        #expect(ti?["error"] == nil)

        // 3. Iframe element appears in snapshot + subtree snapshot works
        let snap = try await AgentSnapshotScript.call("return agent.snapshot('viewport', null);", in: webView) as? [String: Any]
        let md = AgentSnapshotScript.formatSemanticSnapshot(raw: snap ?? [:])
        #expect(md.contains("Inside Frame"))
        #expect(md.contains("[more content below the viewport:"))
        let sub = try await AgentSnapshotScript.call("return agent.snapshot('subtree', '#fr');", in: webView) as? [String: Any]
        let subMd = AgentSnapshotScript.formatSemanticSnapshot(raw: sub ?? [:])
        #expect(subMd.contains("Inside Frame"))
        #expect(!subMd.contains("Continue to Checkout"))

        // 4. selectOption multi + clear + value-or-label
        let mult = try await AgentSnapshotScript.call("return agent.selectOption('#multi', null, { values: ['Alpha', 'c'] });", in: webView) as? [String: Any]
        #expect((mult?["values"] as? [String])?.sorted() == ["a", "c"])
        let clr = try await AgentSnapshotScript.call("return agent.selectOption('#multi', null, { clear: true });", in: webView) as? [String: Any]
        #expect(clr?["cleared"] as? Bool == true)

        // 5. checkSelector(hidden) propagates syntax error instead of returning matched=true
        let badSel = try await AgentSnapshotScript.call("return agent.checkSelector('###invalid', null, 'hidden');", in: webView) as? [String: Any]
        #expect(badSel?["error"] as? String == "invalid")
        #expect(badSel?["matched"] as? Bool == false)

        // 6. JS Dialog interception + acceptDialog + auto-dismiss on finish()
        let (session, _) = TestSession.make()
        let controller = AgentController(session: session)
        AgentHandoffManager.shared.reset()
        let opened = try controller.openTab(url: URL(string: "https://example.com")!)
        let tabId = UUID(uuidString: opened["id"] as! String)!
        var promptReply: String?
        let intercepted = controller.interceptDialog(tabId: tabId, type: "prompt", message: "Name?", defaultText: "Guest") { accepted, txt in
            promptReply = accepted ? txt : nil
        }
        #expect(intercepted == true)
        #expect(controller.pendingDialogInfo(for: tabId)?["type"] as? String == "prompt")
        _ = try controller.acceptDialog(promptText: "Ada", tabId: tabId)
        #expect(promptReply == "Ada")
        #expect(controller.pendingDialogInfo(for: tabId) == nil)

        // 7. finish(keep: []) closes agent-opened tab while preserving user tabs
        let beforeCount = session.allTabs.count
        let fin = controller.finish(keep: [])
        #expect((fin["closedAgentTabs"] as? Int) == 1)
        #expect(session.allTabs.count == beforeCount - 1)
    }
}
