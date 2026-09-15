import AppKit
import Combine
import PDFKit
import WebKit

@MainActor
protocol TabDelegate: AnyObject {
    /// A page asked for a new window (`window.open`, `target="_blank"`).
    /// The returned web view is handed back to WebKit, so it must be created
    /// from the configuration WebKit supplied.
    func tab(_ tab: Tab, requestsNewTabWith configuration: WKWebViewConfiguration) -> Tab

    /// A page finished loading and should be written to history.
    func tab(_ tab: Tab, didVisit url: URL, title: String)

    /// The page recorded by `didVisit` has since reported its real title.
    /// Titles routinely arrive after `didFinish`, and a visit written at that
    /// moment carries the host as its title until this corrects it.
    func tab(_ tab: Tab, didRetitle url: URL, to title: String)

    /// A link was modifier-clicked (Option-Shift or Option-Command) to open in split view.
    func tab(_ tab: Tab, requestsOpenInSplit url: URL)

    /// A page finished loading and its plain-text content was extracted for local full-text search indexing.
    func tab(_ tab: Tab, didExtractContent content: String, for url: URL, title: String)
}

extension TabDelegate {
    func tab(_ tab: Tab, requestsOpenInSplit url: URL) {}
    func tab(_ tab: Tab, didExtractContent content: String, for url: URL, title: String) {}
}

/// One browsable page.
///
/// A tab owns its web view lazily: nothing is allocated until the tab is first
/// shown. `unload()` reverses that, capturing `interactionState` so the tab can
/// be restored later at the same scroll position with its back-forward list
/// intact. Phase 2 uses this for lazy creation and teardown; Phase 5 adds the
/// policy that decides when a background tab should be unloaded.
@MainActor
final class Tab: Identifiable {
    let id = UUID()

    weak var delegate: TabDelegate?

    /// Emitted whenever a displayed property changes, so views can refresh.
    let didChange = PassthroughSubject<Void, Never>()

    private(set) var url: URL
    private(set) var pageTitle: String?

    /// The identity this tab's pages load under: its space's. Fixed, because
    /// WebKit binds a web view to its data store at creation and there is no
    /// way to swap it afterwards.
    let identity: Space.Identity
    /// Nothing this tab does is written to disk.
    var isPrivate: Bool { identity.isPrivate }

    /// A video from this tab is playing in a picture-in-picture window.
    /// Reported by the page; closing the tab would take it away.
    private(set) var isInPictureInPicture = false

    /// Whether any audio or video media is currently playing in this tab.
    private(set) var isPlayingMedia = false
    /// Whether audio is actively playing in this tab.
    private(set) var isPlayingAudio = false
    /// Whether a video element is actively playing in this tab.
    private(set) var hasPlayingVideo = false
    /// Whether audio output from this tab has been muted by the user.
    private(set) var isMuted = false
    /// Media title reported by page or MediaSession.
    private(set) var mediaTitle: String = ""
    /// Media artist/creator reported by page or MediaSession.
    private(set) var mediaArtist: String = ""
    /// Tracks if Picture-in-Picture was automatically activated on tab/space switch,
    /// so switching back automatically restores it to the page.
    var wasAutoPictureInPicture = false

    func setMediaState(isPlaying: Bool, hasAudio: Bool, hasVideo: Bool, isMuted: Bool, title: String, artist: String) {
        let changed = (isPlayingMedia != isPlaying) || (isPlayingAudio != hasAudio) || (hasPlayingVideo != hasVideo) || (self.isMuted != isMuted) || (mediaTitle != title) || (mediaArtist != artist)
        isPlayingMedia = isPlaying
        isPlayingAudio = hasAudio
        hasPlayingVideo = hasVideo
        self.isMuted = isMuted
        mediaTitle = title
        mediaArtist = artist
        if changed {
            NotificationCenter.default.post(name: .tabMediaStateDidChange, object: self)
        }
    }

    func setPictureInPicture(_ active: Bool) {
        let changed = isInPictureInPicture != active
        isInPictureInPicture = active
        if changed {
            NotificationCenter.default.post(name: .tabMediaStateDidChange, object: self)
        }
    }

    func requestPictureInPicture(autoTriggered: Bool = false) {
        if autoTriggered {
            wasAutoPictureInPicture = true
        }
        guard let webView = currentWebView else { return }
        let script = """
        (function() {
          if (window.__kylmoraMedia && window.__kylmoraMedia.requestPiP) {
            return window.__kylmoraMedia.requestPiP();
          }
          var v = document.querySelector('video');
          if (v) {
            if (v.requestPictureInPicture) { v.requestPictureInPicture().catch(function(){}); return true; }
            if (v.webkitSetPresentationMode) { v.webkitSetPresentationMode('picture-in-picture'); return true; }
          }
          return false;
        })();
        """
        webView.evaluateJavaScript(script) { _, _ in }
    }

    func exitPictureInPicture() {
        wasAutoPictureInPicture = false
        guard let webView = currentWebView else { return }
        let script = """
        (function() {
          if (document.pictureInPictureElement && document.exitPictureInPicture) {
            document.exitPictureInPicture().catch(function(){});
          }
          var v = document.querySelector('video');
          if (v && v.webkitSetPresentationMode) {
            v.webkitSetPresentationMode('inline');
          }
        })();
        """
        webView.evaluateJavaScript(script) { _, _ in }
    }

    func toggleMute() {
        setMuted(!isMuted)
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        NotificationCenter.default.post(name: .tabMediaStateDidChange, object: self)
        guard let webView = currentWebView else { return }
        let script = """
        (function() {
          if (window.__kylmoraMedia && window.__kylmoraMedia.setMuted) {
            window.__kylmoraMedia.setMuted(\(muted ? "true" : "false"));
          } else {
            document.querySelectorAll('audio, video').forEach(function(el) { el.muted = \(muted ? "true" : "false"); });
          }
        })();
        """
        webView.evaluateJavaScript(script) { _, _ in }
    }

