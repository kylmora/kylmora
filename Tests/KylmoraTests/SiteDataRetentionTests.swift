import Foundation
import Testing
import WebKit
@testable import Kylmora

@Suite("Site Data Retention & Clearing (F-14)")
@MainActor
struct SiteDataRetentionTests {
    private func tempDefaults() -> (UserDefaults, String) {
        let suiteName = "SiteDataRetentionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (defaults, suiteName)
    }

    @Test("Quit allowlist host matching correctly matches exact hosts and subdomains")
    func allowlistHostMatching() {
        let allowlist = ["github.com", "google.com", "my-service.org"]

        // Exact match
        #expect(WebsiteData.isHostAllowed("github.com", in: allowlist))
        #expect(WebsiteData.isHostAllowed("google.com", in: allowlist))

        // Normalisation (www. and uppercase)
        #expect(WebsiteData.isHostAllowed("WWW.GITHUB.COM", in: allowlist))
        #expect(WebsiteData.isHostAllowed("https://google.com/", in: allowlist))

        // Subdomains
        #expect(WebsiteData.isHostAllowed("api.github.com", in: allowlist))
        #expect(WebsiteData.isHostAllowed("mail.google.com", in: allowlist))
        #expect(WebsiteData.isHostAllowed("sub.deep.api.github.com", in: allowlist))

        // Non-matches
        #expect(!WebsiteData.isHostAllowed("notgithub.com", in: allowlist))
        #expect(!WebsiteData.isHostAllowed("tracker.adnetwork.com", in: allowlist))
        #expect(!WebsiteData.isHostAllowed("evilgoogle.com", in: allowlist))
        #expect(!WebsiteData.isHostAllowed("", in: allowlist))
    }

    @Test("WebsiteData record matching correctly compares hosts against WebKit display names")
    func websiteDataRecordMatches() {
        #expect(WebsiteData.matches(host: "github.com", displayName: "github.com"))
        #expect(WebsiteData.matches(host: "gist.github.com", displayName: "github.com"))
        #expect(WebsiteData.matches(host: "github.com", displayName: "gist.github.com"))
        #expect(WebsiteData.matches(host: "www.example.com", displayName: "example.com"))

        #expect(!WebsiteData.matches(host: "github.com", displayName: "gitlab.com"))
        #expect(!WebsiteData.matches(host: "example.org", displayName: "example.com"))
    }

    @Test("Settings manages quit allowlist addition, removal, and toggle")
    func settingsAllowlistManagement() {
        let (defaults, suite) = tempDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = Settings(defaults: defaults)

        #expect(!settings.clearWebsiteDataOnQuit)
        settings.clearWebsiteDataOnQuit = true
        #expect(settings.clearWebsiteDataOnQuit)

        #expect(settings.websiteDataQuitAllowlist.isEmpty)

        settings.addToQuitAllowlist("github.com")
        settings.addToQuitAllowlist("https://www.google.com/")
        #expect(settings.websiteDataQuitAllowlist.contains("github.com"))
        #expect(settings.websiteDataQuitAllowlist.contains("google.com"))
        #expect(settings.isQuitAllowlisted("api.github.com"))
        #expect(settings.isQuitAllowlisted("mail.google.com"))
        #expect(!settings.isQuitAllowlisted("facebook.com"))

        settings.removeFromQuitAllowlist("github.com")
        #expect(!settings.websiteDataQuitAllowlist.contains("github.com"))
        #expect(settings.websiteDataQuitAllowlist.contains("google.com"))
    }

    @Test("Per-site forgetWhenClosed setting persists and resolves")
    func forgetWhenClosedPolicy() {
        var state = SiteSettingsState()
        #expect(state.defaultOption(for: .forgetWhenClosed) == "off")

        let testURL = URL(string: "https://privacy-conscious.example/login")!
        #expect(state.resolve(.forgetWhenClosed, for: testURL) == "off")

        state.set("on", for: "privacy-conscious.example", in: .forgetWhenClosed)
        #expect(state.resolve(.forgetWhenClosed, for: testURL) == "on")

        let subURL = URL(string: "https://sub.privacy-conscious.example/dashboard")!
        #expect(state.resolve(.forgetWhenClosed, for: subURL) == "on")

        let otherURL = URL(string: "https://other-site.example/")!
        #expect(state.resolve(.forgetWhenClosed, for: otherURL) == "off")
    }

    @Test("CommandCatalog includes clear-space-data command under spaces")
    func commandCatalogIncludesClearSpaceData() {
        let command = CommandCatalog.all.first { $0.id == "clear-space-data" }
        #expect(command != nil)
        #expect(command?.title.contains("Space") == true)
        #expect(command?.keywords.contains("clear") == true)
        #expect(command?.keywords.contains("cookies") == true)
    }

    @Test("SiteSettingCategory includes forgetWhenClosed with valid options and defaults")
    func forgetWhenClosedCategorySanity() {
        let category = SiteSettingCategory.forgetWhenClosed
        #expect(!category.title.isEmpty)
        #expect(!category.symbolName.isEmpty)
        #expect(category.builtInDefault == "off")
        #expect(category.options.contains { $0.id == "off" })
        #expect(category.options.contains { $0.id == "on" })
    }
}
