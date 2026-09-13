import AppKit
import Foundation
import Testing
import WebKit
@testable import Kylmora

@Suite("A space's look")
@MainActor
struct SpaceLookTests {
    @Test("The defaults leave the window as it was: system appearance, no bars, WebKit's fonts")
    func defaults() {
        let look = SpaceLook()
        #expect(look.appearance == .system)
        #expect(look.customColor == nil)
        #expect(look.allowsWebsiteThemeColor == false)
        #expect(look.alwaysShowsToolbarInFullScreen)
        #expect(look.autoShowsSidebarInFullScreen)
        #expect(look.isOpaqueInFullScreen)
        #expect(look.showsBookmarksBar == false)
        #expect(look.washOpacity == 1, "The wash is at full strength until dialled down")
        #expect(look.fonts == .webKitDefaults)
        #expect(look.fonts.styleSheet == nil, "WebKit's own fonts need no style sheet")
    }

    @Test("Wash transparency scales the tint and survives a relaunch")
    func washTransparency() throws {
        let session = TestSession.make().0
        let space = session.activeSpace
        session.setTheme(.blue, for: space)
        let full = try #require(space.wash?.usingColorSpace(.sRGB))

        var look = space.look
        look.washOpacity = 0.5
        session.setLook(look, for: space)
        let half = try #require(space.wash?.usingColorSpace(.sRGB))
        #expect(abs(half.alphaComponent - full.alphaComponent / 2) < 0.001, "Half the strength, half the alpha")
        #expect(abs(half.redComponent - full.redComponent) < 0.001, "Same hue")

        // Fully transparent still resolves, at zero alpha (a faded-out wash).
        look.washOpacity = 0
        session.setLook(look, for: space)
        #expect((space.wash?.usingColorSpace(.sRGB))?.alphaComponent == 0)
    }

    @Test("The window border draws only while the space is customised")
    func borderFollowsCustomized() {
        let session = TestSession.make().0
        let space = session.activeSpace
        let rim = WindowBorder(style: .solid, thickness: .thin, animation: .still, palette: .glow)

        session.setTheme(.blue, for: space)
        session.setBorder(rim, for: space)
        #expect(space.isCustomized)
        #expect(space.effectiveBorder == rim)

        // A plain preset -- neutral, untinted -- draws no rim, but keeps the value.
        session.setTheme(.neutral, for: space)
        #expect(!space.isCustomized)
        #expect(space.effectiveBorder == .none)
        #expect(space.border == rim, "The border is suppressed, not discarded")

        // Back to a colour, and the rim returns.
        session.setTheme(.blue, for: space)
        #expect(space.effectiveBorder == rim)

        // Website mode defers to the page, so it draws no rim of its own.
        var look = space.look
        look.allowsWebsiteThemeColor = true
        session.setLook(look, for: space)
        #expect(!space.isCustomized)
        #expect(space.effectiveBorder == .none)
    }