    func togglePlayPause() {
        guard let webView = currentWebView else { return }
        let script = """
        (function() {
          if (window.__kylmoraMedia && window.__kylmoraMedia.togglePlayPause) {
            window.__kylmoraMedia.togglePlayPause();
          } else {
            var anyPlaying = false;
            document.querySelectorAll('audio, video').forEach(function(el) {
              if (!el.paused && !el.ended) { anyPlaying = true; el.pause(); }
            });
            if (!anyPlaying) {
              var first = document.querySelector('audio, video');
              if (first) { first.play().catch(function(){}); }
            }
          }
        })();
        """
        webView.evaluateJavaScript(script) { _, _ in }
    }

    /// Opens the Web Inspector developer tools for this tab.
    func showWebInspector() {
        guard !EnterprisePolicyManager.shared.isDeveloperToolsDisabled else {
            NSSound.beep()
            return
        }
        let wv = webView()
        if #available(macOS 13.3, *) {
            wv.isInspectable = true
        }
        if wv.responds(to: Selector(("_showInspector:"))) {
            wv.perform(Selector(("_showInspector:")), with: nil)
        } else if let inspector = (wv as AnyObject).value(forKey: "_inspector") as? AnyObject {
            if inspector.responds(to: Selector(("show"))) {
                _ = inspector.perform(Selector(("show")))
            }
        } else {
            NSApp.sendAction(Selector(("showWebInspector:")), to: wv, from: nil)
        }
    }

    /// Opens the JavaScript developer console for this tab.
    func showJavaScriptConsole() {
        guard !EnterprisePolicyManager.shared.isDeveloperToolsDisabled else {
            NSSound.beep()
            return
        }
        let wv = webView()
        if #available(macOS 13.3, *) {
            wv.isInspectable = true
        }
        if let inspector = (wv as AnyObject).value(forKey: "_inspector") as? AnyObject {
            if inspector.responds(to: Selector(("showConsole"))) {
                _ = inspector.perform(Selector(("showConsole")))
                return
            }
        }
        showWebInspector()
    }

    /// Renders an enterprise-blocked interstitial when a URL is restricted by corporate policy.
    func showBlockedByPolicy(url: URL) {
        let wv = webView()
        let org = EnterprisePolicyManager.shared.organizationName
        let escapedURL = url.absoluteString
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Blocked by Organization Policy</title>
        <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            background-color: #1c1c1e;
            color: #f2f2f7;
            display: flex;
            align-items: center;
            justify-content: center;
            height: 100vh;
            margin: 0;
            padding: 20px;
            box-sizing: border-box;
        }
        @media (prefers-color-scheme: light) {
            body { background-color: #f2f2f7; color: #1c1c1e; }
            .card { background-color: #ffffff !important; border-color: #d1d1d6 !important; box-shadow: 0 4px 20px rgba(0,0,0,0.08) !important; }
            .url-box { background-color: #e5e5ea !important; color: #d70015 !important; }
        }
        .card {
            background-color: #2c2c2e;
            border: 1px solid #3a3a3c;
            border-radius: 16px;
            padding: 40px;
            max-width: 500px;
            text-align: center;
            box-shadow: 0 8px 32px rgba(0,0,0,0.4);
        }
        .icon { font-size: 48px; margin-bottom: 16px; }
        h1 { font-size: 20px; margin: 0 0 12px; font-weight: 600; }
        p { font-size: 14px; color: #8e8e93; line-height: 1.5; margin: 0 0 20px; }
        .url-box {
            font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
            font-size: 12px;
            background-color: #1c1c1e;
            padding: 8px 14px;
            border-radius: 8px;
            color: #ff453a;
            word-break: break-all;
            margin-bottom: 24px;
            display: inline-block;
        }
        .footer { font-size: 12px; color: #636366; margin: 0; }
        </style>
        </head>
        <body>
        <div class="card">
        <div class="icon">🛡️</div>
        <h1>Website Blocked by Policy</h1>
        <p>Your organization (\(org)) has restricted access to this website in accordance with corporate security and acceptable use policies.</p>
        <div class="url-box">\(escapedURL)</div>
        <p class="footer">If you need access to this resource for business purposes, please contact your IT administrator.</p>
        </div>
        </body>
        </html>
        """
        wv.loadHTMLString(html, baseURL: url)
        self.url = url
        self.pageTitle = "Blocked by Policy"
    }

    /// Captures a screenshot of this tab.
    func captureScreenshot(scope: ScreenshotScope) async throws -> NSImage {
        let wv = webView()
        return try await ScreenshotService.capture(webView: wv, scope: scope)
    }
    private(set) var isLoading = false
    private(set) var estimatedProgress: Double = 0

    /// Which group in its space this tab belongs to, if any.
    private(set) var groupID: TabGroup.ID?

    /// The pinned shortcut this tab is showing, if it was opened from one.
    ///
    /// Matching on the URL instead does not survive the first navigation: open
    /// a pin for `slack.com` and the site sends you to `slack.com/intl/en-in/`,
    /// after which the pin no longer recognises its own tab and opens another.
    private(set) var pinnedSiteID: UUID?

    /// When this tab was last on screen. Drives suspension and archiving.
    private(set) var lastActiveAt: Date = .now

    /// Never suspend this tab, however long it sits. The user's own override of
    /// the idle policy, for the tab holding a half-written message or a page
    /// that loses its state on reload.
    ///
    /// Because archiving only ever takes already-suspended tabs, a tab kept
    /// awake is also never archived: one switch, both promises.
    private var explicitlyKeepsAwake = false
    var keepsAwake: Bool {
        explicitlyKeepsAwake || !SiteSettings.shared.allowsSuspension(for: url)
    }

    /// Never archive this tab. It may still suspend -- giving its memory back
    /// costs the user nothing -- but it does not leave the sidebar.
    private var explicitlyKeepsInSidebar = false
    var keepsInSidebar: Bool {
        explicitlyKeepsInSidebar || isLocked || !SiteSettings.shared.allowsSuspension(for: url)
    }

    /// Refuses to close. The user's answer to the mistyped Cmd-W, the stray
    /// click on the cross, and "Close Other Tabs" reaching one tab too far.
    ///
    /// Deliberately stronger than the other two switches, which only overrule
    /// policy the browser applies on its own. This one stands against the
    /// user's own hand, so every path that closes a tab has to go through
    /// `BrowserSession.closeTab` and be told no.
    ///
    /// It implies `keepsInSidebar`: a tab that may not be closed is not
    /// quietly filed into the archive either. Not the reverse -- keeping a tab
    /// out of the archive says nothing about whether you meant to close it.
    private(set) var isLocked = false

    /// Set when the current navigation failed, cleared when a new one starts.
    private(set) var failure: NavigationFailure?

    /// The colour the user tagged this tab with, if any.
    private(set) var colorTag: TabColorTag?

    /// The last page whose text went to the full-text index, and when.
    private var lastIndexedURL: URL?
    private var lastIndexedAt: Date = .distantPast

    /// A note the user attached to this tab, shown in its tooltip.
    private(set) var note: String?

    /// An emoji standing in for the favicon, when the user set one.
    private(set) var emoji: String?

    func setEmoji(_ text: String?) {
        let value = Self.firstEmoji(in: text)
        guard value != emoji else { return }
        emoji = value
        didChange.send()
    }

    /// The first character of what was typed, if it is an emoji.
    static func firstEmoji(in text: String?) -> String? {
        guard let first = text?.trimmingCharacters(in: .whitespacesAndNewlines).first else { return nil }
        let scalars = first.unicodeScalars
        guard scalars.contains(where: { $0.properties.isEmojiPresentation || $0.properties.isEmojiModifierBase })
              || (scalars.first?.properties.isEmoji == true && scalars.contains { $0.value == 0xFE0F || $0.value > 0x2000 }) else { return nil }
        return String(first)
    }

    func setNote(_ text: String?) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty ?? true) ? nil : trimmed
        guard value != note else { return }
        note = value
        didChange.send()
    }

    /// Seconds between automatic reloads, or nil when the page reloads only
    /// when asked. Kept across a relaunch, since a dashboard left refreshing
    /// is meant to stay that way.
    private(set) var autoReloadInterval: TimeInterval?
    private var autoReloadTimer: Timer?

    static let autoReloadChoices: [TimeInterval] = [10, 30, 60, 300, 900]

    func setAutoReload(every interval: TimeInterval?) {
        guard interval != autoReloadInterval else { return }
        autoReloadInterval = interval
        scheduleAutoReload()
        didChange.send()
    }

    private func scheduleAutoReload() {
        autoReloadTimer?.invalidate()
        autoReloadTimer = nil
        guard let interval = autoReloadInterval, interval > 0 else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.loadedWebView != nil, !self.isLoading else { return }
                self.reload()
            }
        }
        timer.tolerance = interval / 10
        autoReloadTimer = timer
    }

    /// What a space sets for every page in it, looked up by identity.
    struct SpaceOverrides {
        var userAgent: String?
        var defaultZoom: String?
    }

    /// Set by the session, which knows which space an identity belongs to.
    static var spaceOverrides: ((Space.Identity) -> SpaceOverrides?)?

    var overrides: SpaceOverrides? { Self.spaceOverrides?(identity) }

    /// When the page last changed its title, so a tab that changed while it
    /// was out of sight can say so. Compared with `lastActiveAt`: a change
    /// after the tab was last looked at is unread.
    private(set) var titleChangedAt: Date?

    var hasUnreadChange: Bool {
        guard let titleChangedAt else { return false }
        return titleChangedAt > lastActiveAt
    }

    func setColorTag(_ tag: TabColorTag?) {
        guard tag != colorTag else { return }
        colorTag = tag
        didChange.send()
    }

    /// Records a title change the page made. Public so the sidebar's unread
    /// dot can be exercised without a web view.
    func noteTitleChanged(_ title: String?) {
        guard let title, !title.isEmpty, title != pageTitle else { return }
        titleChangedAt = .now
    }

    /// A PDF the tab is showing in its own viewer instead of a web page.
    ///
    /// The document is fetched as a WebKit download of the navigation's
    /// response, so it carries the tab's cookies, and shown in `documentView`
    /// over the web view. While it is set, the tab's address and title are
    /// the document's, whatever the web view underneath reports.
    private(set) var document: TabDocument?
    private(set) var documentView: PDFDocumentView?
    private var inlineDownload: InlinePDFDownload?

    /// The tab is on Kylmora's own new-tab page, which is drawn in the
    /// window rather than loaded; the web view underneath stays blank.
    private(set) var showsStartPage = false
    private(set) var startPageView: StartPageView?
    /// The web view's blank first document stands in for the start page, so
    /// going back to it brings the start page back rather than a white page.
    private var blankIsStartPage = false

    /// Whatever is drawn over the web view for this tab: a document it is
    /// showing, or the start page. Nil for an ordinary web page.
    var contentOverlay: NSView? {
        if let documentView { return documentView }
        if showsStartPage {
            if let startPageView { return startPageView }
            let view = StartPageView()
            startPageView = view
            return view
        }
        return nil
    }

    /// The address the user asked for, held until that navigation commits.
    ///
    /// Only ever set from `load(_:)`, which is reached from the omnibox, a
    /// restored session or a new tab. A page can never set it, which is what
    /// makes it safe to display before commit.
    private var pendingUserURL: URL?

    /// The address that failed, so retrying goes to the right place. `url`
    /// reverts to the previous page before the failure is delivered.
    private var failedURL: URL?

    private var loadedWebView: WKWebView?
    /// Whether this tab's page is currently barred from playing media. A tab
    /// that is not on screen is suspended so a video or audio in it pauses the
    /// instant it leaves the front and does not play on behind whatever
    /// replaced it -- and so two YouTube tabs cannot play at once. Held here so
    /// the state survives the web view being unloaded and is reapplied when a
    /// new one attaches.
    private var mediaSuspended = false
    /// The colour the page declares for the chrome around it, if any.
    private(set) var themeColor: NSColor?

    /// Pauses or resumes all audio and video in the page. Suspending pauses
    /// what is playing and holds it paused -- the page cannot restart it -- until
    /// this is called again with `false`, at which point playback resumes where
    /// it left off. A tab with no live web view records the wish and applies it
    /// when one attaches.
    func setMediaSuspended(_ suspended: Bool) {
        guard mediaSuspended != suspended else { return }
        mediaSuspended = suspended
        loadedWebView?.setAllMediaPlaybackSuspended(suspended)
    }

    /// Whether media in this tab is currently barred from playing. Read-only;
    /// the state is driven by `BrowserSession.updateMediaSuspension`.
    var isMediaSuspended: Bool { mediaSuspended }

    /// Records the page's colour and announces it like a title change, so
    /// the chrome can follow it when the space allows.
    func recordThemeColor(_ colour: NSColor?) {
        guard colour != themeColor else { return }
        themeColor = colour
        didChange.send()
    }

    /// Restyles the live page with a space's default fonts. Pages that are
    /// not loaded pick them up from their configuration when they are.
    func applyFonts(_ fonts: WebFonts) {
        guard let loadedWebView else { return }
        WebFontStyling.apply(fonts, to: loadedWebView)
    }
    private var savedInteractionState: Any?
    /// The web view is replaying `savedInteractionState`. That load is not a
    /// visit: the user went there before, and it was written then. Cleared
    /// by the first commit, which hands over to `suppressesNextVisit`.
    private var isRestoringDocument = false
    /// The restore has committed; its `didFinish` is not to be recorded.
    private var suppressesNextVisit = false
    /// The address of the last visit written, so a late title can update it.
    private var reportedVisitURL: URL?
    private var cancellables: Set<AnyCancellable> = []
    private var navigationHandler: TabNavigationHandler?

    var isLoaded: Bool { loadedWebView != nil }

    /// The live web view, if there already is one, for read-only queries such
    /// as favicon discovery. Deliberately does not create one: a tab that has
    /// never been shown must not cost a content process just to draw its icon.
    var currentWebView: WKWebView? { loadedWebView }

    /// Was loaded, has been released, and can be brought back exactly.
    ///
    /// Narrower than `isAsleep`: this is specifically the tab that has a saved
    /// scroll position and back-forward list waiting for it.
    var isSuspended: Bool { loadedWebView == nil && savedInteractionState != nil }

    /// No web view, so no memory, so nothing on screen to lose.
    ///
    /// Two tabs reach this from opposite directions -- one was loaded and gave
    /// its page back, the other was restored or opened in the background and
    /// has never had a page at all -- and the difference between them is not
    /// one the sidebar should ask anyone to care about. Both are costing
    /// nothing and neither is open. This is what "sleeping" means to a user,
    /// and so it is what the moon, the dimming and the idle badge key off.
    var isAsleep: Bool { loadedWebView == nil }

    /// Set by `BrowserSession` when a pinned shortcut opens this tab.
    func setPinnedSiteID(_ id: UUID?) {
        guard id != pinnedSiteID else { return }
        pinnedSiteID = id
        didChange.send()
    }

    /// Set by `BrowserSession`, which is the only thing allowed to file a tab.
    func setGroupID(_ id: TabGroup.ID?) {
        guard id != groupID else { return }
        groupID = id
        didChange.send()
    }

    /// Called when the tab becomes the visible one.
    func markActive() {
        lastActiveAt = .now
    }

    /// How long this tab has been out of sight. Zero while it is the visible
    /// one, because `markActive` keeps stamping it.
    func idleDuration(now: Date = .now) -> TimeInterval {
        max(0, now.timeIntervalSince(lastActiveAt))
    }

    /// Winds the idle clock back, for tests.
    ///
    /// Archiving is measured in days. The alternative to this one line is
    /// either a test that takes three days or an archiving policy that is only
    /// ever exercised with the thresholds turned down to something no user
    /// would set, and neither tells us the shipped behaviour is right.
    func backdateLastActive(by seconds: TimeInterval) {
        lastActiveAt = lastActiveAt.addingTimeInterval(-seconds)
    }

    /// Set from the sidebar's menu. Waking a tab that is already asleep is left
    /// to the caller: the flag says what happens from now on, and reloading a
    /// page the user cannot see is not what they asked for.
    func setKeepsAwake(_ keeps: Bool) {
        guard keeps != explicitlyKeepsAwake else { return }
        explicitlyKeepsAwake = keeps
        didChange.send()
    }

    /// Set from the sidebar's menu.
    func setKeepsInSidebar(_ keeps: Bool) {
        guard keeps != explicitlyKeepsInSidebar else { return }
        explicitlyKeepsInSidebar = keeps
        didChange.send()
    }

    /// Set from the sidebar's menu, the row's context menu and the close
    /// refusal's own Unlock button.
    func setLocked(_ locked: Bool) {
        guard locked != isLocked else { return }
        isLocked = locked
        didChange.send()
    }

    var canGoBack: Bool { loadedWebView?.canGoBack ?? false }
    var canGoForward: Bool { loadedWebView?.canGoForward ?? false }

    /// The address to show in the omnibox.
    ///
    /// Not `WKWebView.url`, which moves to the target of a navigation the moment
    /// it is started and before the old document is replaced. Measured on
    /// macOS 26: during a stalled load, `url` named the new host for as long as
    /// the load hung while `document.title` still belonged to the old page.
    /// Showing that is the classic URL-spoofing window.
    ///
    /// `backForwardList.currentItem` is the right source because it moves only
    /// on commit, yet still follows `history.pushState` and fragment changes,
    /// which produce no navigation callbacks at all. Both behaviours were
    /// verified rather than assumed.
    var displayURL: URL {
        if let document { return document.url }
        if showsStartPage { return StartPage.url }
        return pendingUserURL ?? loadedWebView?.backForwardList.currentItem?.url ?? url
    }

    /// What the sidebar shows: the name the user gave this tab, then the page
    /// title, then the host. The ladder itself is in `TabNaming` so it can be
    /// tested without a tab.
    var displayTitle: String {
        // A failed load shows an error page for the address that failed, so
        // the previous page's title would name something no longer on screen.
        if failure != nil, let failedURL {
            return TabNaming.displayTitle(customName: customName, pageTitle: nil, url: failedURL)
        }
        if let document {
            return TabNaming.displayTitle(customName: customName, pageTitle: document.title, url: document.url)
        }
        if showsStartPage {
            return TabNaming.displayTitle(customName: customName, pageTitle: StartPage.title, url: StartPage.url)
        }
        return TabNaming.displayTitle(customName: customName, pageTitle: pageTitle, url: url)
    }

    /// The user-given name, if there is one. Held in `TabNameStore` rather than
    /// here: what the user chose and what the page reports are different kinds
    /// of fact, and a page must never be able to overwrite the first.
    var customName: String? { TabNameStore.shared.name(for: id) }

    init(url: URL, identity: Space.Identity) {
        showsStartPage = StartPage.isStartPage(url)
        blankIsStartPage = showsStartPage
        self.url = url
        self.identity = identity
    }

    /// Rebuilds a tab from a saved session. The web view is still not created
    /// until the tab is shown, so restoring twenty tabs costs twenty small
    /// objects rather than twenty content processes.
    init(restoring snapshot: SessionSnapshot.Tab, identity: Space.Identity) {
        showsStartPage = StartPage.isStartPage(snapshot.url)
        blankIsStartPage = showsStartPage
        self.url = snapshot.url
        self.pageTitle = snapshot.title
        self.identity = identity
        self.groupID = snapshot.groupID
        self.pinnedSiteID = snapshot.pinnedSiteID
        self.savedInteractionState = snapshot.interactionState
        // A session written before the clock was persisted restores as "just
        // now", which is the safe direction to be wrong in: a tab is never
        // archived for idleness it accrued while nobody was measuring.
        self.lastActiveAt = snapshot.lastActiveAt ?? .now
        self.explicitlyKeepsAwake = snapshot.keepsAwake ?? false
        self.explicitlyKeepsInSidebar = snapshot.keepsInSidebar ?? false
        self.isLocked = snapshot.isLocked ?? false
        self.colorTag = snapshot.colorTag.flatMap(TabColorTag.init(rawValue:))
        self.note = snapshot.note
        self.emoji = snapshot.emoji
        self.autoReloadInterval = snapshot.autoReloadSeconds.map { TimeInterval($0) }
        TabNameStore.shared.restore(snapshot.customName, for: id)
        scheduleAutoReload()
    }

    /// The state needed to bring this tab back after a relaunch.
    func snapshot() -> SessionSnapshot.Tab {
        SessionSnapshot.Tab(
            url: document?.url ?? url,
            title: document?.title ?? pageTitle,
            groupID: groupID,
            customName: TabNameStore.shared.name(for: id),
            pinnedSiteID: pinnedSiteID,
            // A PDF was never a WebKit navigation, so the web view's saved
            // state belongs to the page underneath; restoring the address
            // fetches the document again.
            interactionState: document != nil ? nil : (loadedWebView?.interactionState as? Data ?? savedInteractionState as? Data),
            lastActiveAt: lastActiveAt,
            // Written only when set, so a session file does not grow a pair of
            // `false`s on every tab the user never touched.
            keepsAwake: explicitlyKeepsAwake ? true : nil,
            keepsInSidebar: explicitlyKeepsInSidebar ? true : nil,
            isLocked: isLocked ? true : nil,
            colorTag: colorTag?.rawValue,
            note: note,
            autoReloadSeconds: autoReloadInterval.map { Int($0) },
            emoji: emoji
        )
    }

    /// Adopts a web view WebKit asked us to create for `window.open`.
    init(adopting webView: WKWebView, identity: Space.Identity) {
        self.url = webView.url ?? URL(string: "about:blank")!
        self.identity = identity
        attach(webView)
    }

    // MARK: - Web view lifecycle

    /// The live web view, created on first use.
    func webView() -> WKWebView {
        if let loadedWebView { return loadedWebView }

        let webView = WebEnvironment.shared.makeWebView(identity: identity)
        attach(webView)

        if showsStartPage {
            // The start page is drawn over the web view; WebKit gets a blank
            // document so there is a page to navigate away from.
            webView.load(URLRequest(url: URL(string: "about:blank")!))
        } else if let savedInteractionState {
            isRestoringDocument = true
            webView.interactionState = savedInteractionState
        } else {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    /// Releases the web view and the WebKit content process backing it, keeping
    /// enough state to restore the page exactly where the user left it.
    func unload() {
        guard let webView = loadedWebView else { return }
        failure = nil
        savedInteractionState = webView.interactionState
        pendingUserURL = nil
        failedURL = nil
        cancellables.removeAll()
        navigationHandler = nil
        webView.uiDelegate = nil
        webView.navigationDelegate = nil
        webView.stopLoading()
        webView.removeFromSuperview()
        loadedWebView = nil
        isLoading = false
        estimatedProgress = 0
        didChange.send()
    }

    private func attach(_ webView: WKWebView) {
        loadedWebView = webView
        let handler = TabNavigationHandler(tab: self)
        navigationHandler = handler
        webView.uiDelegate = handler
        webView.navigationDelegate = handler
        // A tab restored while still in the background must stay muted; only
        // becoming visible clears the suspension.
        if mediaSuspended { webView.setAllMediaPlaybackSuspended(true) }
        observe(webView)
    }

    private func observe(_ webView: WKWebView) {
        webView.publisher(for: \.url, options: [.initial, .new])
            .sink { [weak self] url in
                guard let self, let url, self.document == nil, !self.showsStartPage else { return }
                if self.blankIsStartPage, url.absoluteString == "about:blank" {
                    self.showsStartPage = true
                    self.url = StartPage.url
                    self.pageTitle = nil
                    self.didChange.send()
                    return
                }
                self.url = url
                self.didChange.send()
            }
            .store(in: &cancellables)

        webView.publisher(for: \.title, options: [.initial, .new])
            .sink { [weak self] title in
                guard let self, self.document == nil, !self.showsStartPage else { return }
                self.noteTitleChanged(title)
                self.pageTitle = title
                self.didChange.send()
                if let title, !title.isEmpty, self.reportedVisitURL == self.url {
                    self.delegate?.tab(self, didRetitle: self.url, to: title)
                }
            }
            .store(in: &cancellables)

        // A page's `<meta name="theme-color">`, which a space may let take
        // over the chrome's wash. Announced like a title so the chrome follows.
        webView.publisher(for: \.themeColor, options: [.initial, .new])
            .sink { [weak self] colour in self?.recordThemeColor(colour) }
            .store(in: &cancellables)

        webView.publisher(for: \.isLoading, options: [.initial, .new])
            .sink { [weak self] isLoading in
                guard let self, self.document == nil else { return }
                self.isLoading = isLoading
                self.didChange.send()
            }
            .store(in: &cancellables)

        webView.publisher(for: \.estimatedProgress, options: [.initial, .new])
            .sink { [weak self] progress in
                self?.estimatedProgress = progress
                self?.didChange.send()
            }
            .store(in: &cancellables)

        // The chrome enables its buttons from these, so a change must repaint.
        webView.publisher(for: \.canGoBack, options: [.new])
            .merge(with: webView.publisher(for: \.canGoForward, options: [.new]))
            .sink { [weak self] _ in self?.didChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - Navigation

    func load(_ url: URL) {
        clearDocument()
        if StartPage.isStartPage(url) {
            showsStartPage = true
            blankIsStartPage = true
            self.url = url
            pendingUserURL = nil
            failure = nil
            failedURL = nil
            isLoading = false
            didChange.send()
            return
        }
        if showsStartPage {
            showsStartPage = false
            startPageView = nil
        }
        self.url = url
        pendingUserURL = url
        failedURL = nil
        // A load the user asked for is a visit even while a restore is still
        // in flight.
        isRestoringDocument = false
        suppressesNextVisit = false
        if let loadedWebView {
            loadedWebView.load(URLRequest(url: url))
        } else {
            // Not shown yet: drop any stale restore state so the new URL wins.
            savedInteractionState = nil
        }
        didChange.send()
    }

    /// Sets the page zoom, live on the current web view and remembered for the
    /// site (as one of `SiteSettings`' zoom steps), so a reload or a return to
    /// the page keeps it. `optionID` is a zoom step such as "1" or "1.25".
    func setPageZoom(_ optionID: String) {
        loadedWebView?.pageZoom = CGFloat(Double(optionID) ?? 1)
        guard let host = url.host, !host.isEmpty else { return }
        SiteSettings.shared.update { $0.set(optionID, for: host, in: .pageZoom) }
    }

    func reload() {
        if showsStartPage { return }
        // A document is fetched again from its address; the web view
        // underneath has nothing to do with it.
        if let document {
            let target = document.url
            clearDocument()
            load(target)
            return
        }
        // A failed load leaves nothing to reload, so retry the address itself.
        if failure != nil, let loadedWebView {
            let target = failedURL ?? url
            failure = nil
            pendingUserURL = target
            didChange.send()
            loadedWebView.load(URLRequest(url: target))
            return
        }
        loadedWebView?.reload()
    }
    /// Back from a document returns to the page under it, which is what
    /// WebKit still shows: the document was never in its history.
    func goBack() {
        if showsStartPage { return }
        if document != nil {
            clearDocument()
            if let webURL = loadedWebView?.url { url = webURL }
            pageTitle = loadedWebView?.title
            didChange.send()
            return
        }
        loadedWebView?.goBack()
    }
    func goForward() { loadedWebView?.goForward() }
    func stopLoading() { loadedWebView?.stopLoading() }

    fileprivate func makeChildTab(with configuration: WKWebViewConfiguration) -> Tab? {
        delegate?.tab(self, requestsNewTabWith: configuration)
    }

    fileprivate func navigationStarted() {
        // A navigation that begins after the restore committed is the user's
        // own, whatever started it; only the restore itself is silent.
        if !isRestoringDocument { suppressesNextVisit = false }
        // A new page replaces whatever document was showing.
        let hadDocument = document != nil
        clearDocument()
        guard failure != nil || hadDocument else { return }
        failure = nil
        didChange.send()
    }

    // MARK: - Documents

    /// Starts showing the PDF at `url`, whose bytes arrive through
    /// `adoptInlineDownload`.
    func beginDocument(at url: URL) {
        inlineDownload = nil
        document = TabDocument(url: url, title: TabDocument.title(for: url), state: .loading)
        self.url = url
        pendingUserURL = nil
        failure = nil
        failedURL = nil
        isLoading = true
        let view = documentView ?? PDFDocumentView()
        documentView = view
        view.showLoading(url: url)
        didChange.send()
    }

    /// Takes a download with a delegate the caller made.
    func adoptInlineDownload(_ download: WKDownload, using fetch: InlinePDFDownload) {
        inlineDownload = fetch
        download.delegate = fetch
    }

    /// Takes the WebKit download that carries the document's bytes.
    func adoptInlineDownload(_ download: WKDownload, for url: URL) {
        let fetch = InlinePDFDownload(
            url: url,
            onFinish: { [weak self] file in self?.documentArrived(at: file, from: url) },
            onFail: { [weak self] error in self?.documentFailed(error, from: url) }
        )
        inlineDownload = fetch
        download.delegate = fetch
    }

    /// The document's bytes are on disk; show them, or say why not.
    func documentArrived(at file: URL, from url: URL) {
        guard document?.url == url else { return }
        guard let pdf = PDFDocument(url: file) else {
            documentFailed(TabDocument.Failure.unreadable, from: url)
            return
        }
        document?.state = .ready(fileURL: file, pageCount: pdf.pageCount)
        isLoading = false
        documentView?.show(pdf, fileURL: file)
        didChange.send()
        // A document is a visit like any page.
        reportedVisitURL = url
        delegate?.tab(self, didVisit: url, title: displayTitle)
    }

    func documentFailed(_ error: any Error, from url: URL) {
        guard document?.url == url else { return }
        document?.state = .failed(error.localizedDescription)
        isLoading = false
        documentView?.showFailure("Could not open the PDF: \(error.localizedDescription)")
        didChange.send()
    }

    /// Drops the document and its temporary file; the web view underneath
    /// becomes the tab's content again.
    func clearDocument() {
        guard let document else { return }
        if case .ready(let file, _) = document.state {
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
        self.document = nil
        inlineDownload = nil
        documentView?.removeFromSuperview()
        documentView = nil
        isLoading = loadedWebView?.isLoading ?? false
    }

    fileprivate func navigationCommitted() {
        if isRestoringDocument {
            isRestoringDocument = false
            suppressesNextVisit = true
        }
        pendingUserURL = nil
        didChange.send()
    }

    fileprivate func navigationFailed(_ error: any Error) {
        // `url` has already reverted to the previous page by the time a
        // provisional failure arrives, so the address that actually failed has
        // to come from the error itself.
        let attempted = (error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL
            ?? pendingUserURL
            ?? url
        guard let failure = NavigationFailure(error, url: attempted) else { return }

        self.failure = failure
        self.failedURL = attempted
        pendingUserURL = attempted
        isLoading = false
        isRestoringDocument = false
        suppressesNextVisit = false
        didChange.send()
    }

    fileprivate func reportVisit() {
        if suppressesNextVisit {
            suppressesNextVisit = false
            return
        }
        // Only real web pages belong in history; `about:` and `data:` do not.
        guard let scheme = url.scheme, scheme == "http" || scheme == "https" else { return }
        reportedVisitURL = url
        let title = displayTitle
        delegate?.tab(self, didVisit: url, title: title)

        // The page's text goes to the full-text index once per page, not
        // once per reload: a page reloaded every thirty seconds would
        // otherwise pull its whole body over and re-index it each time.
        if !isPrivate, url != lastIndexedURL || Date.now.timeIntervalSince(lastIndexedAt) > 300 {
            lastIndexedURL = url
            lastIndexedAt = .now
            let script = "(function() { var b = document.body; if (!b) return ''; var t = b.innerText || b.textContent || ''; return t.length > 65536 ? t.slice(0, 65536) : t; })()"
            currentWebView?.evaluateJavaScript(script) { [weak self, weak delegate] result, _ in
                guard let self, let text = result as? String, !text.isEmpty else { return }
                delegate?.tab(self, didExtractContent: text, for: url, title: title)
            }
        }
    }
}

/// Holds the WebKit delegate conformances off `Tab` itself, so `Tab` stays a
/// plain Swift class rather than an `NSObject` subclass.
private final class TabNavigationHandler: NSObject, WKUIDelegate, WKNavigationDelegate {
    private weak var tab: Tab?

    /// URLs of `<a download>` clicks that have been allowed to load so the
    /// response can be turned into a download.
    ///
    /// Returning `.download` from the *action* policy is the documented way to
    /// download a `download`-attribute link, but on macOS 26 WebKit accepts
    /// that policy and then quietly does nothing: no request, no `didBecome`.
    /// Allowing the load and converting the *response* instead works, and is
    /// also what happens for a plain link to a non-displayable file. Recording
    /// the URL here lets the response honour the attribute even when the file
    /// is one the browser could have shown inline.
    private var pendingDownloadURLs: Set<URL> = []

    /// PDF responses turned into downloads so the tab can show them itself.
    private var pendingDocumentURLs: Set<URL> = []

    init(tab: Tab) {
        self.tab = tab
    }

    @MainActor
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // A site set to block pop-ups gets nothing back, which WebKit reports
        // to the page as the window failing to open.
        guard SiteSettings.shared.allowsPopups(for: webView.url) else { return nil }
        // WebKit performs the navigation itself once we hand back a web view
        // built from its configuration, so nothing is loaded here.
        guard let child = tab?.makeChildTab(with: configuration) else { return nil }
        return child.webView()
    }

    @MainActor
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        tab?.navigationStarted()
    }

    @MainActor
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // Zoom is a property of the web view, not the navigation, so it is
        // set once the new page is the one on screen.
        webView.pageZoom = SiteSettings.shared.pageZoom(for: webView.url, spaceDefault: tab?.overrides?.defaultZoom)
        tab?.navigationCommitted()
    }

    @MainActor
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        BoostCoordinator.shared.apply(to: webView)
        tab?.reportVisit()
    }

    @MainActor
    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        tab?.navigationFailed(error)
    }

    @MainActor
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        tab?.navigationFailed(error)
    }

    private static func isSplitLinkChord(_ flags: NSEvent.ModifierFlags) -> Bool {
        let considered: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let masked = flags.intersection(considered)
        return masked == [.option, .shift] || masked == [.option, .command] || masked == [.control, .option]
    }

    /// `<a download>` and anything else WebKit marks as a download before the
    /// navigation starts.
    @MainActor
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        // Modifier-click (Option-Shift or Option-Command) opens the link in the other split pane,
        // or splits the tab side-by-side if not already in a split.
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url,
           Self.isSplitLinkChord(navigationAction.modifierFlags),
           GlanceInvocation.isPermittedTarget(url) {
            decisionHandler(.cancel, preferences)
            if let tab {
                tab.delegate?.tab(tab, requestsOpenInSplit: url)
            }
            return
        }

        // Option-click on a link opens a glance instead of navigating. Decided
        // here because this is the only place that sees the modifier flags and
        // the destination before anything is loaded.
        if GlanceLinkMonitor.shared.intercept(navigationAction) {
            decisionHandler(.cancel, preferences)
            return
        }
        let url = navigationAction.request.url
        let sites = SiteSettings.shared
        // A link into another app: mailto, a meeting client, a music app.
        // The page's site decides whether it may hand off.
        if let url, let scheme = url.scheme?.lowercased(), !Self.webSchemes.contains(scheme) {
            handOff(url, from: webView.url)
            decisionHandler(.cancel, preferences)
            return
        }
        // Enterprise corporate policy URL filtering
        if let url,
           navigationAction.targetFrame?.isMainFrame ?? true,
           EnterprisePolicyManager.shared.isURLBlocked(url) {
            decisionHandler(.cancel, preferences)
            tab?.showBlockedByPolicy(url: url)
            return
        }
        if navigationAction.targetFrame?.isMainFrame ?? true,
           let url, Settings.shared.trackerRemoval.applies(isPrivate: tab?.isPrivate ?? false),
           let cleaned = TrackingParameters.cleaned(url) {
            // The same page without the parameters that only say where the
            // visit came from. Cancelled and reloaded clean; the clean
            // address has nothing left to strip, so this cannot loop.
            decisionHandler(.cancel, preferences)
            webView.load(URLRequest(url: cleaned))
            return
        }
        if navigationAction.targetFrame?.isMainFrame ?? true {
            // The per-site choices that ride on the navigation itself.
            preferences.allowsContentJavaScript = sites.allowsJavaScript(for: url)
            preferences.preferredContentMode = sites.prefersMobile(for: url) ? .mobile : .desktop
            // A per-site choice first, then the space's, then WebKit's own.
            webView.customUserAgent = sites.userAgent(for: url) ?? tab?.overrides?.userAgent
            ContentBlocker.shared.applySiteChoice(for: url, to: webView.configuration.userContentController)
            SitePolicy.shared.apply(for: url, to: webView.configuration.userContentController, spaceIdentity: tab?.identity)
            BoostCoordinator.shared.apply(for: url, to: webView.configuration.userContentController)
        }
        if navigationAction.shouldPerformDownload {
            guard sites.allowsDownloads(for: url) else {
                decisionHandler(.cancel, preferences)
                return
            }
            // Allowed to load, then converted in the response (see
            // `pendingDownloadURLs`). Anchored on the main frame only; a
            // sub-frame download attribute is honoured by the response's own
            // disposition, not tracked here.
            if let url, navigationAction.targetFrame?.isMainFrame ?? true {
                pendingDownloadURLs.insert(url)
            }
            decisionHandler(.allow, preferences)
            return
        }
        decisionHandler(DownloadManager.shared.policy(for: navigationAction), preferences)
    }

    private static let webSchemes: Set<String> = ["http", "https", "about", "blob", "data", "file", "javascript", "ws", "wss"]

    /// Opens a link in whatever app claims its scheme, as the page's site
    /// allows: outright, after asking, or not at all.
    @MainActor
    private func handOff(_ url: URL, from page: URL?) {
        switch SiteSettings.shared.permission(.externalApps, for: page) {
        case .deny:
            return
        case .allow:
            NSWorkspace.shared.open(url)
        case .ask:
            let app = NSWorkspace.shared.urlForApplication(toOpen: url)
                .map { FileManager.default.displayName(atPath: $0.path(percentEncoded: false)) }
            let alert = NSAlert()
            alert.messageText = app.map { "Open \u{201c}\($0)\u{201d}?" } ?? "Open this link in another app?"
            alert.informativeText = "\(page?.host() ?? "This page") wants to open \(url.absoluteString)."
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
        }
    }

    /// Camera and microphone, as the page's site allows. Ask leaves the
    /// prompt to WebKit, which is what the system dialog is for.
    @MainActor
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        let page = webView.url
        let sites = SiteSettings.shared
        var permissions: [SiteSettings.Permission] = []
        switch type {
        case .camera: permissions = [sites.permission(.camera, for: page)]
        case .microphone: permissions = [sites.permission(.microphone, for: page)]
        case .cameraAndMicrophone: permissions = [sites.permission(.camera, for: page), sites.permission(.microphone, for: page)]
        @unknown default: permissions = [.ask]
        }
        if permissions.contains(.deny) {
            decisionHandler(.deny)
        } else if permissions.allSatisfy({ $0 == .allow }) {
            decisionHandler(.grant)
        } else {
            decisionHandler(.prompt)
        }
    }

    /// A certificate WebKit would refuse is accepted on a site whose
    /// certificate check is off. Nowhere else.
    @MainActor
    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              !SiteSettings.shared.checksCertificates(for: webView.url ?? URL(string: "https://\(challenge.protectionSpace.host)"))
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    /// A response WebKit cannot render, or one the server marked
    /// `Content-Disposition: attachment`, becomes a download instead of a page.
    @MainActor
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
        // A `<a download>` click that was allowed through to here becomes a
        // download whatever its type, because the page asked for one.
        let responseURL = navigationResponse.response.url
        if let responseURL, pendingDownloadURLs.remove(responseURL) != nil {
            decisionHandler(.download)
            return
        }
        // A PDF for the tab itself: shown in Kylmora's viewer unless the
        // site's setting says otherwise. The bytes come as a download of this
        // same response, which is the one fetch that carries the tab's cookies.
        if let tab, let responseURL, PDFViewing.isPDF(navigationResponse) {
            switch SiteSettings.shared.pdfHandling(for: responseURL) {
            case .viewer, .preview:
                pendingDocumentURLs.insert(responseURL)
                tab.beginDocument(at: responseURL)
                decisionHandler(.download)
                return
            case .download:
                guard SiteSettings.shared.allowsDownloads(for: responseURL) else {
                    decisionHandler(.cancel)
                    return
                }
                decisionHandler(.download)
                return
            case .webkit:
                break
            }
        }
        let policy = DownloadManager.shared.policy(for: navigationResponse)
        if policy == .download, !SiteSettings.shared.allowsDownloads(for: responseURL) {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(policy)
    }

    @MainActor
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        DownloadManager.shared.adopt(download)
    }

    @MainActor
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        if let tab, let url = navigationResponse.response.url, pendingDocumentURLs.remove(url) != nil {
            if SiteSettings.shared.pdfHandling(for: url) == .preview {
                // Fetched the same way, then handed to whatever opens PDFs;
                // the tab goes back to the page it was on.
                let fetch = InlinePDFDownload(
                    url: url,
                    onFinish: { [weak tab] file in
                        tab?.clearDocument()
                        tab?.goBack()
                        NSWorkspace.shared.open(file)
                    },
                    onFail: { [weak tab] error in tab?.documentFailed(error, from: url) }
                )
                tab.adoptInlineDownload(download, using: fetch)
            } else {
                tab.adoptInlineDownload(download, for: url)
            }
            return
        }
        DownloadManager.shared.adopt(download)
    }
}

extension Notification.Name {
    static let tabMediaStateDidChange = Notification.Name("tabMediaStateDidChange")
}

