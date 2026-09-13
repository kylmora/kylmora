import AppKit
import Foundation

/// User preferences, on `UserDefaults`.
///
/// macOS already provides preference storage that is atomic, sandbox-aware and
/// synchronised across processes. A settings file of our own would be a worse
/// version of it.
@MainActor
final class Settings {
    static let shared = Settings()

    private enum Key {
        static let searchEngine = "searchEngineIdentifier"
        static let restoresSession = "restoresSessionOnLaunch"
        static let suspensionMinutes = "tabSuspensionMinutes"
        static let archiveHours = "tabArchiveHours"
        static let idleBadge = "tabIdleBadgeMode"
        static let compactMode = "compactModeEnabled"
        static let compactHidesToolbar = "compactModeHidesToolbar"
        static let compactRevealsOnHover = "compactModeRevealsOnHover"
        static let spaceSwitchWraps = "spaceSwitchWrapsAround"
        static let appearance = "appearancePreference"
        static let blocksAds = "contentBlockingBlocksAds"
        static let blocksCookieBanners = "contentBlockingBlocksCookieBanners"
        static let blocksTrackers = "contentBlockingBlocksTrackers"
        static let listOverrides = "contentBlockingListOverrides"
        static let homepage = "homepageURL"
        static let newTabTarget = "newTabTarget"
        static let customSearchEngines = "customSearchEngines"
        static let privateSearchEngine = "privateSearchEngineIdentifier"
        static let sameEngineInPrivate = "sameSearchEngineInPrivate"
        static let suggestTopHits = "suggestTopHits"
        static let suggestSearch = "suggestSearchEngine"
        static let suggestHistory = "suggestHistory"
        static let suggestBookmarks = "suggestBookmarks"
        static let suggestOpenTabs = "suggestOpenTabs"
        static let trackerRemoval = "trackerRemoval"
        static let historyRetention = "historyRetentionDays"
        static let cookieDeletion = "cookieDeletion"
        static let lastCookieDeletion = "lastCookieDeletion"
        static let historyDisabled = "historyDisabled"
        static let crashReports = "crashReportPolicy"
        static let customUserAgent = "customUserAgent"
        static let autoUpdatesFilterLists = "autoUpdatesFilterLists"
        static let upgradesToHTTPS = "upgradesKnownHostsToHTTPS"
        static let showsFullAddress = "showsFullAddress"
        static let showsUnicodeDomains = "showsUnicodeDomains"
        static let bookmarksInNewTabs = "opensBookmarksInNewTabs"
        static let favouriteShortcuts = "favouriteShortcutsEnabled"
        /// Superseded by `externalLinkPresentation`, and read only to carry a
        /// checkbox's answer over to it.
        static let externalLinksInGlance = "opensExternalLinksInGlance"
        static let externalLinkPresentation = "externalLinkPresentation"
        /// Set once the carry-over above has run. Deliberately absent from the
        /// registered defaults: see the migration in `init`.
        static let externalLinkMigrated = "externalLinkPresentationMigrated"
        static let compactShowsButtons = "compactModeShowsWindowButtons"
        static let confirmsClosingPiP = "confirmsClosingPictureInPicture"
        static let minimumFontSizeEnabled = "minimumFontSizeEnabled"
        static let minimumFontSize = "minimumFontSize"
        static let tabFocusesLinks = "tabFocusesLinks"
        static let preventsEscapeInFullScreen = "preventsEscapeExitingFullScreen"
        static let downloadLocation = "downloadLocation"
        static let downloadRemoval = "downloadRemoval"
        static let opensSafeFiles = "opensSafeFilesAfterDownloading"
        static let defaultSpace = "defaultSpaceIdentifier"
        static let externalLinkTarget = "externalLinkTarget"
        static let warnsBeforeQuitting = "warnsBeforeQuitting"
        static let formatsJSON = "formatsJSON"
        static let allowsChromeExtensions = "allowsChromeExtensions"
        static let allowsFirefoxExtensions = "allowsFirefoxExtensions"
        static let passwordProvider = "passwordProvider"
        static let passwordOfferAutofill = "passwordOfferAutofill"
        static let passwordOfferSave = "passwordOfferSave"
        static let passwordSubmitAutomatically = "passwordSubmitAutomatically"
        static let passwordUsesTouchID = "passwordUsesTouchID"
        static let syncEnabled = "syncEnabled"
        static let syncOpenTabs = "syncOpenTabs"
        static let syncBookmarks = "syncBookmarks"
        static let syncSiteSettings = "syncSiteSettings"
        static let syncCustomDirectory = "syncCustomDirectory"
        static let syncLastTimestamp = "syncLastTimestamp"
        static let syncService = "syncService"
        static let syncPassphrase = "syncPassphrase"
        static let syncWebDAVURL = "syncWebDAVURL"
        static let syncWebDAVUsername = "syncWebDAVUsername"
        static let syncWebDAVPassword = "syncWebDAVPassword"
        static let openCommandBarOnNewTab = "openCommandBarOnNewTab"
        static let userRulesText = "contentBlockingUserRulesText"
        static let customFilterLists = "contentBlockingCustomFilterLists"
        static let autoRejectCookieBanners = "contentBlockingAutoRejectCookieBanners"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // One-time: this replaced the "open links from other apps in a Glance"
        // checkbox, so a build that had it ticked keeps opening them in a
        // glance.
        //
        // Once, on the first launch of a build that has this key. Keyed on its
        // own marker rather than on "the new key has no value":
        // `register(defaults:)` fills a registration domain that every
        // `UserDefaults` in the process reads, so as soon as one `Settings`
        // exists the new key always has a value -- and its absence can never
        // mean "the user has not chosen". A choice made in Settings afterwards
        // is therefore never revisited.
        if defaults.object(forKey: Key.externalLinkMigrated) == nil {
            if defaults.bool(forKey: Key.externalLinksInGlance) {
                defaults.set(ExternalLinkPresentation.glance.rawValue, forKey: Key.externalLinkPresentation)
            }
            defaults.set(true, forKey: Key.externalLinkMigrated)
        }