    @Test("Wash opacity decodes tolerantly and defaults to the full wash")
    func washOpacityDecoding() throws {
        let empty = try JSONDecoder().decode(SpaceLook.self, from: Data("{}".utf8))
        #expect(empty.washOpacity == 1)
        let wild = try JSONDecoder().decode(SpaceLook.self, from: Data(#"{"washOpacity":5}"#.utf8))
        #expect(wild.washOpacity == 1, "Out of range clamps to the full wash")
        let low = try JSONDecoder().decode(SpaceLook.self, from: Data(#"{"washOpacity":-2}"#.utf8))
        #expect(low.washOpacity == 0, "Below zero clamps to fully faded")
        let set = try JSONDecoder().decode(SpaceLook.self, from: Data(#"{"washOpacity":0.4}"#.utf8))
        #expect(abs(set.washOpacity - 0.4) < 0.0001)
    }

    @Test("A look from another build decodes field by field")
    func toleratesUnknownValues() throws {
        let json = #"{"appearance":"sepia","showsBookmarksBar":true,"bookmarksBarStyle":"huge","fonts":{"standardFamily":"Georgia","standardSize":400},"extra":1}"#
        let look = try JSONDecoder().decode(SpaceLook.self, from: Data(json.utf8))
        #expect(look.appearance == .system, "An unknown appearance falls back")
        #expect(look.showsBookmarksBar)
        #expect(look.bookmarksBarStyle == .iconAndText)
        #expect(look.fonts.standardFamily == "Georgia")
        #expect(look.fonts.standardSize == WebFonts.sizeRange.upperBound, "A wild size is clamped")
        #expect(look.fonts.fixedFamily == WebFonts.webKitDefaults.fixedFamily)

        let empty = try JSONDecoder().decode(SpaceLook.self, from: Data("{}".utf8))
        #expect(empty == SpaceLook())
    }

    @Test("A custom colour is a theme of its own, and the wash follows it")
    func customColour() {
        let session = TestSession.make().0
        let space = session.activeSpace
        let teal = NSColor(srgbRed: 0, green: 0.5, blue: 0.5, alpha: 1)
        session.setCustomColor(teal, for: space)
        #expect(space.theme == .custom)
        #expect(space.color.hexString == teal.hexString)
        let wash = space.wash?.usingColorSpace(.sRGB)
        #expect(wash != nil)
        #expect(wash.map { abs($0.greenComponent - 0.5) < 0.01 } == true)

        // Back to a swatch, the custom colour is remembered for next time.
        session.setTheme(.green, for: space)
        #expect(space.color.hexString == SpaceTheme.green.color.hexString)
        #expect(space.look.customColor?.hexString == teal.hexString)
        #expect(session.nextUnusedTheme() != .custom, "The wheel is never handed out as a default")
    }

    @Test("A page's theme colour takes over the wash only when the space allows it")
    func websiteThemeColour() {
        let session = TestSession.make().0
        let space = session.activeSpace
        let tab = session.newTab(url: URL(string: "https://example.com")!)
        #expect(space.wash(for: tab)?.hexString == space.wash?.hexString, "No page colour: the space's own")

        // The page declares a colour.
        tab.recordThemeColor(NSColor.red)
        #expect(space.wash(for: tab)?.hexString == space.wash?.hexString, "Not allowed: still the space's own")

        var look = space.look
        look.allowsWebsiteThemeColor = true
        session.setLook(look, for: space)
        let taken = space.wash(for: tab)?.usingColorSpace(.sRGB)
        #expect(taken?.redComponent == 1)
        #expect((taken?.alphaComponent ?? 1) < 0.5, "Still a wash, not a paint")
    }

    @Test("Looks survive a relaunch, and fonts reach the space's web configuration")
    func roundTripAndFonts() {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "kylmora-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = SessionStore(fileURL: file)
        let defaults = UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!

        let first = BrowserSession(database: nil, sessionStore: store, settings: Settings(defaults: defaults))
        let work = first.addSpace(named: "Work")
        var look = SpaceLook()
        look.appearance = .light
        look.showsBookmarksBar = true
        look.bookmarksBarStyle = .iconOnly
        look.fonts = WebFonts(standardFamily: "Georgia", standardSize: 18, fixedFamily: "Menlo", fixedSize: 12)
        first.setLook(look, for: work)
        first.saveNow()

        let second = BrowserSession(database: nil, sessionStore: store, settings: Settings(defaults: defaults))
        #expect(second.spaces[1].look == look)
        #expect(second.spaces[0].look == SpaceLook())

        // The environment hands the space's fonts to every configuration
        // made for its identity, as a script at document start.
        let configuration = WebEnvironment.shared.makeConfiguration(for: work.identity)
        let scripts = configuration.userContentController.userScripts.filter { $0.source.contains("kylmora.fonts") }
        #expect(scripts.count == 1)
        #expect(scripts.first?.injectionTime == .atDocumentStart)
        #expect(scripts.first?.source.contains("Georgia") == true)
        #expect(scripts.first?.source.contains("18px") == true)

        // Back to the defaults, and the script goes away rather than
        // injecting Times over the page's own start.
        var reset = look
        reset.fonts = .webKitDefaults
        second.setLook(reset, for: second.spaces[1])
        let plain = WebEnvironment.shared.makeConfiguration(for: work.identity)
        #expect(plain.userContentController.userScripts.allSatisfy { !$0.source.contains("kylmora.fonts") })
    }

    @Test("The font style sheet is a starting point a page can override")
    func styleSheet() throws {
        let fonts = WebFonts(standardFamily: "Palatino \"Linotype\"", standardSize: 17, fixedFamily: "Menlo", fixedSize: 11)
        let sheet = try #require(fonts.styleSheet)
        #expect(sheet.contains(#"html { font-family: "Palatino \"Linotype\""; font-size: 17px; }"#))
        #expect(sheet.contains("pre, code"))
        #expect(sheet.contains("11px"))
        // The installer script embeds the sheet as a JSON string literal.
        let source = WebFontStyling.source(for: sheet)
        #expect(source.hasPrefix("/* kylmora.fonts */"))
        #expect(source.contains("kylmora-fonts"))
    }

    @Test("Installing fonts keeps the other scripts and replaces only its own")
    func installKeepsOthers() {
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: "/* other */", injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        WebFontStyling.install(WebFonts(standardFamily: "Georgia", standardSize: 16, fixedFamily: "Courier", fixedSize: 13), in: controller)
        WebFontStyling.install(WebFonts(standardFamily: "Verdana", standardSize: 16, fixedFamily: "Courier", fixedSize: 13), in: controller)
        let sources = controller.userScripts.map(\.source)
        #expect(sources.count == 2)
        #expect(sources.contains("/* other */"))
        #expect(sources.filter { $0.contains("kylmora.fonts") }.count == 1)
        #expect(sources.contains { $0.contains("Verdana") })
        #expect(!sources.contains { $0.contains("Georgia") })
    }

    @Test("The bookmarks bar shows what fits and puts the rest behind the chevron")
    func bookmarksBarOverflow() {
        let bar = BookmarksBarView(frame: NSRect(x: 0, y: 0, width: 300, height: BookmarksBarView.height))
        let bookmarks = (0..<12).map {
            Bookmark(id: Int64($0), url: URL(string: "https://site\($0).example")!, title: "Bookmark number \($0)", created: .now)
        }
        bar.show(bookmarks, style: .iconAndText, isPrivate: false)
        bar.layoutSubtreeIfNeeded()
        let chips = bar.subviews.filter { $0 is NSControl && !($0 is IconButton) }
        let visible = chips.filter { !$0.isHidden }
        #expect(visible.count > 0)
        #expect(visible.count < bookmarks.count, "Twelve long titles cannot fit in 300 points")
        let chevron = bar.subviews.first { $0 is IconButton }
        #expect(chevron?.isHidden == false)
        for chip in visible { #expect(chip.frame.maxX <= 300) }

        bar.show(Array(bookmarks.prefix(2)), style: .iconOnly, isPrivate: false)
        bar.layoutSubtreeIfNeeded()
        #expect(bar.subviews.first { $0 is IconButton }?.isHidden == true, "Everything fits: no chevron")
    }
}

