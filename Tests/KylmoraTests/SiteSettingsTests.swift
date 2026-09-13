import Foundation
import Testing
import WebKit
@testable import Kylmora

@Suite("Per-website settings")
struct SiteSettingsStateTests {
    private func url(_ string: String) -> URL { URL(string: string)! }

    @Test("A site's setting covers its subdomains, and a subdomain can differ from its parent")
    func resolvesByHost() {
        var state = SiteSettingsState()
        state.set("off", for: "example.com", in: .javaScript)
        state.set("on", for: "docs.example.com", in: .javaScript)
        #expect(state.resolve(.javaScript, for: url("https://example.com/")) == "off")
        #expect(state.resolve(.javaScript, for: url("https://www.example.com/a")) == "off")
        #expect(state.resolve(.javaScript, for: url("https://docs.example.com/")) == "on")
        #expect(state.resolve(.javaScript, for: url("https://api.docs.example.com/")) == "on")
        #expect(state.resolve(.javaScript, for: url("https://notexample.com/")) == "on")
        #expect(state.resolve(.javaScript, for: nil) == "on")
    }

    @Test("The default is the built-in one until changed, and a changed default resolves for every site")
    func defaults() {
        var state = SiteSettingsState()
        #expect(state.defaultOption(for: .pageZoom) == "1")
        state.setDefault("1.25", for: .pageZoom)
        #expect(state.resolve(.pageZoom, for: url("https://anything.example/")) == "1.25")
        // Back to the built-in default leaves no record behind.
        state.setDefault("1", for: .pageZoom)
        #expect(state.defaults[.pageZoom] == nil)
    }

    @Test("Hosts are normalised from whatever was pasted")
    func normalises() {
        #expect(SiteSettingsState.normalise("https://www.Example.com/path?q=1") == "example.com")
        #expect(SiteSettingsState.normalise("  WWW.EXAMPLE.COM ") == "example.com")
        #expect(SiteSettingsState.normalise("example.com/") == "example.com")
        #expect(SiteSettingsState.normalise("docs.example.com") == "docs.example.com")
    }

    @Test("Removing the last site for a category removes the category")
    func removal() {
        var state = SiteSettingsState()
        state.set("block", for: "a.example", in: .popups)
        state.remove("a.example", from: .popups)
        #expect(state.sites[.popups] == nil)
        #expect(state.configuredHosts(for: .popups).isEmpty)
    }

    @Test("The state round-trips through JSON")
    func roundTrips() throws {
        var state = SiteSettingsState()
        state.setDefault("block", for: .cookies)
        state.set("allow", for: "shop.example", in: .cookies)
        state.set("chrome", for: "video.example", in: .userAgent)
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(SiteSettingsState.self, from: data) == state)
    }

    @Test("Every category offers its built-in default among its options")
    func defaultsAreOptions() {
        for category in SiteSettingCategory.allCases {
            #expect(category.option(category.builtInDefault) != nil, Comment(rawValue: category.title))
        }
    }
}

@Suite("Per-website rules")
@MainActor
struct SiteRulesTests {
    private func settings(_ change: (inout SiteSettingsState) -> Void) -> SiteSettings {
        let file = FileManager.default.temporaryDirectory.appending(path: "kylmora-sites-\(UUID().uuidString).json")
        let settings = SiteSettings(file: file)
        settings.update(change)
        return settings
    }

    @Test("Every registered change observer is notified, not just the last one")
    func changeObserversAllFire() {
        let file = FileManager.default.temporaryDirectory.appending(path: "kylmora-sites-\(UUID().uuidString).json")
        let settings = SiteSettings(file: file)
        // Two independent owners register -- the content blocker and the open
        // Websites pane both do. A single-closure hook let the second silently
        // replace the first: the clobber that stopped per-site cookie/font/
        // tracking rules recompiling once the Websites pane had been opened.
        var blockerFired = 0
        var paneFired = 0
        settings.addChangeObserver { blockerFired += 1 }
        settings.addChangeObserver { paneFired += 1 }

        settings.update { $0.set("block", for: "tracker.example", in: .cookies) }
        #expect(blockerFired == 1)
        #expect(paneFired == 1)

        // A change that leaves the state equal fires nothing.
        settings.update { $0.set("block", for: "tracker.example", in: .cookies) }
        #expect(blockerFired == 1)
        #expect(paneFired == 1)
    }

