import Foundation
import Testing
@testable import Kylmora

// XCTest ships with Xcode, which this project does not require; swift-testing is
// part of the Swift toolchain, so tests run against Command Line Tools alone.

@Suite("Address bar input resolution")
struct URLResolverTests {
    @Test("Explicit web schemes pass through untouched", arguments: [
        "https://apple.com/mac",
        "http://example.com",
        "about:blank",
        "file:///tmp/index.html"
    ])
    func explicitSchemesPassThrough(input: String) {
        #expect(URLResolver.resolve(input)?.absoluteString == input)
    }

    // The public web is upgraded to https; this machine and the local network,
    // which have no certificate, stay on http so a dev server still loads.
    @Test("Bare hosts get a scheme: https for the web, http for local", arguments: [
        ("apple.com", "https://apple.com"),
        ("developer.apple.com/documentation", "https://developer.apple.com/documentation"),
        ("localhost:8080", "http://localhost:8080"),
        ("127.0.0.1:8950/", "http://127.0.0.1:8950/"),
        ("192.168.1.20", "http://192.168.1.20"),
        ("192.168.1.1", "http://192.168.1.1"),
        ("10.0.0.5:3000/api", "http://10.0.0.5:3000/api"),
        ("172.20.1.1", "http://172.20.1.1"),
        ("169.254.1.1", "http://169.254.1.1"),
        ("kylmora.local", "http://kylmora.local"),
        ("app.localhost:5173", "http://app.localhost:5173"),
        ("172.32.0.1", "https://172.32.0.1"),
        ("8.8.8.8", "https://8.8.8.8"),
        ("example.co.uk/a?b=c", "https://example.co.uk/a?b=c")
    ])
    func bareHostsBecomeHTTPS(input: String, expected: String) {
        #expect(URLResolver.resolve(input)?.absoluteString == expected)
    }

    @Test("The default scheme is http for local hosts and https for the web", arguments: [
        ("localhost", "http"),
        ("app.localhost", "http"),
        ("dev.local", "http"),
        ("127.0.0.1", "http"),
        ("10.1.2.3", "http"),
        ("172.16.0.1", "http"),
        ("172.31.255.255", "http"),
        ("192.168.0.1", "http"),
        ("169.254.0.1", "http"),
        ("172.32.0.1", "https"),
        ("11.0.0.1", "https"),
        ("example.com", "https"),
        ("sub.example.co.uk", "https")
    ])
    func defaultSchemeByHost(host: String, scheme: String) {
        #expect(URLResolver.defaultScheme(for: host) == scheme)
    }

    @Test("Non-URL input becomes a search", arguments: [
        "swift appkit tutorial",
        "swift",
        "3.14",
        "mailto:me@example.com",
        "hello world.com is great"
    ])
    func nonURLInputSearches(input: String) {
        #expect(URLResolver.resolve(input)?.host() == "duckduckgo.com")
    }

    @Test("Whitespace-only input resolves to nothing")
    func emptyInput() {
        #expect(URLResolver.resolve("   ") == nil)
    }

    @Test("Search queries are percent-escaped")
    func searchEscaping() {
        let url = URLResolver.resolve("a & b = c?")
        #expect(url?.query(percentEncoded: true) == "q=a%20%26%20b%20%3D%20c%3F")
    }

    @Test("Search engine template is honoured")
    func customEngine() {
        let engine = SearchEngine(
            id: "test",
            name: "Test",
            queryTemplate: "https://s.example/find?term={query}",
            homeURL: URL(string: "https://s.example")!
        )
        #expect(URLResolver.resolve("swift", using: engine)?.absoluteString
                == "https://s.example/find?term=swift")
    }
}

@Suite("Quick searches and custom engines")
struct SearchEngineTests {
    @Test("A bang at either end searches that engine: !g cats, cats !g")
    func bangs() {
        let wiki = SearchEngine.custom(name: "Wikipedia", address: "https://en.wikipedia.org/w/index.php?search=%s", keyword: "w")!
        let engines = SearchEngine.all + [wiki]

        #expect(URLResolver.resolve("!g cats", using: .duckDuckGo, engines: engines)?.host() == "www.google.com")
        #expect(URLResolver.resolve("cats !g", using: .duckDuckGo, engines: engines)?.host() == "www.google.com")
        let wikiURL = URLResolver.resolve("!w cats and dogs", using: .duckDuckGo, engines: engines)
        #expect(wikiURL?.host() == "en.wikipedia.org")
        #expect(wikiURL?.query()?.contains("search=cats%20and%20dogs") == true)
        #expect(URLResolver.quickSearch("black holes !W", engines: engines)?.query == "black holes")

        // A bang nobody defined is an ordinary search, exclamation mark and all.
        let plain = URLResolver.resolve("!zz cats", using: .duckDuckGo, engines: engines)
        #expect(plain?.host() == "duckduckgo.com")
        #expect(plain?.query()?.contains("zz") == true)
        // A bang alone has nothing to search for.
        #expect(URLResolver.quickSearch("!g", engines: engines) == nil)
        // "!" by itself is not a bang, and neither is "!!g".
        #expect(URLResolver.quickSearch("! cats", engines: engines) == nil)
        #expect(URLResolver.quickSearch("!!g cats", engines: engines) == nil)
    }