        defaults.register(defaults: [
            Key.searchEngine: SearchEngine.duckDuckGo.id,
            Key.restoresSession: true,
            Key.suspensionMinutes: 10,
            // Off. Archiving removes rows the user did not ask to remove, so it
            // is the one tab-lifecycle setting that has to be switched on
            // deliberately rather than discovered after the fact.
            Key.archiveHours: 0,
            Key.idleBadge: TabIdleBadgeMode.asleep.rawValue,
            Key.compactMode: false,
            Key.compactHidesToolbar: false,
            Key.compactRevealsOnHover: true,
            Key.spaceSwitchWraps: true,
            Key.appearance: AppearancePreference.system.rawValue,
            Key.blocksAds: true,
            Key.blocksCookieBanners: true,
            Key.blocksTrackers: true,
            Key.newTabTarget: NewTabTarget.startPage.rawValue,
            Key.privateSearchEngine: SearchEngine.duckDuckGo.id,
            Key.sameEngineInPrivate: true,
            Key.suggestTopHits: true,
            Key.suggestSearch: true,
            Key.suggestHistory: true,
            Key.suggestBookmarks: true,
            Key.suggestOpenTabs: true,
            Key.trackerRemoval: TrackerRemoval.privateOnly.rawValue,
            Key.historyRetention: HistoryRetention.manually.rawValue,
            Key.cookieDeletion: CookieDeletion.manually.rawValue,
            Key.historyDisabled: false,
            Key.crashReports: CrashReportPolicy.ask.rawValue,
            Key.customUserAgent: "",
            Key.autoUpdatesFilterLists: true,
            Key.upgradesToHTTPS: true,
            Key.showsFullAddress: true,
            Key.showsUnicodeDomains: false,
            Key.bookmarksInNewTabs: true,
            Key.favouriteShortcuts: true,
            Key.externalLinkPresentation: ExternalLinkPresentation.tab.rawValue,
            Key.compactShowsButtons: true,
            Key.confirmsClosingPiP: true,
            Key.minimumFontSizeEnabled: false,
            Key.minimumFontSize: 9,
            Key.tabFocusesLinks: false,
            Key.preventsEscapeInFullScreen: false,
            Key.downloadLocation: DownloadLocation.downloads.rawValue,
            Key.downloadRemoval: DownloadRemoval.manually.rawValue,
            Key.opensSafeFiles: false,
            Key.externalLinkTarget: ExternalLinkTarget.currentSpace.rawValue,
            Key.warnsBeforeQuitting: true,
            Key.formatsJSON: true,
            Key.allowsChromeExtensions: true,
            Key.allowsFirefoxExtensions: true,
            Key.passwordProvider: PasswordProvider.keychain.rawValue,
            Key.passwordOfferAutofill: true,
            Key.passwordOfferSave: true,
            Key.passwordSubmitAutomatically: false,
            Key.passwordUsesTouchID: true,
            Key.syncEnabled: false,
            Key.syncOpenTabs: true,
            Key.syncBookmarks: true,
            Key.syncSiteSettings: true,
            Key.syncCustomDirectory: "",
            Key.syncLastTimestamp: 0.0,
            Key.syncService: SyncService.iCloud.rawValue,
            Key.syncPassphrase: "",
            Key.syncWebDAVURL: "",
            Key.syncWebDAVUsername: "",
            Key.syncWebDAVPassword: "",
            Key.userRulesText: "",
            Key.autoRejectCookieBanners: true
        ])
    }