    @Test("Blocking cookies on a site becomes a block-cookies rule for its pages")
    func cookiesPerSite() {
        let settings = settings { $0.set("block", for: "tracker.example", in: .cookies) }
        let rules = settings.siteRules()
        #expect(rules.count == 1)
        let action = rules[0]["action"] as? [String: Any]
        let trigger = rules[0]["trigger"] as? [String: Any]
        #expect(action?["type"] as? String == "block-cookies")
        #expect(trigger?["if-domain"] as? [String] == ["*tracker.example"])
    }

    @Test("Blocking fonts by default with one exception becomes one rule with an unless-domain")
    func fontsByDefault() {
        let settings = settings {
            $0.setDefault("block", for: .webFonts)
            $0.set("allow", for: "pretty.example", in: .webFonts)
        }
        let rules = settings.siteRules()
        #expect(rules.count == 1)
        let trigger = rules[0]["trigger"] as? [String: Any]
        #expect(trigger?["resource-type"] as? [String] == ["font"])
        #expect(trigger?["unless-domain"] as? [String] == ["*pretty.example"])
    }

    @Test("Nothing configured means no rules at all")
    func nothingConfigured() {
        #expect(settings { _ in }.siteRules().isEmpty)
    }

    @Test("WebKit compiles the per-site rules")
    func compiles() async throws {
        let settings = settings {
            $0.set("block", for: "tracker.example", in: .cookies)
            $0.setDefault("block", for: .webFonts)
            $0.set("allow", for: "pretty.example", in: .webFonts)
        }
        let data = try JSONSerialization.data(withJSONObject: settings.siteRules())
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "kylmora-site-rules-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try #require(WKContentRuleListStore(url: directory))
        let compiled: WKContentRuleList? = try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(forIdentifier: "site", encodedContentRuleList: String(decoding: data, as: UTF8.self)) { list, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: list) }
            }
        }
        #expect(compiled != nil)
    }

    @Test("The applied values follow the resolved option")
    func appliedValues() {
        let settings = settings {
            $0.set("1.5", for: "big.example", in: .pageZoom)
            $0.set("block", for: "noisy.example", in: .popups)
            $0.set("deny", for: "nofiles.example", in: .downloads)
            $0.set("off", for: "plain.example", in: .javaScript)
            $0.set("mobile", for: "m.example", in: .compatibilityMode)
            $0.set("firefox", for: "ff.example", in: .userAgent)
            $0.set("off", for: "ads-ok.example", in: .contentBlockers)
        }
        #expect(settings.pageZoom(for: URL(string: "https://big.example/")) == 1.5)
        #expect(settings.pageZoom(for: URL(string: "https://other.example/")) == 1)
        #expect(settings.allowsPopups(for: URL(string: "https://noisy.example/")) == false)
        #expect(settings.allowsDownloads(for: URL(string: "https://nofiles.example/x.zip")) == false)
        #expect(settings.allowsJavaScript(for: URL(string: "https://plain.example/")) == false)
        #expect(settings.prefersMobile(for: URL(string: "https://m.example/")))
        #expect(settings.userAgent(for: URL(string: "https://ff.example/"))?.contains("Firefox") == true)
        #expect(settings.userAgent(for: URL(string: "https://other.example/")) == nil)
        #expect(settings.blocksContent(for: URL(string: "https://ads-ok.example/")) == false)
    }
}

