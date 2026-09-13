import Foundation
import Testing
import WebKit
@testable import Kylmora

@Suite("User Rules and Element Picker")
struct ElementPickerAndUserRulesTests {
    @Test("Custom user rules convert properly to WebKit hiding rules")
    func userRulesConvert() {
        let converter = AdblockRuleConverter()
        let rulesText = """
        ! My custom rules
        example.com##.sponsored-banner
        nytimes.com##div#newsletter-popup
        ##.global-annoyance
        ||bad-tracker.example.com^
        @@||whitelisted.example.com^
        """
        let output = converter.convert(rulesText)
        #expect(output.rules.count == 5)

        // Hiding rules
        let hidingRules = output.rules.filter { $0.actionType == "css-display-none" }
        #expect(hidingRules.count == 3)
        #expect(hidingRules.contains { $0.selector == ".sponsored-banner" && $0.ifDomain == ["*example.com"] })
        #expect(hidingRules.contains { $0.selector == "div#newsletter-popup" && $0.ifDomain == ["*nytimes.com"] })
        #expect(hidingRules.contains { $0.selector == ".global-annoyance" && $0.ifDomain == nil })

        // Network rules
        let networkRules = output.rules.filter { $0.actionType == "block" }
        #expect(networkRules.count == 1)

        // Exception rules
        let exceptionRules = output.rules.filter { $0.actionType == "ignore-previous-rules" }
        #expect(exceptionRules.count == 1)
    }

    @Test("User rules text persists in Settings and rounds-trip")
    @MainActor
    func userRulesSettingsPersistence() {
        let defaults = UserDefaults(suiteName: "kylmora.tests.userrules.\(UUID().uuidString)")!
        let settings = Settings(defaults: defaults)

        #expect(settings.userRulesText.isEmpty)
        #expect(settings.autoRejectCookieBanners == true)
        #expect(settings.customFilterLists.isEmpty)

        settings.userRulesText = "example.com##.ad\n||tracker.com^"
        settings.autoRejectCookieBanners = false

        let customList = CustomFilterList(
            name: "Test List",
            url: URL(string: "https://example.com/filters.txt")!,
            isEnabled: true
        )
        settings.customFilterLists = [customList]

        let reloaded = Settings(defaults: defaults)
        #expect(reloaded.userRulesText == "example.com##.ad\n||tracker.com^")
        #expect(reloaded.autoRejectCookieBanners == false)
        #expect(reloaded.customFilterLists.count == 1)
        #expect(reloaded.customFilterLists[0].name == "Test List")
        #expect(reloaded.customFilterLists[0].url == URL(string: "https://example.com/filters.txt")!)
        #expect(reloaded.customFilterLists[0].isEnabled == true)
    }

    @Test("ContentBlocker addUserRule appends rule and formats with newline")
    @MainActor
    func contentBlockerAddUserRule() {
        let defaults = UserDefaults(suiteName: "kylmora.tests.addrule.\(UUID().uuidString)")!
        let settings = Settings(defaults: defaults)
        let blocker = ContentBlocker(settings: settings)

        blocker.addUserRule("example.com##.first-banner")
        #expect(settings.userRulesText.contains("example.com##.first-banner\n"))

        blocker.addUserRule("example.com##.second-banner")
        #expect(settings.userRulesText.contains("example.com##.first-banner\nexample.com##.second-banner\n"))
    }

    @Test("Element picker script produces non-empty isolated injection payload")
    func elementPickerScriptPayload() {
        let script = ElementPickerScript.script
        #expect(!script.isEmpty)
        #expect(script.contains("kylmora-element-picker-root"))
        #expect(script.contains("attachShadow"))
        #expect(script.contains("createRule"))
    }

    @Test("Cookie consent auto-reject script contains major CMP handlers")
    @MainActor
    func cookieConsentScriptCoverage() {
        let script = CookieConsentAutoReject.source
        #expect(!script.isEmpty)
        #expect(script.contains("onetrust"))
        #expect(script.contains("CybotCookiebot"))
        #expect(script.contains("didomi"))
        #expect(script.contains("truste"))
        #expect(script.contains("usercentrics"))
        #expect(script.contains("unfreezeScroll"))
    }

    @Test("Per-site content blocking toggle respects whitelisting")
    @MainActor
    func perSiteContentBlockingToggle() {
        let file = FileManager.default.temporaryDirectory.appending(path: "kylmora-site-rules-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let sites = SiteSettings(file: file)

        let url = URL(string: "https://news.example.com/article")!
        let host = SiteSettings.normalise("news.example.com")

        // Built-in default is "on"
        #expect(sites.blocksContent(for: url) == true)

        // Turn off (whitelist this site)
        sites.update { $0.set("off", for: host, in: .contentBlockers) }
        #expect(sites.blocksContent(for: url) == false)

        // Turn on again
        sites.update { $0.set("on", for: host, in: .contentBlockers) }
        #expect(sites.blocksContent(for: url) == true)
    }

    @Test("ContentBlocker change notifications reach every subscriber")
    @MainActor
    func changeObserversAreMulticast() {
        let defaults = UserDefaults(suiteName: "kylmora.tests.multicast.\(UUID().uuidString)")!
        let settings = Settings(defaults: defaults)
        let blocker = ContentBlocker(settings: settings)

        var first = 0
        var second = 0
        var legacy = 0
        let token1 = blocker.addChangeObserver { first += 1 }
        let token2 = blocker.addChangeObserver { second += 1 }
        blocker.onChange = { legacy += 1 }

        // Every subscriber sees the same events (compiles announce fetching,
        // readiness and the final refresh, so the count is not exactly one).
        blocker.preferencesChanged()
        #expect(first > 0)
        #expect(first == second)
        #expect(second == legacy)

        // Removing one observer leaves the others firing.
        blocker.removeChangeObserver(token1)
        blocker.preferencesChanged()
        let frozen = first
        #expect(second > frozen)
        #expect(second == legacy)
        #expect(first == frozen)

        // Replacing the legacy slot does not disturb added observers.
        blocker.onChange = { legacy += 1000 }
        blocker.preferencesChanged()
        #expect(first == frozen)
        #expect(second > frozen)
        #expect(legacy >= 1000)
        _ = token2
    }
}