    var trackerRemoval: TrackerRemoval {
        get { TrackerRemoval(rawValue: defaults.string(forKey: Key.trackerRemoval) ?? "") ?? .privateOnly }
        set { defaults.set(newValue.rawValue, forKey: Key.trackerRemoval) }
    }

    var historyRetention: HistoryRetention {
        get { HistoryRetention(rawValue: defaults.integer(forKey: Key.historyRetention)) ?? .manually }
        set { defaults.set(newValue.rawValue, forKey: Key.historyRetention) }
    }

    var cookieDeletion: CookieDeletion {
        get { CookieDeletion(rawValue: defaults.string(forKey: Key.cookieDeletion) ?? "") ?? .manually }
        set { defaults.set(newValue.rawValue, forKey: Key.cookieDeletion) }
    }

    var lastCookieDeletion: Date? {
        get { defaults.object(forKey: Key.lastCookieDeletion) as? Date }
        set { defaults.set(newValue, forKey: Key.lastCookieDeletion) }
    }

    /// Nothing visited is recorded while this is on.
    var historyDisabled: Bool {
        get { defaults.bool(forKey: Key.historyDisabled) }
        set { defaults.set(newValue, forKey: Key.historyDisabled) }
    }

    var crashReportPolicy: CrashReportPolicy {
        get { CrashReportPolicy(rawValue: defaults.string(forKey: Key.crashReports) ?? "") ?? .ask }
        set { defaults.set(newValue.rawValue, forKey: Key.crashReports) }
    }

    /// The string a site set to "Custom" in Website Settings is shown. Nil
    /// while empty, which leaves WebKit's own.
    var customUserAgent: String? {
        get {
            let text = defaults.string(forKey: Key.customUserAgent)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? nil : text
        }
        set { defaults.set(newValue ?? "", forKey: Key.customUserAgent) }
    }

    var autoUpdatesFilterLists: Bool {
        get { defaults.bool(forKey: Key.autoUpdatesFilterLists) }
        set { defaults.set(newValue, forKey: Key.autoUpdatesFilterLists) }
    }

    // MARK: - General

    var downloadLocation: DownloadLocation {
        get { DownloadLocation(rawValue: defaults.string(forKey: Key.downloadLocation) ?? "") ?? .downloads }
        set { defaults.set(newValue.rawValue, forKey: Key.downloadLocation) }
    }

