import AppKit
import Foundation
import Testing
import UserNotifications
import WebKit
@testable import Kylmora

/// A notification centre that records instead of posting.
///
/// The system's own centre traps in a process that is not a bundled
/// application, so this is the one seam in the feature: everything above it --
/// the store, the content, the click routing and the page's own script -- is
/// the real thing running for real.
@MainActor
final class RecordingNotificationBackend: WebNotificationBackend {
    var grants = true
    var refusesDelivery = false
    private(set) var authorisationsAsked = 0
    private(set) var delivered: [UNNotificationRequest] = []
    private(set) var withdrawn: [String] = []

    func authorise() async -> Bool {
        authorisationsAsked += 1
        return grants
    }

    func deliver(_ request: UNNotificationRequest) async -> Bool {
        guard !refusesDelivery else { return false }
        delivered.append(request)
        return true
    }

    func withdraw(_ identifiers: [String]) { withdrawn.append(contentsOf: identifiers) }

    var deliveredIdentifiers: [String] { delivered.map(\.identifier) }
}

@Suite("Web notifications")
@MainActor
struct WebNotificationTests {
    private func record(
        title: String = "Hello",
        body: String = "",
        tag: String = "",
        origin: String = "https://example.org",
        tabID: UUID? = nil,
        fromServiceWorker: Bool = false,
        extra: [String: Any] = [:]
    ) -> WebNotificationRecord {
        var payload: [String: Any] = ["title": title, "body": body, "tag": tag, "fromServiceWorker": fromServiceWorker]
        for (key, value) in extra { payload[key] = value }
        return WebNotificationRecord(payload: payload, id: UUID().uuidString, origin: origin, tabID: tabID)!
    }

    // MARK: - Reading what the page sent

