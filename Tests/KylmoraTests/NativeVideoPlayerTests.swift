import Testing
import Foundation
import AppKit
@testable import Kylmora

@Suite("Native HTML5 Video Player (Vinegar-Style) (F-28)")
@MainActor
struct NativeVideoPlayerTests {

    @Test("Native video player setting category is configured with default on and valid options")
    func categoryConfiguration() {
        let category = SiteSettingCategory.nativeVideoPlayer
        #expect(category.title == "Native Video Player")
        #expect(category.symbolName == "play.rectangle.fill")
        #expect(category.builtInDefault == "on")
        #expect(category.options.count == 2)
        #expect(category.option("on")?.title == "Native HTML5 Controls")
        #expect(category.option("off")?.title == "Site Default Player")
    }

    @Test("SiteSettingsState resolves per-domain overrides and defaults")
    func domainOverrides() {
        var state = SiteSettingsState()
        let ytURL = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!
        let vimeoURL = URL(string: "https://vimeo.com/123456")!

        // Built-in default is "on"
        #expect(state.resolve(.nativeVideoPlayer, for: ytURL) == "on")
        #expect(state.resolve(.nativeVideoPlayer, for: vimeoURL) == "on")

        // Turn off for Vimeo
        state.set("off", for: "vimeo.com", in: .nativeVideoPlayer)
        #expect(state.resolve(.nativeVideoPlayer, for: vimeoURL) == "off")
        #expect(state.resolve(.nativeVideoPlayer, for: ytURL) == "on")
    }

    @Test("SiteSettings policy dictionary includes nativeVideoPlayer flag")
    func policyDictionary() {
        let settings = SiteSettings()
        let ytURL = URL(string: "https://youtube.com/watch?v=abc")!
        let policy = settings.policy(for: ytURL)

        #expect(policy["nativeVideoPlayer"] == "on")
        #expect(settings.usesNativeVideoPlayer(for: ytURL) == true)
    }

    @Test("SiteBehaviourScripts includes nativeVideoPlayer with visibility and controls enforcement")
    func scriptContent() {
        let script = SiteBehaviourScripts.nativeVideoPlayer
        #expect(script.contains("nativeVideoPlayer"))
        #expect(script.contains("visibilityState"))
        #expect(script.contains("visibilitychange"))
        #expect(script.contains("controls = true"))
        #expect(script.contains("disablePictureInPicture = false"))
        #expect(script.contains("ytp-skip-ad-button"))

        #expect(SiteBehaviourScripts.documentStart.contains(SiteBehaviourScripts.nativeVideoPlayer))
    }

    @Test("YouTube keeps its own player controls")
    func youTubeKeepsItsControls() {
        // Hiding the player's chrome was how the pause button, the scrubber
        // and fullscreen went missing: the native controls promised in their
        // place never stood in for them.
        let script = SiteBehaviourScripts.nativeVideoPlayer
        #expect(!script.contains("ytp-chrome-bottom"))
        #expect(!script.contains("ytp-chrome-top"))
        #expect(!script.contains("ytp-pause-overlay"))
        #expect(!script.contains("ytp-contextmenu"))
        // The ad overlays are still swept.
        #expect(script.contains("ytp-ad-player-overlay"))
        #expect(script.contains("video-ads"))
    }

    @Test("A blur is only swallowed when it is the window's own")
    func blurIsNotSwallowedForEveryField() {
        // `blur` does not bubble but does capture, so a capturing listener on
        // the window sees every field's blur too. Swallowing those took away
        // the event a search box uses to close its suggestions.
        #expect(SiteBehaviourScripts.nativeVideoPlayer.contains("e.target !== window"))
    }

    @Test("CommandCatalog registers toggle-native-video command")
    func commandPalette() {
        let command = CommandCatalog.all.first { $0.id == "toggle-native-video" }
        #expect(command != nil)
        #expect(command?.title == "Toggle Native HTML5 Video Player")
        #expect(command?.keywords.contains("vinegar") == true)
    }
}