    var downloadRemoval: DownloadRemoval {
        get { DownloadRemoval(rawValue: defaults.string(forKey: Key.downloadRemoval) ?? "") ?? .manually }
        set { defaults.set(newValue.rawValue, forKey: Key.downloadRemoval) }
    }

    /// Movies, pictures, sounds, PDFs, text and archives open themselves
    /// once downloaded.
    var opensSafeFilesAfterDownloading: Bool {
        get { defaults.bool(forKey: Key.opensSafeFiles) }
        set { defaults.set(newValue, forKey: Key.opensSafeFiles) }
    }

    /// The space links from other apps land in when that is the choice
    /// below. Nil means the first space.
    var defaultSpaceID: UUID? {
        get { defaults.string(forKey: Key.defaultSpace).flatMap(UUID.init) }
        set { defaults.set(newValue?.uuidString, forKey: Key.defaultSpace) }
    }

    var externalLinkTarget: ExternalLinkTarget {
        get { ExternalLinkTarget(rawValue: defaults.string(forKey: Key.externalLinkTarget) ?? "") ?? .currentSpace }
        set { defaults.set(newValue.rawValue, forKey: Key.externalLinkTarget) }
    }

    var warnsBeforeQuitting: Bool {
        get { defaults.bool(forKey: Key.warnsBeforeQuitting) }
        set { defaults.set(newValue, forKey: Key.warnsBeforeQuitting) }
    }

    // MARK: - Browsing

    var upgradesToHTTPS: Bool {
        get { defaults.bool(forKey: Key.upgradesToHTTPS) }
        set { defaults.set(newValue, forKey: Key.upgradesToHTTPS) }
    }

    var showsFullAddress: Bool {
        get { defaults.bool(forKey: Key.showsFullAddress) }
        set { defaults.set(newValue, forKey: Key.showsFullAddress) }
    }

    var showsUnicodeDomains: Bool {
        get { defaults.bool(forKey: Key.showsUnicodeDomains) }
        set { defaults.set(newValue, forKey: Key.showsUnicodeDomains) }
    }

    var opensBookmarksInNewTabs: Bool {
        get { defaults.bool(forKey: Key.bookmarksInNewTabs) }
        set { defaults.set(newValue, forKey: Key.bookmarksInNewTabs) }
    }

    /// Option-Command-1 to 9 open the space's pinned sites.
    var favouriteShortcutsEnabled: Bool {
        get { defaults.bool(forKey: Key.favouriteShortcuts) }
        set { defaults.set(newValue, forKey: Key.favouriteShortcuts) }
    }

    /// How a link from another app is shown: a tab, a Little Arc window, or a
    /// glance. Shift held is always a tab, wherever this points
    /// (`LittleArcRouting`).
    var externalLinkPresentation: ExternalLinkPresentation {
        get {
            ExternalLinkPresentation(rawValue: defaults.string(forKey: Key.externalLinkPresentation) ?? "")
                ?? .tab
        }
        set { defaults.set(newValue.rawValue, forKey: Key.externalLinkPresentation) }
    }

    var compactModeShowsWindowButtons: Bool {
        get { defaults.bool(forKey: Key.compactShowsButtons) }
        set { defaults.set(newValue, forKey: Key.compactShowsButtons) }
    }

    var confirmsClosingPictureInPicture: Bool {
        get { defaults.bool(forKey: Key.confirmsClosingPiP) }
        set { defaults.set(newValue, forKey: Key.confirmsClosingPiP) }
    }

    // Spell checking is controlled through the standard Edit > Spelling and
    // Grammar menu, which WKWebView answers on the responder chain (see
    // MainMenu.spellingMenuItem). There is no Settings mirror: a stored flag
    // cannot drive WKWebView's per-field continuous checking, so a toggle here
    // would only have looked like it worked.

    var minimumFontSizeEnabled: Bool {
        get { defaults.bool(forKey: Key.minimumFontSizeEnabled) }
        set { defaults.set(newValue, forKey: Key.minimumFontSizeEnabled) }
    }