    @Test("A keyword and a space search that engine; a keyword alone does not")
    func quickSearch() {
        let wiki = SearchEngine.custom(name: "Wikipedia", address: "https://en.wikipedia.org/w/index.php?search=%s", keyword: "w")!
        let engines = SearchEngine.all + [wiki]
        let url = URLResolver.resolve("w cats and dogs", using: .duckDuckGo, engines: engines)
        #expect(url?.host() == "en.wikipedia.org")
        #expect(url?.query()?.contains("search=cats%20and%20dogs") == true)
        // The built-in keywords work too.
        #expect(URLResolver.resolve("g cats", using: .duckDuckGo, engines: engines)?.host() == "www.google.com")
        // No search words: it is a plain search for the word itself.
        #expect(URLResolver.resolve("w", using: .duckDuckGo, engines: engines)?.host() == "duckduckgo.com")
        // An address is still an address.
        #expect(URLResolver.resolve("example.com", using: .duckDuckGo, engines: engines)?.host() == "example.com")
    }

    @Test("A custom engine needs a name and a %s, and gets a home page from its address")
    func customEngines() {
        let engine = SearchEngine.custom(name: "Wiki", address: "en.wikipedia.org/w/index.php?search=%s", keyword: " W ")
        #expect(engine?.queryTemplate == "https://en.wikipedia.org/w/index.php?search={query}")
        #expect(engine?.homeURL == URL(string: "https://en.wikipedia.org"))
        #expect(engine?.keyword == "w")
        #expect(engine?.isBuiltIn == false)
        #expect(SearchEngine.custom(name: "", address: "https://a.example/?q=%s", keyword: nil) == nil)
        #expect(SearchEngine.custom(name: "No words", address: "https://a.example/", keyword: nil) == nil)
    }

    @Test("Engines, the private choice and the suggestion switches persist")
    @MainActor func settingsPersist() {
        let defaults = UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!
        let settings = Settings(defaults: defaults)
        let wiki = SearchEngine.custom(name: "Wikipedia", address: "https://en.wikipedia.org/w/index.php?search=%s", keyword: "w")!
        settings.customSearchEngines.append(wiki)
        settings.searchEngine = wiki
        #expect(settings.searchEngines.count == 4)
        #expect(settings.searchEngine == wiki)
        // Same engine in private until split.
        #expect(settings.privateSearchEngine == wiki)
        settings.usesSameSearchEngineInPrivate = false
        settings.privateSearchEngine = .duckDuckGo
        #expect(settings.searchEngine(isPrivate: true) == .duckDuckGo)
        #expect(settings.searchEngine(isPrivate: false) == wiki)
        #expect(settings.newTabURL(isPrivate: true) == SearchEngine.duckDuckGo.homeURL)

        var sources = settings.suggestionSources
        sources.bookmarks = false
        settings.suggestionSources = sources
        let again = Settings(defaults: defaults)
        #expect(again.searchEngine == wiki)
        #expect(again.suggestionSources.bookmarks == false)
        #expect(again.suggestionSources.history)

        // Removing the engine in use falls back rather than dangling.
        again.removeCustomSearchEngine(wiki.id)
        #expect(again.searchEngine == .duckDuckGo)
        #expect(again.searchEngines.count == 3)
    }
}

@Suite("Address display")
struct AddressDisplayTests {
    @Test("Punycode labels decode, and only those")
    func punycode() {
        #expect(Punycode.decode("nave-6pa") == "na\u{00ef}ve")
        #expect(Punycode.decode("mnchen-3ya") == "m\u{00fc}nchen")
        #expect(Punycode.decodeHost("xn--nave-6pa.com") == "na\u{00ef}ve.com")
        #expect(Punycode.decodeHost("www.xn--mnchen-3ya.de") == "www.m\u{00fc}nchen.de")
        #expect(Punycode.decodeHost("example.com") == nil)
        #expect(Punycode.decode("not valid ~~") == nil)
    }

    @Test("The address can be the whole thing or the host, with the code or the letters")
    func displayModes() {
        let url = URL(string: "https://xn--nave-6pa.com/path?q=1")!
        #expect(AddressFormatter.display(url) == "xn--nave-6pa.com/path?q=1")
        #expect(AddressFormatter.display(url, full: false, unicodeDomains: false) == "xn--nave-6pa.com")
        #expect(AddressFormatter.display(url, full: true, unicodeDomains: true) == "na\u{00ef}ve.com/path?q=1")
        #expect(AddressFormatter.display(url, full: false, unicodeDomains: true) == "na\u{00ef}ve.com")
    }

    @Test("The Browsing settings persist, and the spelling ones live where WebKit reads them")
    @MainActor func browsingSettingsPersist() {
        let defaults = UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!
        let settings = Settings(defaults: defaults)
        #expect(settings.upgradesToHTTPS && settings.showsFullAddress && !settings.showsUnicodeDomains)
        #expect(settings.effectiveMinimumFontSize == 0)
        settings.minimumFontSizeEnabled = true
        settings.minimumFontSize = 200
        #expect(settings.minimumFontSize == 72)
        #expect(settings.effectiveMinimumFontSize == 72)
        settings.tabFocusesLinks = true
        settings.externalLinkPresentation = .littleArc
        settings.compactModeShowsWindowButtons = false
        let again = Settings(defaults: defaults)
        #expect(again.tabFocusesLinks && again.externalLinkPresentation == .littleArc && !again.compactModeShowsWindowButtons)
        #expect(again.minimumFontSize == 72)
    }

    @Test("Keeping the window buttons in compact mode overrides the hiding rule")
    func windowButtons() {
        #expect(WindowChrome.hidesWindowControls(sidebarCollapsed: true, topBarHovered: false))
        #expect(WindowChrome.hidesWindowControls(sidebarCollapsed: true, topBarHovered: false, keepsButtons: true) == false)
    }
}