    @Test("A payload with only a title is enough; everything else takes its spec default")
    func minimalPayload() throws {
        let made = try #require(WebNotificationRecord(
            payload: ["title": "Just this"], id: "a", origin: "https://example.org", tabID: nil
        ))
        #expect(made.title == "Just this")
        #expect(made.body.isEmpty)
        #expect(made.tag.isEmpty)
        #expect(made.icon == nil)
        #expect(made.direction == "auto")
        #expect(!made.isSilent)
        #expect(!made.requiresInteraction)
        #expect(!made.renotifies)
        #expect(made.data == nil)
        #expect(!made.isFromServiceWorker)
    }

    @Test("A payload with no title at all is not a notification")
    func titleRequired() {
        #expect(WebNotificationRecord(payload: ["body": "orphan"], id: "a", origin: "https://example.org", tabID: nil) == nil)
    }

    @Test("The page's own timestamp is honoured, and nonsense falls back to now")
    func timestamps() throws {
        let stamp = Date(timeIntervalSince1970: 1_600_000_000)
        let given = try #require(WebNotificationRecord(
            payload: ["title": "t", "timestamp": stamp.timeIntervalSince1970 * 1000],
            id: "a", origin: "https://example.org", tabID: nil
        ))
        #expect(abs(given.timestamp.timeIntervalSince(stamp)) < 0.001)

        let now = Date(timeIntervalSince1970: 500)
        let nonsense = try #require(WebNotificationRecord(
            payload: ["title": "t", "timestamp": -5], id: "a", origin: "https://example.org", tabID: nil, now: now
        ))
        #expect(nonsense.timestamp == now)
    }

    @Test("Only an icon the system could actually fetch is kept", arguments: [
        ("https://example.org/icon.png", true),
        ("http://example.org/icon.png", true),
        ("data:image/png;base64,AAAA", false),
        ("blob:https://example.org/abc", false),
        ("file:///etc/passwd", false),
        ("javascript:alert(1)", false),
        ("", false)
    ])
    func iconSchemes(candidate: String, kept: Bool) throws {
        let made = try #require(WebNotificationRecord(
            payload: ["title": "t", "icon": candidate], id: "a", origin: "https://example.org", tabID: nil
        ))
        #expect((made.icon != nil) == kept, "icon \(candidate)")
    }

    @Test("The centre shows the host, not the whole origin")
    func displayOrigin() {
        #expect(record(origin: "https://mail.example.org").displayOrigin == "mail.example.org")
        #expect(record(origin: "http://localhost:8080").displayOrigin == "localhost")
        #expect(record(origin: "not a url").displayOrigin == "not a url")
    }

    // MARK: - The store

    @Test("A tag replaces the notification it names rather than stacking on it")
    func tagReplaces() {
        var store = WebNotificationStore()
        let first = record(title: "One", tag: "chat")
        store.show(first)
        let outcome = store.show(record(title: "Two", tag: "chat"))
        #expect(outcome.displaced == [first.id])
        #expect(store.records.count == 1)
        #expect(store.records.first?.title == "Two")
    }

    @Test("An empty tag is not a tag: untagged notifications stack")
    func untaggedStack() {
        var store = WebNotificationStore()
        store.show(record(title: "One"))
        let outcome = store.show(record(title: "Two"))
        #expect(outcome.displaced.isEmpty)
        #expect(store.records.count == 2)
    }

    @Test("A tag only replaces within its own origin")
    func tagsAreOriginScoped() {
        var store = WebNotificationStore()
        store.show(record(tag: "chat", origin: "https://a.example"))
        let outcome = store.show(record(tag: "chat", origin: "https://b.example"))
        #expect(outcome.displaced.isEmpty)
        #expect(store.records.count == 2)
    }

    @Test("A page posting in a loop is capped, oldest first, without touching another site")
    func cap() {
        var store = WebNotificationStore()
        let quiet = record(title: "quiet", origin: "https://quiet.example")
        store.show(quiet)
        var noisy: [WebNotificationRecord] = []
        for index in 0..<(WebNotificationStore.limitPerOrigin + 3) {
            let made = record(title: "n\(index)", origin: "https://noisy.example")
            noisy.append(made)
            store.show(made)
        }
        #expect(store.records(origin: "https://noisy.example").count == WebNotificationStore.limitPerOrigin)
        #expect(store.records(origin: "https://quiet.example") == [quiet], "a noisy site evicts only its own")
        #expect(store.record(id: noisy[0].id) == nil, "the oldest went first")
        #expect(store.record(id: noisy.last!.id) != nil)
    }

    @Test("A site cannot close another site's notification, even knowing its identifier")
    func closeIsOriginChecked() {
        var store = WebNotificationStore()
        let theirs = record(origin: "https://bank.example")
        store.show(theirs)
        let refused = store.close(id: theirs.id, origin: "https://evil.example")
        #expect(!refused)
        #expect(store.records.count == 1)
        let allowed = store.close(id: theirs.id, origin: "https://bank.example")
        #expect(allowed)
        #expect(store.records.isEmpty)
    }

    @Test("getNotifications answers with this origin's, filtered by tag")
    func listing() {
        var store = WebNotificationStore()
        store.show(record(title: "a", tag: "x", origin: "https://a.example"))
        store.show(record(title: "b", tag: "y", origin: "https://a.example"))
        store.show(record(title: "c", tag: "x", origin: "https://b.example"))
        #expect(store.records(origin: "https://a.example").count == 2)
        #expect(store.records(origin: "https://a.example", tag: "x").map(\.title) == ["a"])
        #expect(store.records(origin: "https://nowhere.example").isEmpty)
    }

    @Test("A closing tab takes its page's notifications but leaves its worker's")
    func closingTab() {
        var store = WebNotificationStore()
        let tab = UUID()
        let other = UUID()
        let fromPage = record(title: "page", tabID: tab)
        let fromWorker = record(title: "worker", tabID: tab, fromServiceWorker: true)
        let elsewhere = record(title: "other tab", tabID: other)
        store.show(fromPage)
        store.show(fromWorker)
        store.show(elsewhere)
        let gone = store.removeAll(tabID: tab)
        #expect(gone == [fromPage.id])
        #expect(store.record(id: fromWorker.id) != nil, "a worker's notification outlives the page")
        #expect(store.record(id: elsewhere.id) != nil)
    }

    // MARK: - What the system is handed

    @Test("The content says which site sent it, and groups by that site")
    func content() async {
        let centre = WebNotificationCentre(backend: RecordingNotificationBackend())
        let made = record(title: "New message", body: "from Ada", origin: "https://chat.example")
        let content = await centre.content(for: made)
        #expect(content.title == "New message")
        #expect(content.body == "from Ada")
        #expect(content.subtitle == "chat.example", "a notification must say who sent it")
        #expect(content.threadIdentifier == "https://chat.example")
        #expect(content.sound != nil)
        #expect(content.userInfo[WebNotificationCentre.identifierKey] as? String == made.id)
        #expect(content.userInfo[WebNotificationCentre.originKey] as? String == "https://chat.example")
    }

    @Test("A silent notification is silent, and requireInteraction raises its level")
    func contentFlags() async {
        let centre = WebNotificationCentre(backend: RecordingNotificationBackend())
        let silent = await centre.content(for: record(extra: ["silent": true]))
        #expect(silent.sound == nil)
        let sticky = await centre.content(for: record(extra: ["requireInteraction": true]))
        #expect(sticky.interruptionLevel == .timeSensitive)
    }

    @Test("Showing one answers with an identifier and posts it")
    func show() async throws {
        let backend = RecordingNotificationBackend()
        let centre = WebNotificationCentre(backend: backend)
        let id = try #require(await centre.show(payload: ["title": "Hi"], origin: "https://example.org", tabID: nil))
        #expect(backend.deliveredIdentifiers == [id])
        #expect(centre.notifications(origin: "https://example.org", tag: "").count == 1)
    }

    @Test("A replaced notification leaves the screen before its replacement lands")
    func showWithdrawsReplaced() async throws {
        let backend = RecordingNotificationBackend()
        let centre = WebNotificationCentre(backend: backend)
        let first = try #require(await centre.show(payload: ["title": "One", "tag": "chat"], origin: "https://example.org", tabID: nil))
        let second = try #require(await centre.show(payload: ["title": "Two", "tag": "chat"], origin: "https://example.org", tabID: nil))
        #expect(backend.withdrawn == [first])
        #expect(centre.notifications(origin: "https://example.org", tag: "").count == 1)
        #expect(centre.notifications(origin: "https://example.org", tag: "").first?["id"] as? String == second)
    }

    @Test("A notification the system refuses is not remembered as shown")
    func refusedDelivery() async {
        let backend = RecordingNotificationBackend()
        backend.refusesDelivery = true
        let centre = WebNotificationCentre(backend: backend)
        let id = await centre.show(payload: ["title": "Hi"], origin: "https://example.org", tabID: nil)
        #expect(id == nil)
        #expect(centre.notifications(origin: "https://example.org", tag: "").isEmpty)
    }

    @Test("Closing withdraws it from the system centre; another origin's attempt does not")
    func close() async throws {
        let backend = RecordingNotificationBackend()
        let centre = WebNotificationCentre(backend: backend)
        let id = try #require(await centre.show(payload: ["title": "Hi"], origin: "https://example.org", tabID: nil))
        centre.close(id: id, origin: "https://evil.example")
        #expect(backend.withdrawn.isEmpty)
        centre.close(id: id, origin: "https://example.org")
        #expect(backend.withdrawn == [id])
    }

    // MARK: - The click, which is the whole point

    @Test("Clicking one brings its tab back and lets the page's handler run")
    func click() async throws {
        let backend = RecordingNotificationBackend()
        let centre = WebNotificationCentre(backend: backend)
        let tab = UUID()
        var focused: [UUID] = []
        var events: [(String, String)] = []
        centre.focusTab = { focused.append($0) }
        centre.dispatchEvent = { record, type in events.append((record.id, type)) }

        let id = try #require(await centre.show(payload: ["title": "Hi"], origin: "https://example.org", tabID: tab))
        centre.handle(action: UNNotificationDefaultActionIdentifier, id: id)
        #expect(focused == [tab])
        #expect(events.map(\.1) == ["click"])
        #expect(events.first?.0 == id)
        #expect(centre.notifications(origin: "https://example.org", tag: "").isEmpty, "a clicked notification is gone")
    }

    @Test("Dismissing one tells the page it closed without dragging the tab forward")
    func dismiss() async throws {
        let backend = RecordingNotificationBackend()
        let centre = WebNotificationCentre(backend: backend)
        var focused: [UUID] = []
        var events: [String] = []
        centre.focusTab = { focused.append($0) }
        centre.dispatchEvent = { _, type in events.append(type) }

        let id = try #require(await centre.show(payload: ["title": "Hi"], origin: "https://example.org", tabID: UUID()))
        centre.handle(action: UNNotificationDismissActionIdentifier, id: id)
        #expect(focused.isEmpty, "a dismissal is not a request to go there")
        #expect(events == ["close"])
    }

    @Test("An identifier the centre has never seen is ignored rather than guessed at")
    func unknownIdentifier() {
        let centre = WebNotificationCentre(backend: RecordingNotificationBackend())
        var events: [String] = []
        centre.dispatchEvent = { _, type in events.append(type) }
        centre.handle(action: UNNotificationDefaultActionIdentifier, id: "never-existed")
        #expect(events.isEmpty)
    }

    @Test("A closing tab's notifications are withdrawn from the system centre")
    func forgetTab() async throws {
        let backend = RecordingNotificationBackend()
        let centre = WebNotificationCentre(backend: backend)
        let tab = UUID()
        let id = try #require(await centre.show(payload: ["title": "Hi"], origin: "https://example.org", tabID: tab))
        centre.forget(tabID: tab)
        #expect(backend.withdrawn == [id])
    }

    // MARK: - The page's own API, in a real web view

    /// A real WebKit page, a real message bridge and the real shim. The only
    /// thing that is not the real system here is the notification centre
    /// itself, which cannot exist in a test process.
    @MainActor
    private struct PageHarness {
        let window: NSWindow
        let webView: WKWebView
        let policy: SitePolicy
        let centre: WebNotificationCentre
        let backend: RecordingNotificationBackend
        let file: URL
    }

    private func makePage(permission: String) async throws -> PageHarness {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "site-settings-\(UUID().uuidString).json")
        let settings = SiteSettings(file: file)
        settings.update { $0.set(permission, for: "example.org", in: .notifications) }
        let backend = RecordingNotificationBackend()
        let centre = WebNotificationCentre(backend: backend)
        let policy = SitePolicy(settings: settings, centre: centre)

        let configuration = WKWebViewConfiguration()
        policy.attach(configuration.userContentController)
        let url = URL(string: "https://example.org/inbox")!
        policy.apply(for: url, to: configuration.userContentController)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let webView = WKWebView(frame: window.contentView!.bounds, configuration: configuration)
        window.contentView!.addSubview(webView)
        webView.loadHTMLString("<html><body>inbox</body></html>", baseURL: url)
        for _ in 0..<400 where webView.isLoading { try await Task.sleep(for: .milliseconds(25)) }
        return PageHarness(window: window, webView: webView, policy: policy,
                           centre: centre, backend: backend, file: file)
    }

    /// Runs script until it answers with something other than nil, so a test
    /// waits on the page's own promises rather than on a fixed sleep.
    private func settle(_ webView: WKWebView, _ script: String, attempts: Int = 200) async throws -> Any? {
        for _ in 0..<attempts {
            if let value = try? await webView.evaluateJavaScript(script), !(value is NSNull) {
                return value
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        return nil
    }

    @Test("A page posts a notification, is told it was shown, and the system gets the real thing")
    func pagePostsNotification() async throws {
        let page = try await makePage(permission: "allow")
        defer { page.window.close(); try? FileManager.default.removeItem(at: page.file) }

        let permission = try await page.webView.evaluateJavaScript("Notification.permission") as? String
        #expect(permission == "granted", "an allowed site does not have to ask again")

        _ = try await page.webView.evaluateJavaScript("""
        window.__events = [];
        window.__n = new Notification("New message", { body: "from Ada", tag: "chat", icon: "/i.png" });
        window.__n.addEventListener("show", function () { window.__events.push("show"); });
        window.__n.onclick = function () { window.__events.push("click"); };
        true;
        """)

        let shown = try await settle(page.webView, "window.__events.length ? window.__events.join(',') : null") as? String
        #expect(shown == "show", "addEventListener is wired to a real EventTarget, not a stub")
        #expect(page.backend.delivered.count == 1)

        let request = try #require(page.backend.delivered.first)
        #expect(request.content.title == "New message")
        #expect(request.content.body == "from Ada")
        #expect(request.content.subtitle == "example.org")
        #expect(request.content.threadIdentifier == "https://example.org")
        #expect(request.content.userInfo[WebNotificationCentre.identifierKey] as? String == request.identifier)
    }

    @Test("A second notification with the same tag replaces the first on screen")
    func pageTagReplaces() async throws {
        let page = try await makePage(permission: "allow")
        defer { page.window.close(); try? FileManager.default.removeItem(at: page.file) }

        _ = try await page.webView.evaluateJavaScript("""
        window.__first = new Notification("One", { tag: "chat" }); true;
        """)
        _ = try await settle(page.webView, "window.__first.__id")
        let firstID = try #require(try await page.webView.evaluateJavaScript("window.__first.__id") as? String)

        _ = try await page.webView.evaluateJavaScript("""
        window.__second = new Notification("Two", { tag: "chat" }); true;
        """)
        _ = try await settle(page.webView, "window.__second.__id")

        #expect(page.backend.withdrawn == [firstID], "the replaced one leaves the screen")
        #expect(page.centre.notifications(origin: "https://example.org", tag: "chat").count == 1)
    }

    @Test("close() takes the notification off the screen rather than only firing an event")
    func pageCloses() async throws {
        let page = try await makePage(permission: "allow")
        defer { page.window.close(); try? FileManager.default.removeItem(at: page.file) }

        _ = try await page.webView.evaluateJavaScript("""
        window.__closed = false;
        window.__n = new Notification("Bye");
        window.__n.onclose = function () { window.__closed = true; };
        true;
        """)
        let id = try #require(try await settle(page.webView, "window.__n.__id") as? String)
        _ = try await page.webView.evaluateJavaScript("window.__n.close(); true;")

        let closed = try await settle(page.webView, "window.__closed ? 1 : null") as? Int
        #expect(closed == 1)
        #expect(page.backend.withdrawn == [id])
        #expect(page.centre.notifications(origin: "https://example.org", tag: "").isEmpty)
    }

    @Test("Clicking the system banner runs the page's own click handler")
    func pageReceivesClick() async throws {
        let page = try await makePage(permission: "allow")
        defer { page.window.close(); try? FileManager.default.removeItem(at: page.file) }

        // Wired exactly as the app delegate wires it: the record's identifier
        // becomes script text and the page's handler runs.
        let webView = page.webView
        page.centre.dispatchEvent = { record, type in
            let id = WebNotificationCentre.javaScriptString(record.id)
            let event = WebNotificationCentre.javaScriptString(type)
            webView.evaluateJavaScript(
                "window.__kylmoraNotificationEvent && window.__kylmoraNotificationEvent(\(id), \(event))"
            ) { _, _ in }
        }

        _ = try await page.webView.evaluateJavaScript("""
        window.__clicked = false;
        window.__n = new Notification("Ping");
        window.__n.addEventListener("click", function () { window.__clicked = true; });
        true;
        """)
        let id = try #require(try await settle(page.webView, "window.__n.__id") as? String)

        page.centre.handle(action: UNNotificationDefaultActionIdentifier, id: id)
        let clicked = try await settle(page.webView, "window.__clicked ? 1 : null") as? Int
        #expect(clicked == 1, "a notification that cannot be clicked back to its page is a dead end")
    }

    @Test("A site set to deny is told no, and its notifications never reach the system")
    func pageDenied() async throws {
        let page = try await makePage(permission: "deny")
        defer { page.window.close(); try? FileManager.default.removeItem(at: page.file) }

        let permission = try await page.webView.evaluateJavaScript("Notification.permission") as? String
        #expect(permission == "denied")

        // The answer is a promise, which `evaluateJavaScript` cannot hand back:
        // it is parked on the page and read once it settles.
        _ = try await page.webView.evaluateJavaScript(
            "window.__asked = null; Notification.requestPermission().then(function (r) { window.__asked = r; }); true;"
        )
        let asked = try await settle(page.webView, "window.__asked") as? String
        #expect(asked == "denied")
        #expect(page.backend.authorisationsAsked == 0, "a denied site does not get to raise a system prompt")

        _ = try await page.webView.evaluateJavaScript("""
        window.__errored = false;
        window.__n = new Notification("Sneaky");
        window.__n.onerror = function () { window.__errored = true; };
        true;
        """)
        let errored = try await settle(page.webView, "window.__errored ? 1 : null") as? Int
        #expect(errored == 1)
        #expect(page.backend.delivered.isEmpty)
    }

    @Test("The service worker spelling is there, and posts down the same path")
    func pageServiceWorkerSpelling() async throws {
        let page = try await makePage(permission: "allow")
        defer { page.window.close(); try? FileManager.default.removeItem(at: page.file) }

        let kind = try await page.webView.evaluateJavaScript(
            "typeof ServiceWorkerRegistration.prototype.showNotification"
        ) as? String
        #expect(kind == "function", "most sites notify through a registration, not the constructor")

        _ = try await page.webView.evaluateJavaScript("""
        window.__swDone = false;
        ServiceWorkerRegistration.prototype.showNotification.call({}, "From the worker", { body: "hello" })
          .then(function () { window.__swDone = true; });
        true;
        """)
        let done = try await settle(page.webView, "window.__swDone ? 1 : null") as? Int
        #expect(done == 1)
        #expect(page.backend.delivered.count == 1)
        #expect(page.backend.delivered.first?.content.title == "From the worker")
    }

    @Test("getNotifications answers with what this page still has on screen")
    func pageListsItsOwn() async throws {
        let page = try await makePage(permission: "allow")
        defer { page.window.close(); try? FileManager.default.removeItem(at: page.file) }

        _ = try await page.webView.evaluateJavaScript("""
        window.__a = new Notification("One", { tag: "x" });
        window.__b = new Notification("Two", { tag: "y" });
        true;
        """)
        _ = try await settle(page.webView, "window.__b.__id")

        _ = try await page.webView.evaluateJavaScript("""
        window.__list = null;
        ServiceWorkerRegistration.prototype.getNotifications.call({}, { tag: "x" })
          .then(function (list) { window.__list = list.map(function (n) { return n.title; }).join(","); });
        true;
        """)
        let titles = try await settle(page.webView, "window.__list") as? String
        #expect(titles == "One")
    }

    // MARK: - Small pieces that carry text across a boundary

    @Test("Identifiers are escaped before they become script text", arguments: [
        "plain", "with \"quotes\"", "back\\slash", "new\nline", "</script>", "😀"
    ])
    func javaScriptEscaping(value: String) async throws {
        let literal = WebNotificationCentre.javaScriptString(value)
        let webView = WKWebView(frame: .zero)
        let echoed = try await webView.evaluateJavaScript("(function () { return \(literal); })()") as? String
        #expect(echoed == value, "the literal must survive being parsed as JavaScript")
    }

    @Test("An origin is a scheme and a host, and only for the web", arguments: [
        ("https://example.org/path?q=1", "https://example.org"),
        ("http://example.org", "http://example.org"),
        ("https://example.org:8443/x", "https://example.org:8443"),
        ("HTTPS://Example.org/x", "https://Example.org")
    ])
    func origins(url: String, expected: String) {
        #expect(SitePolicy.origin(of: URL(string: url)) == expected)
    }

    @Test("A page that is not on the web has no origin to notify from", arguments: [
        "file:///Users/ada/page.html", "about:blank", "kylmora://settings", "data:text/html,<p>hi"
    ])
    func nonWebOrigins(url: String) {
        #expect(SitePolicy.origin(of: URL(string: url)) == nil)
    }
}