    var minimumFontSize: Int {
        get { max(1, defaults.integer(forKey: Key.minimumFontSize)) }
        set { defaults.set(max(1, min(72, newValue)), forKey: Key.minimumFontSize) }
    }

    /// The size WebKit is given: zero means no minimum.
    var effectiveMinimumFontSize: Double {
        minimumFontSizeEnabled ? Double(minimumFontSize) : 0
    }

    var tabFocusesLinks: Bool {
        get { defaults.bool(forKey: Key.tabFocusesLinks) }
        set { defaults.set(newValue, forKey: Key.tabFocusesLinks) }
    }

    var preventsEscapeExitingFullScreen: Bool {
        get { defaults.bool(forKey: Key.preventsEscapeInFullScreen) }
        set { defaults.set(newValue, forKey: Key.preventsEscapeInFullScreen) }
    }

    /// JSON documents are shown indented and coloured.
    var formatsJSON: Bool {
        get { defaults.bool(forKey: Key.formatsJSON) }
        set { defaults.set(newValue, forKey: Key.formatsJSON) }
    }

    /// Whether the Chrome Web Store and `.crx` files are offered as sources.
    var allowsChromeExtensions: Bool {
        get { defaults.bool(forKey: Key.allowsChromeExtensions) }
        set { defaults.set(newValue, forKey: Key.allowsChromeExtensions) }
    }

    /// Which password manager fills and saves logins: the system Keychain, or
    /// an external manager the user is pointed to install.
    var passwordProvider: PasswordProvider {
        get { PasswordProvider(rawValue: defaults.string(forKey: Key.passwordProvider) ?? "") ?? .keychain }
        set { defaults.set(newValue.rawValue, forKey: Key.passwordProvider) }
    }

    var passwordOfferAutofill: Bool {
        get { defaults.bool(forKey: Key.passwordOfferAutofill) }
        set { defaults.set(newValue, forKey: Key.passwordOfferAutofill) }
    }

    var passwordOfferSave: Bool {
        get { defaults.bool(forKey: Key.passwordOfferSave) }
        set { defaults.set(newValue, forKey: Key.passwordOfferSave) }
    }

    var passwordSubmitAutomatically: Bool {
        get { defaults.bool(forKey: Key.passwordSubmitAutomatically) }
        set { defaults.set(newValue, forKey: Key.passwordSubmitAutomatically) }
    }

    var passwordUsesTouchID: Bool {
        get { defaults.bool(forKey: Key.passwordUsesTouchID) }
        set { defaults.set(newValue, forKey: Key.passwordUsesTouchID) }
    }

    /// Whether Mozilla's add-on site and `.xpi` files are offered as sources.
    var allowsFirefoxExtensions: Bool {
        get { defaults.bool(forKey: Key.allowsFirefoxExtensions) }
        set { defaults.set(newValue, forKey: Key.allowsFirefoxExtensions) }
    }

    /// The page "Homepage" means. Nil until the user sets one.
    var homepageURL: URL? {
        get { defaults.string(forKey: Key.homepage).flatMap { URL(string: $0) } }
        set { defaults.set(newValue?.absoluteString, forKey: Key.homepage) }
    }

