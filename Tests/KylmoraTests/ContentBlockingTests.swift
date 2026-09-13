import WebKit
import Foundation
import Testing
@testable import Kylmora

@Suite("Converting filter lists to WebKit rules")
struct AdblockRuleConverterTests {
    private func convert(_ lines: String...) -> AdblockRuleConverter.Output {
        AdblockRuleConverter().convert(lines.joined(separator: "\n"))
    }

    @Test("Comments and headers are not rules")
    func commentsAreSkippedSilently() {
        let output = convert("[Adblock Plus 2.0]", "! Title: Test", "", "   ")
        #expect(output.rules.isEmpty)
        #expect(output.skipped == 0)
    }

    @Test("A host anchor matches the host and its subdomains, on every request type")
    func hostAnchor() {
        let output = convert("||ads.example.com^")
        #expect(output.rules.count == 1)
        let rule = output.rules[0]
        #expect(rule.actionType == "block")
        #expect(rule.urlFilter == "^[^:]+:(//)?([^/]+\\.)?ads\\.example\\.com[^-_.%a-zA-Z0-9]")
        #expect(rule.resourceTypes == nil)
        #expect(rule.loadTypes == nil)
    }

    @Test("Options become resource types, load types and domains")
    func options() {
        let output = convert("/banner.$script,image,third-party,domain=a.com|~b.com")
        let rule = output.rules[0]
        #expect(rule.urlFilter == "/banner\\.")
        #expect(rule.resourceTypes == ["script", "image"])
        #expect(rule.loadTypes == ["third-party"])
        // WebKit cannot hold both in one trigger; the includes win.
        #expect(rule.ifDomain == ["*a.com"])
        #expect(rule.unlessDomain == nil)
    }

    @Test("Wildcards, separators and edge anchors translate")
    func patternSyntax() {
        #expect(AdblockRuleConverter.regex(for: "|http://x.com/*/ad^") == "^http://x\\.com/.*/ad[^-_.%a-zA-Z0-9]")
        #expect(AdblockRuleConverter.regex(for: "tracker.js|") == "tracker\\.js$")
        #expect(AdblockRuleConverter.regex(for: "") == ".*")
    }

    @Test("Exceptions come last and ignore what precedes them")
    func exceptionsFollowBlocks() {
        let output = convert("@@||good.example.com^", "||example.com^")
        #expect(output.rules.map(\.actionType) == ["block", "ignore-previous-rules"])
    }

    @Test("A whole-page exception is keyed on the top-level page")
    func documentException() {
        let output = convert("@@||trusted.example^$document")
        let rule = output.rules[0]
        #expect(rule.actionType == "ignore-previous-rules")
        #expect(rule.urlFilter == ".*")
        #expect(rule.ifTopURL?.count == 1)
        // A page-wide option on a blocking rule has no WebKit meaning.
        #expect(convert("||example.com^$document").skipped == 1)
    }

    @Test("Element hiding becomes a display-none rule, generic or per domain")
    func elementHiding() {
        let output = convert("##.advert", "news.example,~sub.news.example##div#sponsored")
        #expect(output.rules.count == 2)
        #expect(output.rules[0].actionType == "css-display-none")
        #expect(output.rules[0].selector == ".advert")
        #expect(output.rules[0].urlFilter == ".*")
        #expect(output.rules[1].ifDomain == ["*news.example"])
    }

    @Test("What WebKit cannot express is skipped and counted, never guessed")
    func unsupportedIsSkipped() {
        let output = convert(
            "/^https?://.*ads/",            // regular expression
            "example.com#@#.advert",        // hiding exception
            "example.com##.a:has(.b)",      // extended CSS
            "example.com##+js(nowoif)",     // scriptlet
            "||x.com^$redirect=noopjs",     // redirect
            "||y.com^$csp=script-src",      // csp
            "||z.com^$badfilter",           // badfilter
            "||\u{00e9}xample.com^"          // non-ASCII
        )
        #expect(output.rules.isEmpty)
        #expect(output.skipped == 8)
    }

    @Test("Negated resource types become the complement")
    func negatedTypes() {
        let output = convert("||cdn.example^$~image,~font")
        let types = Set(output.rules[0].resourceTypes ?? [])
        #expect(!types.contains("image"))
        #expect(!types.contains("font"))
        #expect(types.contains("script"))
    }