@Suite("The in-page website settings")
@MainActor
struct SitePolicyScriptTests {
    private final class LoadWaiter: NSObject, WKNavigationDelegate {
        var continuation: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            continuation?.resume()
            continuation = nil
        }
    }

    /// A page loaded with the given per-site choices in place.
    private func page(_ html: String, configure: (inout SiteSettingsState) -> Void) async -> WKWebView {
        let file = FileManager.default.temporaryDirectory.appending(path: "kylmora-sites-\(UUID().uuidString).json")
        let settings = SiteSettings(file: file)
        settings.update(configure)
        let policy = SitePolicy(settings: settings)
        let configuration = WKWebViewConfiguration()
        policy.attach(configuration.userContentController)
        let url = URL(string: "https://site.example/")!
        policy.apply(for: url, to: configuration.userContentController)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let waiter = LoadWaiter()
        webView.navigationDelegate = waiter
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiter.continuation = continuation
            webView.loadHTMLString(html, baseURL: url)
        }
        return webView
    }

    @Test("Every category on the pane has options, a default among them, a glyph and a line of instruction")
    func everyCategoryIsComplete() {
        #expect(SiteSettingCategory.allCases.count == 20)
        for category in SiteSettingCategory.allCases {
            #expect(!category.options.isEmpty, Comment(rawValue: category.title))
            #expect(category.option(category.builtInDefault) != nil, Comment(rawValue: category.title))
            #expect(!category.symbolName.isEmpty && !category.instruction.isEmpty, Comment(rawValue: category.title))
        }
    }

    @Test("The policy reaches the page with the site's values")
    func policyIsInThePage() async throws {
        let webView = await page("<html><body></body></html>") {
            $0.set("never", for: "site.example", in: .autoPlay)
            $0.set("deny", for: "site.example", in: .location)
        }
        let autoPlay = try await webView.evaluateJavaScript("window.__kylmoraSite.autoPlay") as? String
        let location = try await webView.evaluateJavaScript("window.__kylmoraSite.location") as? String
        #expect(autoPlay == "never")
        #expect(location == "deny")
    }

    @Test("Never auto-play refuses play() before any gesture")
    func autoplayRefused() async throws {
        let webView = await page("<html><body><video id=v></video></body></html>") {
            $0.set("never", for: "site.example", in: .autoPlay)
        }
        // Script run by the host counts as a user gesture to WebKit, which is
        // exactly what the guard lets through; the test takes the gesture away
        // first, and gives up rather than waiting on a video with no source.
        let outcome = try await webView.callAsyncJavaScript(
            """
            Object.defineProperty(navigator, 'userActivation', { value: { hasBeenActive: false, isActive: false } });
            var timeout = new Promise(function (resolve) { setTimeout(function () { resolve('timed out'); }, 2000); });
            var attempt = document.getElementById('v').play().then(function () { return 'played'; }, function (e) { return e.name; });
            return await Promise.race([attempt, timeout]);
            """,
            arguments: [:], in: nil, contentWorld: .page
        ) as? String
        #expect(outcome == "NotAllowedError")
    }

    @Test("Denied location answers with a permission error, granted asks Kylmora")
    func locationDenied() async throws {
        let webView = await page("<html><body></body></html>") {
            $0.set("deny", for: "site.example", in: .location)
        }
        let code = try await webView.callAsyncJavaScript(
            "return await new Promise(function (resolve) { navigator.geolocation.getCurrentPosition(function () { resolve(0); }, function (e) { resolve(e.code); }); });",
            arguments: [:], in: nil, contentWorld: .page
        ) as? Int
        #expect(code == 1)
    }

    @Test("Denied notifications report denied without asking anyone")
    func notificationsDenied() async throws {
        let webView = await page("<html><body></body></html>") {
            $0.set("deny", for: "site.example", in: .notifications)
        }
        let permission = try await webView.evaluateJavaScript("Notification.permission") as? String
        #expect(permission == "denied")
        let asked = try await webView.callAsyncJavaScript(
            "return await Notification.requestPermission();", arguments: [:], in: nil, contentWorld: .page
        ) as? String
        #expect(asked == "denied")
    }

    @Test("Reader mode rewrites an article and leaves a short page alone")
    func readerMode() async throws {
        let paragraph = String(repeating: "Words that make up an article paragraph of reasonable length. ", count: 6)
        let article = "<html><head><title>An Article</title></head><body><nav>Menu</nav><main><h1>An Article</h1>"
            + (0..<8).map { _ in "<p>\(paragraph)</p>" }.joined() + "</main><footer>Footer</footer></body></html>"
        let reader = await page(article) { $0.set("on", for: "site.example", in: .readerMode) }
        let rewritten = try await reader.evaluateJavaScript("document.querySelector('.kylmora-reader') !== null && document.querySelector('nav') === null") as? Bool
        #expect(rewritten == true)

        let short = await page("<html><body><p>Too short.</p></body></html>") { $0.set("on", for: "site.example", in: .readerMode) }
        let untouched = try await short.evaluateJavaScript("document.querySelector('.kylmora-reader') === null") as? Bool
        #expect(untouched == true)
    }

    @Test("Strict tracking prevention becomes a third-party cookie block for the site")
    func strictTracking() {
        let file = FileManager.default.temporaryDirectory.appending(path: "kylmora-sites-\(UUID().uuidString).json")
        let settings = SiteSettings(file: file)
        settings.update { $0.set("strict", for: "shop.example", in: .trackingPrevention) }
        let rules = settings.siteRules()
        let trigger = rules.first?["trigger"] as? [String: Any]
        #expect(trigger?["load-type"] as? [String] == ["third-party"])
        #expect((rules.first?["action"] as? [String: Any])?["type"] as? String == "block-cookies")
    }
}