    /// A typed homepage, tolerant of a bare host: "example.com" is what
    /// people type, and refusing it teaches nothing.
    static func homepageURL(from text: String) -> URL? {
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), url.scheme != nil, url.host() != nil { return url }
        return URL(string: "https://" + text).flatMap { $0.host() != nil ? $0 : nil }
    }

    var newTabTarget: NewTabTarget {
        get { NewTabTarget(rawValue: defaults.string(forKey: Key.newTabTarget) ?? "") ?? .startPage }
        set { defaults.set(newValue.rawValue, forKey: Key.newTabTarget) }
    }

    /// Whether Cmd-T opens the floating command palette over the current page
    /// without replacing or creating a blank page first.
    var openCommandBarOnNewTab: Bool {
        get { defaults.object(forKey: Key.openCommandBarOnNewTab) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.openCommandBarOnNewTab) }
    }

    /// The content-blocking switches and per-list choices. On by default:
    /// a browser that ships with the lists and does not apply them is
    /// asking the user to discover a setting before the web is bearable.
    var contentBlocking: ContentBlockingPreferences {
        get {
            var preferences = ContentBlockingPreferences()
            preferences.blocksAds = defaults.bool(forKey: Key.blocksAds)
            preferences.blocksCookieBanners = defaults.bool(forKey: Key.blocksCookieBanners)
            preferences.blocksTrackers = defaults.bool(forKey: Key.blocksTrackers)
            preferences.listOverrides = defaults.dictionary(forKey: Key.listOverrides) as? [String: Bool] ?? [:]
            return preferences
        }
        set {
            defaults.set(newValue.blocksAds, forKey: Key.blocksAds)
            defaults.set(newValue.blocksCookieBanners, forKey: Key.blocksCookieBanners)
            defaults.set(newValue.blocksTrackers, forKey: Key.blocksTrackers)
            defaults.set(newValue.listOverrides, forKey: Key.listOverrides)
        }
    }

    /// The user's custom Adblock Plus rules (cosmetic hiding, network blocks, exceptions).
    var userRulesText: String {
        get { defaults.string(forKey: Key.userRulesText) ?? "" }
        set { defaults.set(newValue, forKey: Key.userRulesText) }
    }

    /// Whether common CMP cookie consent banners should be automatically declined/rejected.
    var autoRejectCookieBanners: Bool {
        get { defaults.object(forKey: Key.autoRejectCookieBanners) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.autoRejectCookieBanners) }
    }

    /// Third-party filter lists subscribed to by URL.
    var customFilterLists: [CustomFilterList] {
        get {
            guard let data = defaults.data(forKey: Key.customFilterLists),
                  let lists = try? JSONDecoder().decode([CustomFilterList].self, from: data) else {
                return []
            }
            return lists
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            defaults.set(data, forKey: Key.customFilterLists)
        }
    }

    var searchEngine: SearchEngine {
        get { engine(named: defaults.string(forKey: Key.searchEngine)) }
        set { defaults.set(newValue.id, forKey: Key.searchEngine) }
    }

    /// The engine a private space searches with, which is the ordinary one
    /// unless the user has split them.
    var privateSearchEngine: SearchEngine {
        get {
            usesSameSearchEngineInPrivate ? searchEngine : engine(named: defaults.string(forKey: Key.privateSearchEngine))
        }
        set { defaults.set(newValue.id, forKey: Key.privateSearchEngine) }
    }

    /// The private engine as chosen, whether or not it is in use.
    var chosenPrivateSearchEngine: SearchEngine {
        engine(named: defaults.string(forKey: Key.privateSearchEngine))
    }

    var usesSameSearchEngineInPrivate: Bool {
        get { defaults.bool(forKey: Key.sameEngineInPrivate) }
        set { defaults.set(newValue, forKey: Key.sameEngineInPrivate) }
    }

    func searchEngine(isPrivate: Bool) -> SearchEngine {
        isPrivate ? privateSearchEngine : searchEngine
    }

    /// Built-in first, then the user's own.
    var searchEngines: [SearchEngine] { SearchEngine.all + customSearchEngines }

    var customSearchEngines: [SearchEngine] {
        get {
            guard let data = defaults.data(forKey: Key.customSearchEngines) else { return [] }
            return (try? JSONDecoder().decode([SearchEngine].self, from: data)) ?? []
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.customSearchEngines) }
    }

    /// Removing the engine in use falls back to the built-in default rather
    /// than leaving a choice that names nothing.
    func removeCustomSearchEngine(_ id: String) {
        customSearchEngines.removeAll { $0.id == id }
        if defaults.string(forKey: Key.searchEngine) == id { searchEngine = .duckDuckGo }
        if defaults.string(forKey: Key.privateSearchEngine) == id { privateSearchEngine = .duckDuckGo }
    }

    private func engine(named id: String?) -> SearchEngine {
        searchEngines.first { $0.id == id } ?? .duckDuckGo
    }

    /// Which sources the command bar suggests from.
    struct SuggestionSources: Equatable, Sendable {
        var topHits = true
        var searchEngine = true
        var history = true
        var bookmarks = true
        var openTabs = true
    }

    var suggestionSources: SuggestionSources {
        get {
            SuggestionSources(
                topHits: defaults.bool(forKey: Key.suggestTopHits),
                searchEngine: defaults.bool(forKey: Key.suggestSearch),
                history: defaults.bool(forKey: Key.suggestHistory),
                bookmarks: defaults.bool(forKey: Key.suggestBookmarks),
                openTabs: defaults.bool(forKey: Key.suggestOpenTabs)
            )
        }
        set {
            defaults.set(newValue.topHits, forKey: Key.suggestTopHits)
            defaults.set(newValue.searchEngine, forKey: Key.suggestSearch)
            defaults.set(newValue.history, forKey: Key.suggestHistory)
            defaults.set(newValue.bookmarks, forKey: Key.suggestBookmarks)
            defaults.set(newValue.openTabs, forKey: Key.suggestOpenTabs)
        }
    }

    var restoresSession: Bool {
        get { defaults.bool(forKey: Key.restoresSession) }
        set { defaults.set(newValue, forKey: Key.restoresSession) }
    }

    /// Choices offered in Settings. Zero means never suspend.
    static let suspensionChoices: [Int] = [0, 5, 10, 30, 60]

    var tabSuspensionMinutes: Int {
        get { defaults.integer(forKey: Key.suspensionMinutes) }
        set { defaults.set(newValue, forKey: Key.suspensionMinutes) }
    }

    /// How long a background tab may sit before its memory is reclaimed, or nil
    /// when the user has turned suspension off.
    var tabSuspensionDelay: TimeInterval? {
        let minutes = tabSuspensionMinutes
        return minutes > 0 ? TimeInterval(minutes) * 60 : nil
    }

    /// Measured in hours, not minutes: the second stage is about days away from
    /// a tab, and offering "archive after 5 minutes" would invite people to
    /// configure their tabs into disappearing.
    static let archiveChoices: [Int] = [0, 12, 24, 72, 168, 720]

    var tabArchiveHours: Int {
        get { defaults.integer(forKey: Key.archiveHours) }
        set { defaults.set(newValue, forKey: Key.archiveHours) }
    }

    /// How long a *sleeping* tab may sit before it leaves the sidebar, or nil
    /// when archiving is off.
    var tabArchiveDelay: TimeInterval? {
        let hours = tabArchiveHours
        return hours > 0 ? TimeInterval(hours) * 3_600 : nil
    }

    var tabIdleBadgeMode: TabIdleBadgeMode {
        get { TabIdleBadgeMode(rawValue: defaults.string(forKey: Key.idleBadge) ?? "") ?? .asleep }
        set { defaults.set(newValue.rawValue, forKey: Key.idleBadge) }
    }

    /// Whether the window comes back in compact mode. A window that forgets
    /// its mode on every launch is a mode nobody keeps using.
    var compactModeEnabled: Bool {
        get { defaults.bool(forKey: Key.compactMode) }
        set { defaults.set(newValue, forKey: Key.compactMode) }
    }

    /// The compact-mode preferences as one value. Reading it applies the
    /// system's Reduce Motion setting, which is not a preference of ours to
    /// store -- it may change while the app is running and the stored copy
    /// would then be wrong.
    var compactModeConfiguration: CompactModeConfiguration {
        get {
            var configuration = CompactModeConfiguration()
            configuration.hidesToolbar = defaults.bool(forKey: Key.compactHidesToolbar)
            configuration.revealsOnHover = defaults.bool(forKey: Key.compactRevealsOnHover)
            configuration.reducesMotion = NSWorkspace.shared
                .accessibilityDisplayShouldReduceMotion
            return configuration
        }
        set {
            defaults.set(newValue.hidesToolbar, forKey: Key.compactHidesToolbar)
            defaults.set(newValue.revealsOnHover, forKey: Key.compactRevealsOnHover)
        }
    }

    /// Spaces wrap at the ends of the list. A repeated shortcut that silently
    /// stops at the end is indistinguishable from one that has stopped working.
    var spaceSwitchWraps: Bool {
        get { defaults.bool(forKey: Key.spaceSwitchWraps) }
        set { defaults.set(newValue, forKey: Key.spaceSwitchWraps) }
    }

    /// Light, dark, or whatever the Mac is set to.
    var appearance: AppearancePreference {
        get { AppearancePreference(storedValue: defaults.string(forKey: Key.appearance)) }
        set { defaults.set(newValue.rawValue, forKey: Key.appearance) }
    }

    /// Applies the stored appearance to the whole application.
    ///
    /// Set on `NSApp` rather than on each window: panels, menus, the Settings
    /// window and any sheet all have to agree, and one of them disagreeing is
    /// more obvious than all of them being wrong together.
    func applyAppearance() {
        NSApp.appearance = appearance.appearance
    }

    /// Where a new tab starts: the homepage when one is set and chosen,
    /// otherwise the search engine's start page.
    var newTabURL: URL { newTabURL(isPrivate: false) }

    /// A private space starts on its own engine's page.
    func newTabURL(isPrivate: Bool) -> URL {
        if newTabTarget == .homepage, let homepage = homepageURL { return homepage }
        return searchEngine(isPrivate: isPrivate).homeURL
    }

    // MARK: - Sync

    var syncEnabled: Bool {
        get { defaults.bool(forKey: Key.syncEnabled) }
        set { defaults.set(newValue, forKey: Key.syncEnabled) }
    }

    var syncOpenTabs: Bool {
        get { defaults.bool(forKey: Key.syncOpenTabs) }
        set { defaults.set(newValue, forKey: Key.syncOpenTabs) }
    }

    var syncBookmarks: Bool {
        get { defaults.bool(forKey: Key.syncBookmarks) }
        set { defaults.set(newValue, forKey: Key.syncBookmarks) }
    }

    var syncSiteSettings: Bool {
        get { defaults.bool(forKey: Key.syncSiteSettings) }
        set { defaults.set(newValue, forKey: Key.syncSiteSettings) }
    }

    var syncCustomDirectory: String {
        get { defaults.string(forKey: Key.syncCustomDirectory) ?? "" }
        set { defaults.set(newValue, forKey: Key.syncCustomDirectory) }
    }

    var syncLastTimestamp: Double {
        get { defaults.double(forKey: Key.syncLastTimestamp) }
        set { defaults.set(newValue, forKey: Key.syncLastTimestamp) }
    }

    var syncService: SyncService {
        get {
            guard let raw = defaults.string(forKey: Key.syncService),
                  let service = SyncService(rawValue: raw) else {
                return .iCloud
            }
            return service
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.syncService)
        }
    }

    var syncPassphrase: String {
        get { defaults.string(forKey: Key.syncPassphrase) ?? "" }
        set {
            defaults.set(newValue, forKey: Key.syncPassphrase)
        }
    }

    var syncWebDAVURL: String {
        get { defaults.string(forKey: Key.syncWebDAVURL) ?? "" }
        set {
            defaults.set(newValue, forKey: Key.syncWebDAVURL)
        }
    }

    var syncWebDAVUsername: String {
        get { defaults.string(forKey: Key.syncWebDAVUsername) ?? "" }
        set {
            defaults.set(newValue, forKey: Key.syncWebDAVUsername)
        }
    }

    var syncWebDAVPassword: String {
        get { defaults.string(forKey: Key.syncWebDAVPassword) ?? "" }
        set {
            defaults.set(newValue, forKey: Key.syncWebDAVPassword)
        }
    }
}

/// A user-subscribed external Adblock Plus / uBlock Origin filter list.
public struct CustomFilterList: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var url: URL
    public var isEnabled: Bool

    public init(id: UUID = UUID(), name: String, url: URL, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.url = url
        self.isEnabled = isEnabled
    }
}

