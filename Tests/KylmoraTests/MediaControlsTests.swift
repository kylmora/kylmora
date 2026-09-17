import Testing
import AppKit
@testable import Kylmora

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

@Suite("Media Controls & Picture-in-Picture (F-15)")
@MainActor
struct MediaControlsTests {

    @Test("Tab tracks media playback state and fires notifications")
    func testTabMediaState() {
        let tab = Tab(url: URL(string: "https://example.com/video")!, identity: .standard)
        #expect(!tab.isPlayingMedia)
        #expect(!tab.isPlayingAudio)
        #expect(!tab.hasPlayingVideo)
        #expect(!tab.isMuted)

        let notificationFired = Box(false)
        let token = NotificationCenter.default.addObserver(
            forName: .tabMediaStateDidChange,
            object: tab,
            queue: .main
        ) { _ in
            notificationFired.value = true
        }
        defer { NotificationCenter.default.removeObserver(token) }

        tab.setMediaState(
            isPlaying: true,
            hasAudio: true,
            hasVideo: true,
            isMuted: false,
            title: "Test Song",
            artist: "Test Artist"
        )

        #expect(tab.isPlayingMedia)
        #expect(tab.isPlayingAudio)
        #expect(tab.hasPlayingVideo)
        #expect(tab.mediaTitle == "Test Song")
        #expect(tab.mediaArtist == "Test Artist")
        #expect(notificationFired.value)

        tab.toggleMute()
        #expect(tab.isMuted)

        tab.toggleMute()
        #expect(!tab.isMuted)
    }

    @Test("Tab Picture-in-Picture state updates and notifies")
    func testTabPictureInPicture() {
        let tab = Tab(url: URL(string: "https://example.com/video")!, identity: .standard)
        #expect(!tab.isInPictureInPicture)

        let notified = Box(false)
        let token = NotificationCenter.default.addObserver(
            forName: .tabMediaStateDidChange,
            object: tab,
            queue: .main
        ) { _ in
            notified.value = true
        }
        defer { NotificationCenter.default.removeObserver(token) }

        tab.setPictureInPicture(true)
        #expect(tab.isInPictureInPicture)
        #expect(notified.value)

        tab.requestPictureInPicture(autoTriggered: true)
        #expect(tab.wasAutoPictureInPicture)

        tab.exitPictureInPicture()
        #expect(!tab.wasAutoPictureInPicture)
    }

    @Test("Tab switching auto-triggers PiP when playing video and restores on return")
    func testAutoPictureInPictureTabSwitch() {
        let settings = Settings.shared
        let originalAutoPiP = settings.autoPictureInPicture
        defer { settings.autoPictureInPicture = originalAutoPiP }
        settings.autoPictureInPicture = true

        let session = BrowserSession(database: nil)
        let tab1 = session.newTab()
        let tab2 = session.newTab()

        session.selectTab(tab1)
        tab1.setMediaState(
            isPlaying: true,
            hasAudio: true,
            hasVideo: true,
            isMuted: false,
            title: "Video 1",
            artist: "Channel 1"
        )

        #expect(tab1.hasPlayingVideo)
        #expect(!tab1.isInPictureInPicture)

        // Switching to tab2 should auto-trigger PiP on tab1
        session.selectTab(tab2)
        #expect(tab1.wasAutoPictureInPicture)

        // Simulate WKWebView confirming PiP was entered
        tab1.setPictureInPicture(true)

        // Switching back to tab1 should exit PiP
        session.selectTab(tab1)
        #expect(!tab1.wasAutoPictureInPicture)
    }

    @Test("Disabling auto PiP prevents auto-triggering on tab switch")
    func testAutoPiPDisabled() {
        let settings = Settings.shared
        let originalAutoPiP = settings.autoPictureInPicture
        defer { settings.autoPictureInPicture = originalAutoPiP }
        settings.autoPictureInPicture = false

        let session = BrowserSession(database: nil)
        let tab1 = session.newTab()
        let tab2 = session.newTab()

        session.selectTab(tab1)
        tab1.setMediaState(
            isPlaying: true,
            hasAudio: true,
            hasVideo: true,
            isMuted: false,
            title: "Video 1",
            artist: "Channel 1"
        )

        session.selectTab(tab2)
        #expect(!tab1.wasAutoPictureInPicture)
    }

