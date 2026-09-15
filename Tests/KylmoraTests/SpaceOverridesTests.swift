import AppKit
import Foundation
import Testing
@testable import Kylmora

@Suite("Per-Space overrides")
@MainActor
struct SpaceOverridesTests {
    @Test("A space's engine, user agent, sleep delay and zoom persist and fall back to Settings")
    func persistence() {
        let (session, _) = TestSession.make()
        let space = session.addSpace(named: "Work")
        #expect(session.searchEngine(for: space) == Settings.shared.searchEngine(isPrivate: false))

        session.setSearchEngineID(SearchEngine.bing.id, for: space)
        session.setUserAgent("  KylmoraBot/1.0  ", for: space)
        session.setSleepMinutes(0, for: space)
        session.setDefaultZoom("1.25", for: space)
        #expect(session.searchEngine(for: space) == .bing)
        #expect(space.userAgent == "KylmoraBot/1.0", "trimmed")
        #expect(space.sleepDelay(global: 600) == nil, "0 means never")
        #expect(space.defaultZoom == "1.25")

        let restored = BrowserSession.spaces(from: session.snapshot())?.first { $0.name == "Work" }
        #expect(restored?.searchEngineID == SearchEngine.bing.id)
        #expect(restored?.userAgent == "KylmoraBot/1.0")
        #expect(restored?.sleepMinutes == 0)
        #expect(restored?.defaultZoom == "1.25")

        session.setUserAgent("", for: space)
        #expect(space.userAgent == nil, "empty clears")
        session.setSearchEngineID("nope", for: space)
        #expect(session.searchEngine(for: space) == Settings.shared.searchEngine(isPrivate: false), "an unknown engine falls back")
        session.setSleepMinutes(10, for: space)
        #expect(space.sleepDelay(global: nil) == 600)
        session.setSleepMinutes(nil, for: space)
        #expect(space.sleepDelay(global: 42) == 42)
    }

    @Test("The tab asks its space for a user agent and zoom, and a site's own choice wins")
    func tabOverrides() {
        let (session, _) = TestSession.make()
        let space = session.addSpace(named: "Zoomed")
        session.setDefaultZoom("1.5", for: space)
        session.setUserAgent("SpaceUA", for: space)
        let tab = Tab(url: URL(string: "https://zoom-test.example/")!, identity: space.identity)
        #expect(tab.overrides?.userAgent == "SpaceUA")
        #expect(tab.overrides?.defaultZoom == "1.5")
        let other = Tab(url: URL(string: "https://a.example/")!, identity: .makeIsolated())
        #expect(other.overrides == nil)

        let sites = SiteSettings.shared
        let url = URL(string: "https://zoom-test.example/page")!
        sites.update { $0.sites[.pageZoom]?.removeValue(forKey: "zoom-test.example") }
        #expect(sites.pageZoom(for: url, spaceDefault: "1.5") == 1.5)
        #expect(sites.pageZoom(for: url, spaceDefault: nil) == sites.pageZoom(for: url))
        sites.update { $0.set("0.75", for: "zoom-test.example", in: .pageZoom) }
        #expect(sites.pageZoom(for: url, spaceDefault: "1.5") == 0.75, "the site's own zoom wins")
        sites.update { $0.sites[.pageZoom]?.removeValue(forKey: "zoom-test.example") }
    }
}
