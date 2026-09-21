import AppKit
import WebKit

/// What WebKit's extension engine sees when it asks about Kylmora's tabs.
///
/// A separate object rather than a conformance on `Tab`, because the engine
/// keys tabs by object identity and by `NSObject`, and `Tab` is neither meant
/// to be an `NSObject` nor to know that extensions exist. One adapter per tab,
/// held by the manager, so the identity stays put for as long as the tab does.
@available(macOS 15.4, *)
@MainActor
final class ExtensionTabAdapter: NSObject, WKWebExtensionTab {
    private(set) weak var tab: Tab?
    private unowned let manager: ExtensionManager

    init(tab: Tab, manager: ExtensionManager) {
        self.tab = tab
        self.manager = manager
    }

    private var session: BrowserSession? { manager.session }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        manager.windowAdapter
    }

    /// The tab's position in the window, or `NSNotFound` when it is not in one.
    ///
    /// `Int`, not `UInt`: the requirement is declared `NSUInteger` in the
    /// header, but Swift imports it as `Int`, and a `UInt` method only *nearly*
    /// matches the optional requirement -- WebKit never calls it and falls back
    /// to walking the window's whole tab list on every query. `NSNotFound`, not
    /// `0`, is what the header asks for when the tab is in no window; `0` would
    /// claim the first tab's place.
    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        guard let tab, let index = manager.visibleTabs.firstIndex(where: { $0 === tab }) else { return NSNotFound }
        return index
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? { tab?.currentWebView }
    func title(for context: WKWebExtensionContext) -> String? { tab?.displayTitle }
    func url(for context: WKWebExtensionContext) -> URL? { tab?.url }
    func pendingURL(for context: WKWebExtensionContext) -> URL? {
        guard let tab, tab.isLoading else { return nil }
        return tab.displayURL
    }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(tab?.isLoading ?? false) }
    func isSelected(for context: WKWebExtensionContext) -> Bool {
        guard let tab, let session else { return false }
        return session.activeTab === tab
    }
    func isPinned(for context: WKWebExtensionContext) -> Bool { tab?.pinnedSiteID != nil }
    /// Kylmora keeps the mute state itself, for the audio badge and the tab
    /// menu. The engine's default for this is always `NO`, so without it an
    /// extension that muted a tab and asked would be told it was not muted.
    func isMuted(for context: WKWebExtensionContext) -> Bool { tab?.isMuted ?? false }
    /// Whether the page is making noise, which the engine defaults to `NO` --
    /// so without this no extension can show an audio indicator.
    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool { tab?.isPlayingAudio ?? false }
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let tab, let session else { return completionHandler(nil) }
        if let space = session.spaces.first(where: { $0.index(of: tab) != nil }), space.id != session.activeSpaceID {
            session.selectSpace(space)
        }
        session.selectTab(tab)
        completionHandler(nil)
    }

    func setSelected(_ selected: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        if selected { activate(for: context, completionHandler: completionHandler) } else { completionHandler(nil) }
    }

    /// Muting from an extension. The engine leaves this one to the embedder --
    /// "No action is performed if not implemented" -- so without it a tab an
    /// extension muted stayed audible, and the extension was told it worked.
    func setMuted(_ muted: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        tab?.setMuted(muted)
        completionHandler(nil)
    }

    /// Pinning from an extension. Kylmora pins by turning the page into a tile
    /// in the Space, which the session already knows how to do -- and `pin`
    /// refuses a tab that is not in the active Space, so this cannot move a tab
    /// somewhere it does not belong. The engine's default is again "no action
    /// is performed", so without this an extension that pinned a tab was told
    /// it worked and nothing moved.
    func setPinned(_ pinned: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let tab, let session else { return completionHandler(nil) }
        if pinned { session.pin(tab) } else { session.unpin(tab) }
        completionHandler(nil)
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        tab?.load(url)
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        tab?.reload()
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        tab?.goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        tab?.goForward()
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        if let tab { session?.closeTab(tab) }
        completionHandler(nil)
    }

    func duplicate(
        using configuration: WKWebExtension.TabConfiguration,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, Error?) -> Void
    ) {
        guard let tab, let session, let copy = session.duplicate(tab) else { return completionHandler(nil, nil) }
        completionHandler(manager.adapter(for: copy), nil)
    }
}

/// Kylmora's one window, as the engine sees it.
@available(macOS 15.4, *)
@MainActor
final class ExtensionWindowAdapter: NSObject, WKWebExtensionWindow {
    private(set) weak var windowController: BrowserWindowController?
    private unowned let manager: ExtensionManager

    init(windowController: BrowserWindowController, manager: ExtensionManager) {
        self.windowController = windowController
        self.manager = manager
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        manager.visibleTabs.map { manager.adapter(for: $0) }
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard let tab = manager.session?.activeTab, manager.visibleTabs.contains(where: { $0 === tab }) else { return nil }
        return manager.adapter(for: tab)
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window = windowController?.window else { return .normal }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        if window.isMiniaturized { return .minimized }
        if window.isZoomed { return .maximized }
        return .normal
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }

    func frame(for context: WKWebExtensionContext) -> CGRect { windowController?.window?.frame ?? .zero }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        windowController?.window?.screen?.frame ?? NSScreen.main?.frame ?? .zero
    }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        windowController?.window?.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }
}