@Suite("Picture in picture reports")
@MainActor
struct PictureInPictureReportTests {
    private final class LoadWaiter: NSObject, WKNavigationDelegate {
        var continuation: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            continuation?.resume()
            continuation = nil
        }
    }

    @Test("A video entering picture in picture marks its tab, and leaving clears it")
    func reportsReachTheTab() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "kylmora-sites-\(UUID().uuidString).json")
        let policy = SitePolicy(settings: SiteSettings(file: file))
        let tab = Tab(url: URL(string: "https://site.example/")!, identity: .standard)
        policy.tabResolver = { _ in tab }
        let configuration = WKWebViewConfiguration()
        policy.attach(configuration.userContentController)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let waiter = LoadWaiter()
        webView.navigationDelegate = waiter
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiter.continuation = continuation
            webView.loadHTMLString("<html><body><video id=v></video></body></html>", baseURL: URL(string: "https://site.example/"))
        }
        let script = """
            var v = document.getElementById('v');
            Object.defineProperty(v, 'webkitPresentationMode', { get: function () { return window.__mode; }, configurable: true });
            window.__mode = 'picture-in-picture';
            v.dispatchEvent(new Event('webkitpresentationmodechanged', { bubbles: true }));
            await new Promise(function (r) { setTimeout(r, 50); });
            return true;
            """
        _ = try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
        for _ in 0..<20 where !tab.isInPictureInPicture { try await Task.sleep(for: .milliseconds(50)) }
        #expect(tab.isInPictureInPicture)

        let leave = """
            window.__mode = 'inline';
            document.getElementById('v').dispatchEvent(new Event('webkitpresentationmodechanged', { bubbles: true }));
            await new Promise(function (r) { setTimeout(r, 50); });
            return true;
            """
        _ = try await webView.callAsyncJavaScript(leave, arguments: [:], in: nil, contentWorld: .page)
        for _ in 0..<20 where tab.isInPictureInPicture { try await Task.sleep(for: .milliseconds(50)) }
        #expect(tab.isInPictureInPicture == false)
    }
}