    @Test("The output is JSON WebKit's format expects")
    func encodes() throws {
        let output = convert("||ads.example^$script", "##.advert")
        let json = try output.encoded()
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        #expect(parsed?.count == 2)
        let trigger = parsed?[0]["trigger"] as? [String: Any]
        #expect(trigger?["resource-type"] as? [String] == ["script"])
        let action = parsed?[1]["action"] as? [String: Any]
        #expect(action?["type"] as? String == "css-display-none")
    }

    @Test("Over the limit, cosmetic rules go before blocking ones")
    func truncation() {
        var lines: [String] = []
        for i in 0..<100_000 { lines.append("||site\(i).example^") }
        for i in 0..<60_000 { lines.append("##.ad\(i)") }
        let output = AdblockRuleConverter().convert(lines.joined(separator: "\n"))
        #expect(output.rules.count == AdblockRuleConverter.maximumRules)
        #expect(output.truncated == 10_000)
        #expect(output.rules.filter { $0.actionType == "block" }.count == 100_000)
    }
}

@Suite("Content blocking preferences")
struct ContentBlockingPreferencesTests {
    @Test("Every list in the catalogue has a unique id and a usable address")
    func catalogueIsWellFormed() {
        let ids = FilterList.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        for list in FilterList.all {
            #expect(list.url.scheme == "https", Comment(rawValue: list.name))
        }
    }

    @Test("The defaults block ads, trackers and cookie banners and no regional list")
    func defaults() {
        let active = ContentBlockingPreferences().activeLists()
        #expect(!active.isEmpty)
        #expect(active.allSatisfy { $0.category != .regional })
        #expect(active.contains { $0.id == "easylist" })
        #expect(active.contains { $0.id == "easyprivacy" })
        #expect(active.contains { $0.id == "easylist-cookies" })
    }

    @Test("A switch takes its whole category with it, regional riding on ads")
    func switchesGovernCategories() {
        var preferences = ContentBlockingPreferences()
        preferences.listOverrides["ru-adlist"] = true
        #expect(preferences.activeLists().contains { $0.id == "ru-adlist" })
        preferences.blocksAds = false
        let active = preferences.activeLists()
        #expect(!active.contains { $0.category == .ads })
        #expect(!active.contains { $0.id == "ru-adlist" })
        #expect(active.contains { $0.category == .trackers })
    }

    @Test("A list can be turned off inside an enabled category")
    func overridesWithinCategory() {
        var preferences = ContentBlockingPreferences()
        preferences.listOverrides["ublock-ads"] = false
        let active = preferences.activeLists()
        #expect(active.contains { $0.id == "easylist" })
        #expect(!active.contains { $0.id == "ublock-ads" })
    }

    @Test("Preferences round-trip through the settings store")
    @MainActor func persists() {
        let defaults = UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!
        let settings = Settings(defaults: defaults)
        #expect(settings.contentBlocking == ContentBlockingPreferences())
        var changed = settings.contentBlocking
        changed.blocksTrackers = false
        changed.listOverrides = ["easylist-thailand": true, "ublock-unbreak": false]
        settings.contentBlocking = changed
        #expect(Settings(defaults: defaults).contentBlocking == changed)
    }
}

@Suite("WebKit accepts what the converter produces")
struct WebKitCompilationTests {
    /// The one thing the unit tests above cannot say: that WebKit's regular
    /// expression dialect takes every construct the converter emits. A list
    /// that fails here would fail silently in the app, with nothing blocked.
    @Test("A representative list compiles")
    @MainActor func representativeListCompiles() async throws {
        let output = AdblockRuleConverter().convert("""
            [Adblock Plus 2.0]
            ||ads.example.com^
            ||cdn.example^$script,image,third-party,domain=a.com|b.com
            |http://x.com/*/ad^
            tracker.js|
            /banner.$~image,~font
            ##.advert
            news.example,~sub.news.example##div#sponsored
            @@||good.example.com^$script
            @@||trusted.example^$document
            """)
        #expect(output.skipped == 0)
        let json = try output.encoded()

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "kylmora-rules-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try #require(WKContentRuleListStore(url: directory))

        let compiled: WKContentRuleList? = try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(forIdentifier: "test", encodedContentRuleList: json) { list, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: list) }
            }
        }
        #expect(compiled != nil)
    }
}

