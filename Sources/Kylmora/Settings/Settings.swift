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
        static let sidebarMode = "sidebarDisplayMode"
        static let sidebarPosition = "sidebarPosition"
        static let sidebarWidth = "sidebarWidth"
        static let sidebarWidthPerSpace = "sidebarWidthPerSpace"
        static let sidebarHoverDelay = "sidebarHoverDelay"
        static let sidebarDensity = "sidebarDensity"
        static let showsTabStrip = "showsTabStrip"
        static let taskManagerInSidebar = "showsTaskManagerInSidebar"
        static let toolbarLayout = "toolbarLayout"
        static let zenMode = "zenModeEnabled"
        static let spaceSwitchWraps = "spaceSwitchWrapsAround"
        static let appearance = "appearancePreference"
        static let settingsAppearance = "settingsWindowAppearance"
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
        static let automaticallyCheckForUpdates = "automaticallyCheckForUpdates"
        static let automaticallyDownloadUpdates = "automaticallyDownloadUpdates"
        static let skippedUpdateVersion = "skippedUpdateVersion"
        static let lastUpdateCheckDate = "lastUpdateCheckDate"
        static let lastLaunchedVersion = "lastLaunchedVersion"
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
        static let nativeMessagingEnabled = "nativeMessagingEnabled"
        static let nativeMessagingUsesOtherBrowsers = "nativeMessagingUsesOtherBrowsersHosts"
        static let nativeMessagingBlockedHosts = "nativeMessagingBlockedHosts"
        static let passwordProvider = "passwordProvider"
        static let passwordOfferAutofill = "passwordOfferAutofill"
        static let passwordOfferSave = "passwordOfferSave"
        static let passwordSubmitAutomatically = "passwordSubmitAutomatically"
        static let passwordUsesTouchID = "passwordUsesTouchID"
        static let formAutofillEnabled = "formAutofillEnabled"
        static let cardAutofillEnabled = "cardAutofillEnabled"
        static let syncEnabled = "syncEnabled"
        static let syncOpenTabs = "syncOpenTabs"
        static let syncBookmarks = "syncBookmarks"
        static let syncSiteSettings = "syncSiteSettings"
        static let syncHistory = "syncHistory"
        static let syncPasswords = "syncPasswords"
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
        static let mouseGestures = "mouseGesturesEnabled"
        static let rockerGestures = "rockerGesturesEnabled"
        static let gestureTrails = "gestureTrailsEnabled"
        static let autoRejectCookieBanners = "contentBlockingAutoRejectCookieBanners"
        static let blockHostilePageBehaviour = "contentBlockingBlockHostilePageBehaviour"
        static let clearWebsiteDataOnQuit = "clearWebsiteDataOnQuit"
        static let websiteDataQuitAllowlist = "websiteDataQuitAllowlist"
        static let autoPictureInPicture = "autoPictureInPictureOnTabSwitch"
        static let showDevelopMenu = "showDevelopMenu"
        static let linkHints = "linkHintsEnabled"
        static let vimBindings = "vimBindingsEnabled"
        static let browserLockEnabled = "browserLockEnabled"
        static let browserLockMethod = "browserLockMethod"
        static let browserLockOnLaunch = "browserLockOnLaunch"
        static let browserLockIdleTimeout = "browserLockIdleTimeout"
        static let dohProvider = "dohProvider"
        static let dohCustomURL = "dohCustomURL"
        static let proxySettings = "proxySettings"
        static let antiFingerprintingEnabled = "antiFingerprintingEnabled"
        static let canvasNoiseEnabled = "canvasNoiseEnabled"
        static let audioNoiseEnabled = "audioNoiseEnabled"
        static let hardwareMaskingEnabled = "hardwareMaskingEnabled"
        static let contextMenuSearchSelection = "contextMenuSearchSelection"
        static let contextMenuSearchSubmenu = "contextMenuSearchSubmenu"
        static let contextMenuCopyCleanLink = "contextMenuCopyCleanLink"
        static let contextMenuCaptureScreenshot = "contextMenuCaptureScreenshot"
        static let contextMenuGlanceActions = "contextMenuGlanceActions"
        static let contextMenuInspectElement = "contextMenuInspectElement"
        static let contextMenuShareMenu = "contextMenuShareMenu"
        static let contextMenuServicesMenu = "contextMenuServicesMenu"
        static let contextMenuSpeechMenu = "contextMenuSpeechMenu"
        static let contextMenuReloadPage = "contextMenuReloadPage"
        static let contextMenuPrint = "contextMenuPrint"
        static let contextMenuHiddenTitles = "contextMenuHiddenTitles"
        static let iCloudInboxEnabled = "iCloudInboxEnabled"
        static let iCloudInboxDefaultSpace = "iCloudInboxDefaultSpace"
        static let iCloudInboxTargetMode = "iCloudInboxTargetMode"
        static let iCloudInboxNotify = "iCloudInboxNotify"
        static let iCloudInboxAutoCreateSpace = "iCloudInboxAutoCreateSpace"
        static let webPanelEnabled = "webPanelEnabled"
        static let webPanelAlwaysOnTop = "webPanelAlwaysOnTop"
        static let cacheMode = "cacheMode"
        static let ramCacheCapacityMB = "ramCacheCapacityMB"
        static let clearDiskCacheOnQuit = "clearDiskCacheOnQuit"
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
            Key.sidebarMode: SidebarMode.expanded.rawValue,
            Key.sidebarPosition: SidebarPosition.leading.rawValue,
            Key.sidebarHoverDelay: SidebarHoverDelayPreset.balanced.rawValue,
            Key.sidebarDensity: SidebarDensity.regular.rawValue,
            Key.showsTabStrip: false,
            // On. The button is how most people will ever find the Task
            // Manager -- a keyboard shortcut nobody has been told about is not
            // a way in -- and the switch is there for the people who want the
            // footer back.
            Key.taskManagerInSidebar: true,
            Key.zenMode: false,
            Key.spaceSwitchWraps: true,
            Key.appearance: AppearancePreference.system.rawValue,
            Key.settingsAppearance: AppearancePreference.system.rawValue,
            Key.blocksAds: true,
            Key.blocksCookieBanners: true,
            Key.blocksTrackers: true,
            Key.newTabTarget: NewTabTarget.kylmora.rawValue,
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
            Key.clearWebsiteDataOnQuit: false,
            Key.websiteDataQuitAllowlist: [String](),
            Key.historyDisabled: false,
            Key.crashReports: CrashReportPolicy.ask.rawValue,
            Key.customUserAgent: "",
            Key.autoUpdatesFilterLists: true,
            Key.automaticallyCheckForUpdates: true,
            Key.automaticallyDownloadUpdates: false,
            Key.upgradesToHTTPS: true,
            Key.showsFullAddress: true,
            Key.showsUnicodeDomains: false,
            Key.bookmarksInNewTabs: true,
            Key.favouriteShortcuts: true,
            Key.externalLinkPresentation: ExternalLinkPresentation.tab.rawValue,
            Key.compactShowsButtons: true,
            Key.confirmsClosingPiP: true,
            Key.autoPictureInPicture: true,
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
            Key.nativeMessagingEnabled: true,
            Key.nativeMessagingUsesOtherBrowsers: true,
            Key.nativeMessagingBlockedHosts: [String](),
            Key.passwordProvider: PasswordProvider.keychain.rawValue,
            Key.passwordOfferAutofill: true,
            Key.passwordOfferSave: true,
            Key.passwordSubmitAutomatically: false,
            Key.passwordUsesTouchID: true,
            Key.formAutofillEnabled: true,
            Key.cardAutofillEnabled: true,
            Key.syncEnabled: false,
            Key.syncOpenTabs: true,
            Key.syncBookmarks: true,
            Key.syncSiteSettings: true,
            Key.syncHistory: false,
            Key.syncPasswords: false,
            Key.syncCustomDirectory: "",
            Key.syncLastTimestamp: 0.0,
            Key.syncService: SyncService.iCloud.rawValue,
            Key.syncPassphrase: "",
            Key.syncWebDAVURL: "",
            Key.syncWebDAVUsername: "",
            Key.syncWebDAVPassword: "",
            Key.userRulesText: "",
            Key.autoRejectCookieBanners: true,
            Key.blockHostilePageBehaviour: true,
            Key.showDevelopMenu: true,
            Key.mouseGestures: true,
            Key.rockerGestures: true,
            Key.gestureTrails: true,
            Key.browserLockEnabled: false,
            Key.browserLockMethod: BrowserLockMethod.touchIDOrPasscode.rawValue,
            Key.browserLockOnLaunch: true,
            Key.browserLockIdleTimeout: BrowserLockIdleTimeout.never.rawValue,
            Key.dohProvider: "off",
            Key.dohCustomURL: "",
            Key.antiFingerprintingEnabled: true,
            Key.canvasNoiseEnabled: true,
            Key.audioNoiseEnabled: true,
            Key.hardwareMaskingEnabled: true,
            Key.contextMenuSearchSelection: true,
            Key.contextMenuSearchSubmenu: true,
            Key.contextMenuCopyCleanLink: true,
            Key.contextMenuCaptureScreenshot: true,
            Key.contextMenuGlanceActions: true,
            Key.contextMenuInspectElement: true,
            Key.contextMenuShareMenu: true,
            Key.contextMenuServicesMenu: true,
            Key.contextMenuSpeechMenu: true,
            Key.contextMenuReloadPage: true,
            Key.contextMenuPrint: true,
            Key.contextMenuHiddenTitles: [String](),
            Key.iCloudInboxEnabled: true,
            Key.iCloudInboxDefaultSpace: "Read Later",
            Key.iCloudInboxTargetMode: "tab",
            Key.iCloudInboxNotify: true,
            Key.iCloudInboxAutoCreateSpace: true,
            Key.webPanelEnabled: true,
            Key.webPanelAlwaysOnTop: true,
            Key.cacheMode: CacheMode.standard.rawValue,
            Key.ramCacheCapacityMB: RAMCacheCapacity.mb128.rawValue,
            Key.clearDiskCacheOnQuit: false
        ])
    }

    var mouseGesturesEnabled: Bool {
        get { defaults.object(forKey: Key.mouseGestures) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.mouseGestures)
            NotificationCenter.default.post(name: .mouseGesturesSettingDidChange, object: nil)
        }
    }

    var rockerGesturesEnabled: Bool {
        get { defaults.object(forKey: Key.rockerGestures) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.rockerGestures)
            NotificationCenter.default.post(name: .mouseGesturesSettingDidChange, object: nil)
        }
    }

    var gestureTrailsEnabled: Bool {
        get { defaults.object(forKey: Key.gestureTrails) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.gestureTrails)
            NotificationCenter.default.post(name: .mouseGesturesSettingDidChange, object: nil)
        }
    }

    var linkHintsEnabled: Bool {
        get { defaults.object(forKey: Key.linkHints) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.linkHints)
            NotificationCenter.default.post(name: .linkHintsSettingDidChange, object: nil)
        }
    }

    var vimBindingsEnabled: Bool {
        get { defaults.object(forKey: Key.vimBindings) as? Bool ?? false }
        set {
            defaults.set(newValue, forKey: Key.vimBindings)
            NotificationCenter.default.post(name: .vimBindingsSettingDidChange, object: nil)
        }
    }

    var showDevelopMenu: Bool {
        get { defaults.object(forKey: Key.showDevelopMenu) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.showDevelopMenu)
            NotificationCenter.default.post(name: .developMenuSettingDidChange, object: nil)
        }
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

    /// Whether all website data is cleared when the application quits (preserving allow-listed sites).
    var clearWebsiteDataOnQuit: Bool {
        get { defaults.bool(forKey: Key.clearWebsiteDataOnQuit) }
        set { defaults.set(newValue, forKey: Key.clearWebsiteDataOnQuit) }
    }

    /// Domains/hosts whose data is kept when clearing on quit.
    var websiteDataQuitAllowlist: [String] {
        get { defaults.stringArray(forKey: Key.websiteDataQuitAllowlist) ?? [] }
        set { defaults.set(newValue, forKey: Key.websiteDataQuitAllowlist) }
    }

    func addToQuitAllowlist(_ host: String) {
        let norm = SiteSettingsState.normalise(host)
        guard !norm.isEmpty else { return }
        var list = websiteDataQuitAllowlist
        if !list.contains(norm) {
            list.append(norm)
            list.sort()
            websiteDataQuitAllowlist = list
        }
    }

    func removeFromQuitAllowlist(_ host: String) {
        let norm = SiteSettingsState.normalise(host)
        var list = websiteDataQuitAllowlist
        list.removeAll { $0 == norm }
        websiteDataQuitAllowlist = list
    }

    func isQuitAllowlisted(_ host: String) -> Bool {
        WebsiteData.isHostAllowed(host, in: websiteDataQuitAllowlist)
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

    var automaticallyCheckForUpdates: Bool {
        get { defaults.bool(forKey: Key.automaticallyCheckForUpdates) }
        set { defaults.set(newValue, forKey: Key.automaticallyCheckForUpdates) }
    }

    var automaticallyDownloadUpdates: Bool {
        get { defaults.bool(forKey: Key.automaticallyDownloadUpdates) }
        set { defaults.set(newValue, forKey: Key.automaticallyDownloadUpdates) }
    }

    /// The version that ran last time, so an update can say what is new.
    var lastLaunchedVersion: String? {
        get { defaults.string(forKey: Key.lastLaunchedVersion) }
        set { defaults.set(newValue, forKey: Key.lastLaunchedVersion) }
    }

    var skippedUpdateVersion: String? {
        get { defaults.string(forKey: Key.skippedUpdateVersion) }
        set { defaults.set(newValue, forKey: Key.skippedUpdateVersion) }
    }

    var lastUpdateCheckDate: Date? {
        get { defaults.object(forKey: Key.lastUpdateCheckDate) as? Date }
        set { defaults.set(newValue, forKey: Key.lastUpdateCheckDate) }
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

    /// Automatically floating playing video in a Picture-in-Picture window when switching tabs or spaces.
    var autoPictureInPicture: Bool {
        get { defaults.bool(forKey: Key.autoPictureInPicture) }
        set { defaults.set(newValue, forKey: Key.autoPictureInPicture) }
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

    /// Whether extensions may talk to programs installed on the Mac.
    ///
    /// On, because the extensions people miss most -- password managers --
    /// are useless without it. Off stops every host, running ones included.
    var nativeMessagingEnabled: Bool {
        get { defaults.bool(forKey: Key.nativeMessagingEnabled) }
        set { defaults.set(newValue, forKey: Key.nativeMessagingEnabled) }
    }

    /// Whether the hosts other browsers have installed count.
    ///
    /// Vendors write a manifest for Chrome and one for Firefox; almost none
    /// write one for Kylmora. Reading their folders is what makes 1Password
    /// and Bitwarden work on the day they are installed. The manifest still
    /// decides which extensions may reach the host, so this widens what
    /// Kylmora can see and never who may use it.
    var nativeMessagingUsesOtherBrowsers: Bool {
        get { defaults.bool(forKey: Key.nativeMessagingUsesOtherBrowsers) }
        set { defaults.set(newValue, forKey: Key.nativeMessagingUsesOtherBrowsers) }
    }

    /// Hosts the user has switched off by name.
    var nativeMessagingBlockedHosts: [String] {
        get { defaults.stringArray(forKey: Key.nativeMessagingBlockedHosts) ?? [] }
        set { defaults.set(newValue, forKey: Key.nativeMessagingBlockedHosts) }
    }

    /// Which password manager fills and saves logins: the system Keychain, or
    /// an external manager the user is pointed to install.
    var passwordProvider: PasswordProvider {
        get { PasswordProvider(rawValue: defaults.string(forKey: Key.passwordProvider) ?? "") ?? .keychain }
        set { defaults.set(newValue.rawValue, forKey: Key.passwordProvider) }
    }

    /// Names, addresses and contact details from the saved identities.
    var formAutofillEnabled: Bool {
        get { defaults.bool(forKey: Key.formAutofillEnabled) }
        set { defaults.set(newValue, forKey: Key.formAutofillEnabled) }
    }

    /// Saved payment cards, behind Touch ID when passwords are.
    var cardAutofillEnabled: Bool {
        get { defaults.bool(forKey: Key.cardAutofillEnabled) }
        set { defaults.set(newValue, forKey: Key.cardAutofillEnabled) }
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
        get {
            if let enterprise = EnterprisePolicyManager.shared.homepageURL {
                return enterprise
            }
            return defaults.string(forKey: Key.homepage).flatMap { URL(string: $0) }
        }
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
        get { NewTabTarget(rawValue: defaults.string(forKey: Key.newTabTarget) ?? "") ?? .kylmora }
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

    /// Whether hostile page behaviour (forcing text un-selectability, context menu disabling,
    /// clipboard snooping) should be neutralized.
    var blockHostilePageBehaviour: Bool {
        get { defaults.object(forKey: Key.blockHostilePageBehaviour) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.blockHostilePageBehaviour)
            NotificationCenter.default.post(name: .blockHostilePageBehaviourDidChange, object: self)
        }
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
        get {
            if let managed = EnterprisePolicyManager.shared.defaultSearchEngine {
                return engine(named: managed)
            }
            return engine(named: defaults.string(forKey: Key.searchEngine))
        }
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

    /// Current sidebar display mode.
    var sidebarMode: SidebarMode {
        get {
            if let raw = defaults.string(forKey: Key.sidebarMode),
               let mode = SidebarMode(rawValue: raw) {
                return mode
            }
            if defaults.bool(forKey: Key.compactMode) {
                return .compact
            }
            return .expanded
        }
        set {
            // Only on a real change. The window controller listens for this and
            // answers by calling `setSidebarMode`, which writes the mode back
            // here -- so a post on every write is a loop: write, notify, write,
            // notify. NotificationCenter delivers to a main-queue observer on
            // the main thread synchronously, so the loop is recursion, and
            // entering compact mode took the app down with a stack overflow
            // before it had drawn a single frame of it.
            let changed = defaults.string(forKey: Key.sidebarMode) != newValue.rawValue
            defaults.set(newValue.rawValue, forKey: Key.sidebarMode)
            defaults.set(newValue == .compact || newValue == .iconsOnly, forKey: Key.compactMode)
            guard changed else { return }
            NotificationCenter.default.post(name: .sidebarModeDidChange, object: newValue)
        }
    }

    /// How wide the sidebar rests, in points.
    ///
    /// Remembered across launches. It used to be taken from `Style.Metrics`
    /// every time a window opened, so dragging the divider lasted exactly as
    /// long as that window did.
    var sidebarWidth: CGFloat {
        get {
            let stored = defaults.double(forKey: Key.sidebarWidth)
            guard stored > 0 else { return Style.Metrics.sidebarWidth }
            // Clamped on the way out rather than only on the way in: the bounds
            // are what the split view will accept, and a value saved by an
            // older build -- or on a much wider screen -- has to land inside
            // them or the window opens with a sidebar it cannot draw.
            return min(max(stored, Style.Metrics.sidebarMinWidth), Style.Metrics.sidebarMaxWidth)
        }
        set { defaults.set(Double(newValue), forKey: Key.sidebarWidth) }
    }

    /// Whether each space keeps a sidebar width of its own.
    ///
    /// Off by default: one width, and dragging the divider in any space sets it
    /// everywhere, which is what a person expects of a window. On, a space
    /// remembers how wide you left it and switching spaces restores it -- which
    /// is worth having when one space is a list of long titles and another is
    /// six pinned tabs, and worth avoiding otherwise, because the sidebar then
    /// moves under you every time you switch.
    var sidebarWidthIsPerSpace: Bool {
        get { defaults.bool(forKey: Key.sidebarWidthPerSpace) }
        set { defaults.set(newValue, forKey: Key.sidebarWidthPerSpace) }
    }

    /// Docking position of the sidebar (Left or Right).
    var sidebarPosition: SidebarPosition {
        get {
            guard let raw = defaults.string(forKey: Key.sidebarPosition),
                  let pos = SidebarPosition(rawValue: raw) else {
                return .leading
            }
            return pos
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.sidebarPosition)
            NotificationCenter.default.post(name: .sidebarPositionDidChange, object: newValue)
        }
    }

    /// Configurable hover delay before the sidebar reveals or expands on hover.
    /// Which buttons the bar above the page shows, and their order.
    var toolbarLayout: ToolbarLayout {
        get {
            guard let data = defaults.data(forKey: Key.toolbarLayout),
                  let layout = try? JSONDecoder().decode(ToolbarLayout.self, from: data) else { return .default }
            return layout
        }
        set {
            guard newValue != toolbarLayout else { return }
            if newValue.isDefault {
                defaults.removeObject(forKey: Key.toolbarLayout)
            } else if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.toolbarLayout)
            }
            NotificationCenter.default.post(name: .toolbarLayoutDidChange, object: nil)
        }
    }

    /// A horizontal row of tabs above the page, beside or instead of the
    /// sidebar's list.
    var showsTabStrip: Bool {
        get { defaults.bool(forKey: Key.showsTabStrip) }
        set {
            guard newValue != showsTabStrip else { return }
            defaults.set(newValue, forKey: Key.showsTabStrip)
            NotificationCenter.default.post(name: .tabStripDidChange, object: nil)
        }
    }

    /// Whether the sidebar's footer carries the Task Manager button.
    ///
    /// Switching it off does not take the Task Manager away: it stays on the
    /// Window menu, on Shift-Command-U, and on its own pane in Settings, which
    /// is where the switch is. A control that could hide the only way back to
    /// itself would be a trap.
    var showsTaskManagerInSidebar: Bool {
        get { defaults.bool(forKey: Key.taskManagerInSidebar) }
        set {
            guard newValue != showsTaskManagerInSidebar else { return }
            defaults.set(newValue, forKey: Key.taskManagerInSidebar)
            NotificationCenter.default.post(name: .taskManagerButtonDidChange, object: nil)
        }
    }

    /// How tall the sidebar's rows are. Changing it rebuilds the rows.
    var sidebarDensity: SidebarDensity {
        get { SidebarDensity(rawValue: defaults.string(forKey: Key.sidebarDensity) ?? "") ?? .regular }
        set {
            guard newValue != sidebarDensity else { return }
            defaults.set(newValue.rawValue, forKey: Key.sidebarDensity)
            NotificationCenter.default.post(name: .sidebarDensityDidChange, object: nil)
        }
    }

    var sidebarHoverDelay: Double {
        get {
            // A preset, so the pop-up that shows it can say what it is. The
            // default used to be 200 ms, which is not one of the four the
            // pop-up offers: it read as "Balanced (250 ms)", and the first
            // switch anyone touched on that pane made it 250 ms for real.
            guard defaults.object(forKey: Key.sidebarHoverDelay) != nil else {
                return SidebarHoverDelayPreset.balanced.rawValue
            }
            return defaults.double(forKey: Key.sidebarHoverDelay)
        }
        set {
            defaults.set(newValue, forKey: Key.sidebarHoverDelay)
            NotificationCenter.default.post(name: .sidebarHoverDelayDidChange, object: newValue)
        }
    }

    /// Zen Mode (Hide all UI).
    var zenModeEnabled: Bool {
        get { defaults.bool(forKey: Key.zenMode) }
        set {
            defaults.set(newValue, forKey: Key.zenMode)
            NotificationCenter.default.post(name: .zenModeDidChange, object: newValue)
        }
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
            configuration.sidebarEdge = sidebarPosition == .trailing ? .trailing : .leading
            configuration.iconsOnlyCollapsed = (sidebarMode == .iconsOnly)
            configuration.hoverDebounce = sidebarHoverDelay
            configuration.reducesMotion = NSWorkspace.shared
                .accessibilityDisplayShouldReduceMotion
            return configuration
        }
        set {
            defaults.set(newValue.hidesToolbar, forKey: Key.compactHidesToolbar)
            defaults.set(newValue.revealsOnHover, forKey: Key.compactRevealsOnHover)
            defaults.set(newValue.sidebarEdge == .trailing ? SidebarPosition.trailing.rawValue : SidebarPosition.leading.rawValue, forKey: Key.sidebarPosition)
            defaults.set(newValue.hoverDebounce, forKey: Key.sidebarHoverDelay)
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

    /// The Settings window's own appearance, apart from the application's.
    ///
    /// Each space picks light or dark for its window; the Settings window is
    /// nobody's space, so it gets a choice of its own. Automatic follows the
    /// application, which in turn follows the Mac.
    var settingsWindowAppearance: AppearancePreference {
        get { AppearancePreference(storedValue: defaults.string(forKey: Key.settingsAppearance)) }
        set { defaults.set(newValue.rawValue, forKey: Key.settingsAppearance) }
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
        switch newTabTarget {
        case .kylmora: return StartPage.url
        case .homepage: return homepageURL ?? StartPage.url
        case .startPage: return searchEngine(isPrivate: isPrivate).homeURL
        }
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

    /// Recent history travels with the archive. Off by default: where you
    /// have been is the most personal thing the browser knows.
    var syncHistory: Bool {
        get { defaults.bool(forKey: Key.syncHistory) }
        set { defaults.set(newValue, forKey: Key.syncHistory) }
    }

    /// Saved logins travel too, and only inside an archive encrypted with the
    /// passphrase; with no passphrase the switch does nothing.
    var syncPasswords: Bool {
        get { defaults.bool(forKey: Key.syncPasswords) }
        set { defaults.set(newValue, forKey: Key.syncPasswords) }
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

    var browserLockEnabled: Bool {
        get { defaults.bool(forKey: Key.browserLockEnabled) }
        set {
            defaults.set(newValue, forKey: Key.browserLockEnabled)
            NotificationCenter.default.post(name: .browserLockSettingsDidChange, object: nil)
        }
    }

    var browserLockMethod: BrowserLockMethod {
        get {
            guard let raw = defaults.string(forKey: Key.browserLockMethod),
                  let method = BrowserLockMethod(rawValue: raw) else {
                return .touchIDOrPasscode
            }
            return method
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.browserLockMethod)
            NotificationCenter.default.post(name: .browserLockSettingsDidChange, object: nil)
        }
    }

    var browserLockOnLaunch: Bool {
        get { defaults.bool(forKey: Key.browserLockOnLaunch) }
        set {
            defaults.set(newValue, forKey: Key.browserLockOnLaunch)
            NotificationCenter.default.post(name: .browserLockSettingsDidChange, object: nil)
        }
    }

    var browserLockIdleTimeout: BrowserLockIdleTimeout {
        get {
            let seconds = defaults.integer(forKey: Key.browserLockIdleTimeout)
            return BrowserLockIdleTimeout(rawValue: seconds) ?? .never
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.browserLockIdleTimeout)
            NotificationCenter.default.post(name: .browserLockSettingsDidChange, object: nil)
        }
    }

    var dohProvider: DoHProvider {
        get {
            if let enterpriseDoH = EnterprisePolicyManager.shared.dohURL {
                return .custom(url: enterpriseDoH.absoluteString)
            }
            let key = defaults.string(forKey: Key.dohProvider) ?? "off"
            let customURL = defaults.string(forKey: Key.dohCustomURL) ?? ""
            return DoHProvider.from(key: key, customURL: customURL)
        }
        set {
            defaults.set(newValue.key, forKey: Key.dohProvider)
            if case .custom(let url) = newValue {
                defaults.set(url, forKey: Key.dohCustomURL)
            }
            NotificationCenter.default.post(name: .dohSettingDidChange, object: nil)
        }
    }

    var dohCustomURL: String {
        get { defaults.string(forKey: Key.dohCustomURL) ?? "" }
        set {
            defaults.set(newValue, forKey: Key.dohCustomURL)
            if dohProvider.key == "custom" {
                NotificationCenter.default.post(name: .dohSettingDidChange, object: nil)
            }
        }
    }

    var proxySettings: ProxySettings {
        get {
            guard let data = defaults.data(forKey: Key.proxySettings),
                  let settings = try? JSONDecoder().decode(ProxySettings.self, from: data) else {
                return ProxySettings()
            }
            return settings
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.proxySettings)
            }
            NetworkConfigManager.shared.applyToAllStores()
            NotificationCenter.default.post(name: .proxySettingDidChange, object: nil)
        }
    }

    var antiFingerprintingEnabled: Bool {
        get { defaults.object(forKey: Key.antiFingerprintingEnabled) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.antiFingerprintingEnabled)
            NotificationCenter.default.post(name: .antiFingerprintingSettingDidChange, object: nil)
        }
    }

    var canvasNoiseEnabled: Bool {
        get { defaults.object(forKey: Key.canvasNoiseEnabled) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.canvasNoiseEnabled)
            NotificationCenter.default.post(name: .antiFingerprintingSettingDidChange, object: nil)
        }
    }

    var audioNoiseEnabled: Bool {
        get { defaults.object(forKey: Key.audioNoiseEnabled) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.audioNoiseEnabled)
            NotificationCenter.default.post(name: .antiFingerprintingSettingDidChange, object: nil)
        }
    }

    var hardwareMaskingEnabled: Bool {
        get { defaults.object(forKey: Key.hardwareMaskingEnabled) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.hardwareMaskingEnabled)
            NotificationCenter.default.post(name: .antiFingerprintingSettingDidChange, object: nil)
        }
    }

    var contextMenuSearchSelection: Bool {
        get { defaults.object(forKey: Key.contextMenuSearchSelection) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.contextMenuSearchSelection)
            NotificationCenter.default.post(name: .contextMenuSettingsDidChange, object: nil)
        }
    }

    var contextMenuSearchSubmenu: Bool {
        get { defaults.object(forKey: Key.contextMenuSearchSubmenu) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.contextMenuSearchSubmenu)
            NotificationCenter.default.post(name: .contextMenuSettingsDidChange, object: nil)
        }
    }

    var contextMenuCopyCleanLink: Bool {
        get { defaults.object(forKey: Key.contextMenuCopyCleanLink) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.contextMenuCopyCleanLink)
            NotificationCenter.default.post(name: .contextMenuSettingsDidChange, object: nil)
        }
    }

    var contextMenuCaptureScreenshot: Bool {
        get { defaults.object(forKey: Key.contextMenuCaptureScreenshot) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.contextMenuCaptureScreenshot)
            NotificationCenter.default.post(name: .contextMenuSettingsDidChange, object: nil)
        }
    }

    var contextMenuGlanceActions: Bool {
        get { defaults.object(forKey: Key.contextMenuGlanceActions) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.contextMenuGlanceActions)
            NotificationCenter.default.post(name: .contextMenuSettingsDidChange, object: nil)
        }
    }

    var contextMenuInspectElement: Bool {
        get { defaults.object(forKey: Key.contextMenuInspectElement) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.contextMenuInspectElement)
            NotificationCenter.default.post(name: .contextMenuSettingsDidChange, object: nil)
        }
    }

    var contextMenuShareMenu: Bool {
        get { defaults.object(forKey: Key.contextMenuShareMenu) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.contextMenuShareMenu)
            NotificationCenter.default.post(name: .contextMenuSettingsDidChange, object: nil)
        }
    }

    var contextMenuServicesMenu: Bool {
        get { defaults.object(forKey: Key.contextMenuServicesMenu) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.contextMenuServicesMenu)
            NotificationCenter.default.post(name: .contextMenuSettingsDidChange, object: nil)
        }
    }

    var contextMenuSpeechMenu: Bool {
        get { defaults.object(forKey: Key.contextMenuSpeechMenu) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.contextMenuSpeechMenu)
            NotificationCenter.default.post(name: .contextMenuSettingsDidChange, object: nil)
        }
    }

    var contextMenuReloadPage: Bool {
        get { defaults.object(forKey: Key.contextMenuReloadPage) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.contextMenuReloadPage)
            NotificationCenter.default.post(name: .contextMenuSettingsDidChange, object: nil)
        }
    }

    var contextMenuPrint: Bool {
        get { defaults.object(forKey: Key.contextMenuPrint) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.contextMenuPrint)
            NotificationCenter.default.post(name: .contextMenuSettingsDidChange, object: nil)
        }
    }

    var contextMenuHiddenTitles: [String] {
        get { defaults.stringArray(forKey: Key.contextMenuHiddenTitles) ?? [] }
        set {
            defaults.set(newValue, forKey: Key.contextMenuHiddenTitles)
            NotificationCenter.default.post(name: .contextMenuSettingsDidChange, object: nil)
        }
    }

    // MARK: - iPhone Companion / iCloud Inbox (F-35)

    var iCloudInboxEnabled: Bool {
        get { defaults.object(forKey: Key.iCloudInboxEnabled) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.iCloudInboxEnabled)
            NotificationCenter.default.post(name: .iCloudInboxSettingsDidChange, object: nil)
        }
    }

    var iCloudInboxDefaultSpace: String {
        get { defaults.string(forKey: Key.iCloudInboxDefaultSpace) ?? "Read Later" }
        set {
            defaults.set(newValue, forKey: Key.iCloudInboxDefaultSpace)
            NotificationCenter.default.post(name: .iCloudInboxSettingsDidChange, object: nil)
        }
    }

    var iCloudInboxTargetMode: String {
        get { defaults.string(forKey: Key.iCloudInboxTargetMode) ?? "tab" }
        set {
            defaults.set(newValue, forKey: Key.iCloudInboxTargetMode)
            NotificationCenter.default.post(name: .iCloudInboxSettingsDidChange, object: nil)
        }
    }

    var iCloudInboxNotify: Bool {
        get { defaults.object(forKey: Key.iCloudInboxNotify) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.iCloudInboxNotify)
            NotificationCenter.default.post(name: .iCloudInboxSettingsDidChange, object: nil)
        }
    }

    var iCloudInboxAutoCreateSpace: Bool {
        get { defaults.object(forKey: Key.iCloudInboxAutoCreateSpace) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.iCloudInboxAutoCreateSpace)
            NotificationCenter.default.post(name: .iCloudInboxSettingsDidChange, object: nil)
        }
    }

    var webPanelEnabled: Bool {
        get { defaults.object(forKey: Key.webPanelEnabled) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.webPanelEnabled)
            NotificationCenter.default.post(name: .webPanelSettingsDidChange, object: nil)
        }
    }

    var webPanelAlwaysOnTop: Bool {
        get { defaults.object(forKey: Key.webPanelAlwaysOnTop) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.webPanelAlwaysOnTop)
            NotificationCenter.default.post(name: .webPanelSettingsDidChange, object: nil)
        }
    }

    var cacheMode: CacheMode {
        get {
            if EnterprisePolicyManager.shared.isRAMCacheOnlyForced {
                return .ramOnly
            }
            guard let raw = defaults.string(forKey: Key.cacheMode),
                  let mode = CacheMode(rawValue: raw) else {
                return .standard
            }
            return mode
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.cacheMode)
            RAMCacheManager.shared.applyCacheConfiguration()
        }
    }

    var ramCacheCapacityMB: Int {
        get {
            let val = defaults.integer(forKey: Key.ramCacheCapacityMB)
            return val > 0 ? val : RAMCacheCapacity.mb128.rawValue
        }
        set {
            defaults.set(newValue, forKey: Key.ramCacheCapacityMB)
            RAMCacheManager.shared.applyCacheConfiguration()
        }
    }

    var clearDiskCacheOnQuit: Bool {
        get { defaults.bool(forKey: Key.clearDiskCacheOnQuit) }
        set { defaults.set(newValue, forKey: Key.clearDiskCacheOnQuit) }
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

extension Notification.Name {
    static let developMenuSettingDidChange = Notification.Name("developMenuSettingDidChange")
    static let taskManagerButtonDidChange = Notification.Name("taskManagerButtonDidChange")
    static let mouseGesturesSettingDidChange = Notification.Name("mouseGesturesSettingDidChange")
    static let linkHintsSettingDidChange = Notification.Name("linkHintsSettingDidChange")
    static let vimBindingsSettingDidChange = Notification.Name("vimBindingsSettingDidChange")
    static let browserLockSettingsDidChange = Notification.Name("browserLockSettingsDidChange")
    static let browserLockStateDidChange = Notification.Name("browserLockStateDidChange")
    static let dohSettingDidChange = Notification.Name("dohSettingDidChange")
    static let proxySettingDidChange = Notification.Name("proxySettingDidChange")
    static let antiFingerprintingSettingDidChange = Notification.Name("antiFingerprintingSettingDidChange")
    static let contextMenuSettingsDidChange = Notification.Name("contextMenuSettingsDidChange")
    static let blockHostilePageBehaviourDidChange = Notification.Name("blockHostilePageBehaviourDidChange")
    static let iCloudInboxSettingsDidChange = Notification.Name("iCloudInboxSettingsDidChange")
    static let webPanelSettingsDidChange = Notification.Name("webPanelSettingsDidChange")
}

