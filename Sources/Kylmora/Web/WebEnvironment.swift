import AppKit
import WebKit

/// Creates web views, and owns one `WKWebsiteDataStore` per space identity.
///
/// `WKProcessPool` is deliberately absent: Apple deprecated it in macOS 12 and
/// it no longer affects process sharing, so creating one would be dead weight.
/// Web views that share a `WKWebsiteDataStore` already share WebKit's network
/// and content processes — which also means spaces are the unit of process
/// sharing, not tabs.
///
/// Stores are cached because `WKWebsiteDataStore(forIdentifier:)` returns a
/// distinct object each call, and two objects for one space would defeat the
/// sharing above.
@MainActor
final class WebEnvironment {
    static let shared = WebEnvironment()

    private var stores: [Space.Identity: WKWebsiteDataStore] = [:]

    private init() {}

    func dataStore(for identity: Space.Identity) -> WKWebsiteDataStore {
        if let existing = stores[identity] { return existing }

        let store: WKWebsiteDataStore = switch identity {
        case .standard: .default()
        case .isolated(let identifier): WKWebsiteDataStore(forIdentifier: identifier)
        case .ephemeral: .nonPersistent()
        }
        stores[identity] = store
        return store
    }

    /// Drops the cached store so WebKit can release it. Required before the
    /// on-disk data can be removed: `remove(forIdentifier:)` fails while a store
    /// is still in use.
    func releaseDataStore(for identity: Space.Identity) {
        stores[identity] = nil
    }

    /// Erases a space's website data.
    ///
    /// An isolated store is removed from disk. The standard store is WebKit's
    /// default one and cannot be removed, so it is emptied instead. An
    /// ephemeral store held nothing on disk to begin with.
    ///
    /// WebKit refuses with "Data store is in use (by network process)" while any
    /// reference to the store is still alive, and measurement shows retrying
    /// does not help until the last one is released — but that the very next
    /// attempt succeeds once it is. So this retries a few times to cover the
    /// gap between releasing our reference and the deallocation landing.
    static func removeStoredData(for identity: Space.Identity) async {
        switch identity {
        case .ephemeral:
            return
        case .standard:
            let everything = WKWebsiteDataStore.allWebsiteDataTypes()
            await WKWebsiteDataStore.default().removeData(ofTypes: everything, modifiedSince: .distantPast)
        case .isolated(let identifier):
            await removeIsolatedStore(identifier)
        }
    }

    private static func removeIsolatedStore(_ identifier: UUID) async {
        for attempt in 1...5 {
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: identifier)
                return
            } catch {
                if attempt == 5 {
                    NSLog("Kylmora: could not delete space data for \(identifier): \(error.localizedDescription)")
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// Each space's default fonts, by identity, so a configuration made for
    /// a space starts with them. Set by the session as spaces are made,
    /// restored and edited.
    private var fonts: [Space.Identity: WebFonts] = [:]

    func setFonts(_ fonts: WebFonts, for identity: Space.Identity) {
        self.fonts[identity] = fonts
    }

    func fonts(for identity: Space.Identity) -> WebFonts {
        fonts[identity] ?? .webKitDefaults
    }

    func makeConfiguration(for identity: Space.Identity) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore(for: identity)
        configuration.suppressesIncrementalRendering = false

        // The Browsing pane's per-web-view preferences.
        let settings = Settings.shared
        configuration.upgradeKnownHostsToHTTPS = settings.upgradesToHTTPS
        configuration.preferences.minimumFontSize = settings.effectiveMinimumFontSize
        configuration.preferences.tabFocusesLinks = settings.tabFocusesLinks

        // Match the affordances users expect from a real browser.
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        // Glance records the link under the pointer on mousedown, in a content
        // world the page cannot reach.
        GlanceLinkMonitor.shared.install(in: configuration)

        // The chosen filter lists, applied inside WebKit.
        ContentBlocker.shared.attach(configuration.userContentController)
        // Automatic cookie banner rejection for common CMPs.
        CookieConsentAutoReject.shared.attach(configuration.userContentController)
        // Interactive element picker and zapper message handler.
        ElementPickerCoordinator.shared.attach(configuration.userContentController)
        // JSON documents, made readable.
        JSONFormatting.shared.attach(configuration.userContentController)
        // The per-site settings that live in the page.
        SitePolicy.shared.attach(configuration.userContentController)
        // Save and fill logins from the macOS Keychain.
        PasswordAutofill.shared.attach(configuration.userContentController)
        // The space's default fonts.
        WebFontStyling.install(fonts(for: identity), in: configuration.userContentController)

        // Extensions' content scripts reach every page made here.
        if #available(macOS 15.4, *) {
            configuration.webExtensionController = ExtensionManager.shared.controller
            if ExtensionManager.isLogging {
                NSLog("kylmora.extension: configuration made with controller, %d contexts loaded",
                      ExtensionManager.shared.controller.extensionContexts.count)
            }
        }

        return configuration
    }

    func makeWebView(frame: NSRect = .zero, identity: Space.Identity) -> WKWebView {
        makeWebView(frame: frame, configuration: makeConfiguration(for: identity))
    }

    /// Wraps a configuration WebKit handed us (the `window.open` path), so those
    /// web views get the same affordances as ones we create ourselves.
    func makeWebView(frame: NSRect = .zero, configuration: WKWebViewConfiguration) -> WKWebView {
        // Subclassed only to add "Open Link in Glance" to the page's context
        // menu: WebKit exposes no delegate hook for it on macOS.
        let webView = GlanceWebView(frame: frame, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        return webView
    }
}