@Suite("General settings")
@MainActor
struct GeneralSettingsTests {
    @Test("A homepage can be typed as a bare host")
    func homepageParsing() {
        #expect(Settings.homepageURL(from: "example.com") == URL(string: "https://example.com"))
        #expect(Settings.homepageURL(from: "http://example.com/a") == URL(string: "http://example.com/a"))
        #expect(Settings.homepageURL(from: "") == nil)
        #expect(Settings.homepageURL(from: "not a url at all") == nil)
    }

    @Test("New tabs open with the homepage only when one is set and chosen")
    func newTabTarget() {
        let defaults = UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!
        let settings = Settings(defaults: defaults)
        let start = settings.searchEngine.homeURL
        #expect(settings.newTabURL == start)

        settings.newTabTarget = .homepage
        // Chosen but unset falls back rather than opening nothing.
        #expect(settings.newTabURL == start)

        settings.homepageURL = URL(string: "https://home.example/")
        #expect(settings.newTabURL == URL(string: "https://home.example/"))

        settings.newTabTarget = .startPage
        #expect(settings.newTabURL == start)
        #expect(Settings(defaults: defaults).homepageURL == URL(string: "https://home.example/"))
    }
}

@Suite("JSON formatting")
@MainActor
struct JSONFormattingTests {
    private final class LoadWaiter: NSObject, WKNavigationDelegate {
        var continuation: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            continuation?.resume()
            continuation = nil
        }
    }

    private func load(json: String, formatting: Bool) async throws -> (formatted: Bool, keys: Int) {
        let defaults = UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!
        let settings = Settings(defaults: defaults)
        settings.formatsJSON = formatting
        let formatter = JSONFormatting(settings: settings)

        let configuration = WKWebViewConfiguration()
        formatter.attach(configuration.userContentController)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let waiter = LoadWaiter()
        webView.navigationDelegate = waiter
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiter.continuation = continuation
            webView.load(Data(json.utf8), mimeType: "application/json", characterEncodingName: "utf-8",
                         baseURL: URL(string: "https://api.example/things.json")!)
        }
        var formatted = false
        var keys = 0
        for _ in 0..<20 {
            formatted = try await webView.evaluateJavaScript("document.querySelector('.kylmora-json') !== null") as? Bool ?? false
            if formatted { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        keys = try await webView.evaluateJavaScript("document.querySelectorAll('.kylmora-json .k').length") as? Int ?? 0
        return (formatted, keys)
    }

    @Test("A JSON document is rewritten as an indented, coloured tree")
    func formatsJSONDocuments() async throws {
        let result = try await load(json: #"{"name":"Kylmora","tags":["a","b"],"nested":{"ok":true,"n":3}}"#, formatting: true)
        #expect(result.formatted)
        #expect(result.keys == 5)
    }

    @Test("Switched off, the document is left alone")
    func respectsTheSwitch() async throws {
        let result = try await load(json: #"{"name":"Kylmora"}"#, formatting: false)
        #expect(result.formatted == false)
    }

    @Test("Other user scripts survive the switch being flipped")
    func keepsOtherScripts() {
        let defaults = UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!
        let settings = Settings(defaults: defaults)
        let formatter = JSONFormatting(settings: settings)
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: "window.other = 1;", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        formatter.attach(controller)
        #expect(controller.userScripts.count == 2)
        settings.formatsJSON = false
        formatter.preferencesChanged()
        #expect(controller.userScripts.map(\.source) == ["window.other = 1;"])
        settings.formatsJSON = true
        formatter.preferencesChanged()
        #expect(controller.userScripts.count == 2)
    }

    @Test("The advanced switches persist")
    func advancedSwitchesPersist() {
        let defaults = UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!
        let settings = Settings(defaults: defaults)
        #expect(settings.formatsJSON && settings.allowsChromeExtensions && settings.allowsFirefoxExtensions)
        settings.formatsJSON = false
        settings.allowsFirefoxExtensions = false
        let again = Settings(defaults: defaults)
        #expect(again.formatsJSON == false)
        #expect(again.allowsChromeExtensions)
        #expect(again.allowsFirefoxExtensions == false)
    }
}

@Suite("Privacy pane machinery")
struct PrivacyMachineryTests {
    @Test("Tracking parameters come off and everything else stays")
    func stripsTrackers() {
        let url = URL(string: "https://shop.example/item?id=42&utm_source=mail&fbclid=abc&colour=red")!
        let cleaned = TrackingParameters.cleaned(url)
        #expect(cleaned?.absoluteString == "https://shop.example/item?id=42&colour=red")
        #expect(TrackingParameters.cleaned(URL(string: "https://shop.example/item?id=42")!) == nil)
        #expect(TrackingParameters.cleaned(URL(string: "https://shop.example/?gclid=1")!)?.absoluteString == "https://shop.example/")
    }

    @Test("Tracker removal follows the space it is in")
    func removalScopes() {
        #expect(TrackerRemoval.never.applies(isPrivate: true) == false)
        #expect(TrackerRemoval.privateOnly.applies(isPrivate: true))
        #expect(TrackerRemoval.privateOnly.applies(isPrivate: false) == false)
        #expect(TrackerRemoval.always.applies(isPrivate: false))
    }

    @Test("Cookie deletion is due on the schedule, and never when manual")
    func cookieSchedule() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(CookieDeletion.manually.isDue(lastDeletion: nil, now: now) == false)
        #expect(CookieDeletion.onQuit.isDue(lastDeletion: now, now: now))
        #expect(CookieDeletion.afterDay.isDue(lastDeletion: nil, now: now))
        #expect(CookieDeletion.afterDay.isDue(lastDeletion: now.addingTimeInterval(-3600), now: now) == false)
        #expect(CookieDeletion.afterDay.isDue(lastDeletion: now.addingTimeInterval(-90_000), now: now))
        #expect(CookieDeletion.afterWeek.isDue(lastDeletion: now.addingTimeInterval(-6 * 86_400), now: now) == false)
    }

    @Test("History retention gives a cutoff, and manual gives none")
    func retentionCutoff() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(HistoryRetention.manually.cutoff(now: now) == nil)
        #expect(HistoryRetention.threeMonths.cutoff(now: now) == now.addingTimeInterval(-90 * 86_400))
    }

    @Test("Old visits are pruned and recent ones kept")
    func prunesHistory() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "kylmora-history-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: file) }
        let database = try BrowserDatabase(path: file)
        let now = Date()
        try await database.recordVisit(url: URL(string: "https://old.example/")!, title: "Old", key: "old.example", at: now.addingTimeInterval(-100 * 86_400))
        try await database.recordVisit(url: URL(string: "https://new.example/")!, title: "New", key: "new.example", at: now)
        try await database.deleteHistory(before: HistoryRetention.threeMonths.cutoff(now: now)!)
        let remaining = try await database.recentHistory()
        #expect(remaining.map(\.key) == ["new.example"])
    }

    @Test("The custom user agent reaches a site set to Custom, and an empty one leaves WebKit's")
    @MainActor func customUserAgent() {
        let defaults = UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!
        let settings = Settings(defaults: defaults)
        let file = FileManager.default.temporaryDirectory.appending(path: "kylmora-sites-\(UUID().uuidString).json")
        let sites = SiteSettings(file: file, settings: settings)
        sites.update { $0.set("custom", for: "site.example", in: .userAgent) }
        #expect(sites.userAgent(for: URL(string: "https://site.example/")) == nil)
        settings.customUserAgent = "  KylmoraBot/1.0  "
        #expect(sites.userAgent(for: URL(string: "https://site.example/")) == "KylmoraBot/1.0")
    }

    @Test("The privacy settings persist")
    @MainActor func privacySettingsPersist() {
        let defaults = UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!
        let settings = Settings(defaults: defaults)
        #expect(settings.trackerRemoval == .privateOnly)
        #expect(settings.historyRetention == .manually)
        #expect(settings.cookieDeletion == .manually)
        #expect(settings.crashReportPolicy == .ask)
        #expect(settings.autoUpdatesFilterLists)
        settings.trackerRemoval = .always
        settings.historyRetention = .month
        settings.cookieDeletion = .afterWeek
        settings.historyDisabled = true
        settings.crashReportPolicy = .never
        settings.autoUpdatesFilterLists = false
        let again = Settings(defaults: defaults)
        #expect(again.trackerRemoval == .always)
        #expect(again.historyRetention == .month)
        #expect(again.cookieDeletion == .afterWeek)
        #expect(again.historyDisabled)
        #expect(again.crashReportPolicy == .never)
        #expect(again.autoUpdatesFilterLists == false)
    }
}