    @Test("TabRowContent and TabRowView report audio and mute states")
    func testTabRowAudioState() {
        let contentPlaying = TabRowContent(
            title: "Music Stream",
            isPlayingAudio: true,
            isMuted: false
        )
        #expect(contentPlaying.isPlayingAudio)
        #expect(!contentPlaying.isMuted)

        let row = TabRowView()
        row.configure(contentPlaying)
        #expect(row.accessibilityLabel()?.contains("playing audio") == true)

        let contentMuted = TabRowContent(
            title: "Music Stream",
            isPlayingAudio: true,
            isMuted: true
        )
        row.configure(contentMuted)
        #expect(row.accessibilityLabel()?.contains("muted") == true)
    }

    @Test("SidebarNowPlayingView updates state correctly")
    func testSidebarNowPlayingView() {
        let nowPlaying = SidebarNowPlayingView()
        #expect(nowPlaying.isHidden)

        let tab = Tab(url: URL(string: "https://music.apple.com")!, identity: .standard)
        nowPlaying.update(with: tab)
        #expect(nowPlaying.isHidden)

        tab.setMediaState(
            isPlaying: true,
            hasAudio: true,
            hasVideo: false,
            isMuted: false,
            title: "Bohemian Rhapsody",
            artist: "Queen"
        )
        nowPlaying.update(with: tab)
        #expect(!nowPlaying.isHidden)

        let selected = Box<Tab?>(nil)
        nowPlaying.onSelectTab = { t in
            selected.value = t
        }

        // Calling update with nil tab hides it again
        nowPlaying.update(with: nil)
        #expect(nowPlaying.isHidden)
    }

    @Test("A long track title does not shove the sidebar wider")
    func nowPlayingYieldsRatherThanWidenTheSidebar() {
        // The card's width is pinned to the sidebar's, and the split view holds
        // the sidebar at `.defaultLow` -- so anything the card insists on, the
        // sidebar is widened to grant. A YouTube title is long, and the card
        // appears the moment a video starts: the sidebar was shoved wide on
        // opening YouTube and could not be dragged back, because every layout
        // pass asked for the width again.
        func fittingWidth(forTitle title: String, artist: String) -> CGFloat {
            let nowPlaying = SidebarNowPlayingView()
            let tab = Tab(url: URL(string: "https://www.youtube.com/watch?v=x")!, identity: .standard)
            tab.setMediaState(
                isPlaying: true,
                hasAudio: true,
                hasVideo: true,
                isMuted: false,
                title: title,
                artist: artist
            )
            nowPlaying.update(with: tab)
            nowPlaying.layoutSubtreeIfNeeded()
            return nowPlaying.fittingSize.width
        }

        let short = fittingWidth(forTitle: "Hi", artist: "A")
        let long = fittingWidth(
            forTitle: String(repeating: "A very long video title indeed ", count: 8),
            artist: String(repeating: "A rather long channel name ", count: 8)
        )

        #expect(long == short, "the title truncates, it does not ask for room")
        #expect(
            long < Style.Metrics.sidebarWidth,
            "what it asks for is under the sidebar's resting width, so playing something cannot push the divider out"
        )
    }

    @Test("The track title still gets the room between the icon and the controls")
    func nowPlayingTitleIsNotSqueezedToNothing() {
        // The other side of the fix above: the labels yield at a priority below
        // their own hugging, so left to choose their width they would choose
        // none and the title would vanish. The gap is handed to them instead.
        let nowPlaying = SidebarNowPlayingView()
        let tab = Tab(url: URL(string: "https://www.youtube.com/watch?v=x")!, identity: .standard)
        tab.setMediaState(
            isPlaying: true,
            hasAudio: true,
            hasVideo: true,
            isMuted: false,
            title: "A very long video title indeed, the kind YouTube gives you",
            artist: "Some Channel"
        )
        nowPlaying.update(with: tab)
        nowPlaying.frame = NSRect(x: 0, y: 0, width: Style.Metrics.sidebarWidth, height: 44)
        nowPlaying.layoutSubtreeIfNeeded()

        let labels = UITestSupport.textFields(in: nowPlaying)
        #expect(!labels.isEmpty, "the card has labels to measure")
        #expect(
            labels.allSatisfy { $0.frame.width > 0 },
            "the title is truncated to fit, not squeezed out of existence"
        )
    }

    @Test("Command catalog includes Picture in Picture and Mute commands")
    func testCommandCatalogMediaCommands() {
        let pip = CommandCatalog.all.first { $0.id == "pip-video" }
        #expect(pip != nil)
        #expect(pip?.shortcut == "⌥⌘P")

        let mute = CommandCatalog.all.first { $0.id == "toggle-mute-tab" }
        #expect(mute != nil)
    }
}
