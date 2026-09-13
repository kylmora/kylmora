import AppKit
import Foundation

/// One kind of per-website setting: what it is called, what it can be, and
/// what it is unless a site says otherwise.
///
/// Only settings WebKit lets an embedding browser honour are here. Reader
/// mode, notifications, camera, microphone, location, tracking prevention
/// and picture-in-picture are on the screen this was modelled on and not
/// here, because Kylmora has no reader, and the rest are either not exposed by
/// WebKit's public API or need entitlements Kylmora does not hold.
enum SiteSettingCategory: String, CaseIterable, Codable, Sendable {
    case readerMode
    case autoPlay
    case pageZoom
    case popups
    case notifications
    case downloads
    case camera
    case microphone
    case screenSharing
    case location
    case contentBlockers
    case trackingPrevention
    case cookies
    case javaScript
    case webFonts
    case sslCheck
    case userAgent
    case compatibilityMode
    case externalApps
    case pictureInPicture
    case tabSuspension

    struct Option: Equatable, Sendable, Identifiable {
        let id: String
        let title: String
    }

    var title: String {
        switch self {
        case .readerMode: return "Reader Mode"
        case .autoPlay: return "Auto-Play"
        case .pageZoom: return "Page Zoom"
        case .popups: return "Pop-up Windows"
        case .notifications: return "Notifications"
        case .downloads: return "Downloads"
        case .camera: return "Camera"
        case .microphone: return "Microphone"
        case .screenSharing: return "Screen Sharing"
        case .location: return "Location"
        case .contentBlockers: return "Content Blockers"
        case .trackingPrevention: return "Tracking Prevention"
        case .cookies: return "Cookies"
        case .javaScript: return "JavaScript"
        case .webFonts: return "Web Fonts"
        case .sslCheck: return "SSL Certificate Check"
        case .userAgent: return "User Agent"
        case .compatibilityMode: return "Compatibility Mode"
        case .externalApps: return "External Apps"
        case .pictureInPicture: return "Picture in Picture"
        case .tabSuspension: return "Tab Sleeping & Archiving"
        }
    }

    var symbolName: String {
        switch self {
        case .readerMode: return "doc.plaintext.fill"
        case .autoPlay: return "play.fill"
        case .pageZoom: return "plus.magnifyingglass"
        case .popups: return "macwindow.on.rectangle"
        case .notifications: return "bell.badge.fill"
        case .downloads: return "arrow.down.circle.fill"
        case .camera: return "video.fill"
        case .microphone: return "mic.fill"
        case .screenSharing: return "desktopcomputer"
        case .location: return "location.fill"
        case .contentBlockers: return "checkmark.shield.fill"
        case .trackingPrevention: return "hand.raised.fill"
        case .cookies: return "circle.grid.3x3.fill"
        case .javaScript: return "curlybraces"
        case .webFonts: return "textformat"
        case .sslCheck: return "checkmark.seal.fill"
        case .userAgent: return "safari.fill"
        case .compatibilityMode: return "iphone.and.arrow.forward"
        case .externalApps: return "arrow.up.forward.app.fill"
        case .pictureInPicture: return "pip.fill"
        case .tabSuspension: return "moon.stars.fill"
        }
    }

    var tileColour: NSColor {
        switch self {
        case .readerMode, .popups, .camera, .microphone, .notifications, .webFonts, .pictureInPicture: return .systemGray
        case .autoPlay, .pageZoom: return .systemOrange
        case .downloads, .sslCheck: return .systemIndigo
        case .screenSharing, .location, .userAgent, .externalApps: return .systemBlue
        case .contentBlockers, .trackingPrevention: return .systemGreen
        case .cookies: return .systemBrown
        case .javaScript: return .systemYellow
        case .compatibilityMode: return .systemTeal
        case .tabSuspension: return .systemPurple
        }
    }

    /// The line above the configured-websites table.
    var instruction: String {
        switch self {
        case .readerMode: return "Automatically use Reader Mode on the websites below:"
        case .autoPlay: return "Allow or stop auto-play on the websites below:"
        case .pageZoom: return "Use a different zoom on the websites below:"
        case .popups: return "Allow or block pop-up windows on the websites below:"
        case .notifications: return "Allow or deny notifications from the websites below:"
        case .downloads: return "Allow or deny downloads from the websites below:"
        case .camera: return "Allow or deny camera access on the websites below:"
        case .microphone: return "Allow or deny microphone access on the websites below:"
        case .screenSharing: return "Allow or deny screen sharing on the websites below:"
        case .location: return "Allow or deny location access on the websites below:"
        case .contentBlockers: return "Turn content blockers on or off on the websites below:"
        case .trackingPrevention: return "Choose how strictly tracking is prevented on the websites below:"
        case .cookies: return "Allow or block cookies on the websites below:"
        case .javaScript: return "Turn JavaScript on or off on the websites below:"
        case .webFonts: return "Allow or block web fonts on the websites below:"
        case .sslCheck: return "Check or ignore certificate problems on the websites below:"
        case .userAgent: return "Identify as another browser on the websites below:"
        case .compatibilityMode: return "Ask for the desktop or mobile site on the websites below:"
        case .externalApps: return "Allow or deny opening other apps from the websites below:"
        case .pictureInPicture: return "Allow or deny picture in picture on the websites below:"
        case .tabSuspension: return "Allow or prevent tab sleeping and auto-archiving on the websites below:"
        }
    }

    private static let askAllowDeny = [
        Option(id: "ask", title: "Ask"), Option(id: "allow", title: "Allow"), Option(id: "deny", title: "Deny")
    ]

    var options: [Option] {
        switch self {
        case .readerMode: return [Option(id: "off", title: "Off"), Option(id: "on", title: "On")]
        case .autoPlay:
            return [
                Option(id: "allow", title: "Allow All Auto-Play"),
                Option(id: "stopSound", title: "Stop Media with Sound"),
                Option(id: "never", title: "Never Auto-Play")
            ]
        case .pageZoom:
            return ["0.5", "0.75", "0.85", "1", "1.15", "1.25", "1.5", "1.75", "2", "2.5", "3"].map {
                Option(id: $0, title: "\(Int((Double($0)! * 100).rounded()))%")
            }
        case .popups: return [Option(id: "allow", title: "Allow"), Option(id: "block", title: "Block")]
        case .notifications, .camera, .microphone, .screenSharing, .location, .externalApps: return Self.askAllowDeny
        case .downloads: return [Option(id: "allow", title: "Allow"), Option(id: "deny", title: "Deny")]
        case .contentBlockers: return [Option(id: "on", title: "On"), Option(id: "off", title: "Off")]
        case .trackingPrevention: return [Option(id: "standard", title: "Standard"), Option(id: "strict", title: "Strict")]
        case .cookies: return [Option(id: "allow", title: "Allow"), Option(id: "block", title: "Block")]
        case .javaScript: return [Option(id: "on", title: "On"), Option(id: "off", title: "Off")]
        case .webFonts: return [Option(id: "allow", title: "Allow"), Option(id: "block", title: "Block")]
        case .sslCheck: return [Option(id: "on", title: "On"), Option(id: "off", title: "Off")]
        case .userAgent:
            return [
                Option(id: "default", title: "Default"), Option(id: "safari", title: "Safari"),
                Option(id: "chrome", title: "Chrome"), Option(id: "firefox", title: "Firefox"),
                Option(id: "custom", title: "Custom")
            ]
        case .compatibilityMode: return [Option(id: "desktop", title: "Desktop"), Option(id: "mobile", title: "Mobile")]
        case .pictureInPicture: return [Option(id: "allow", title: "Allow"), Option(id: "deny", title: "Deny")]
        case .tabSuspension:
            return [
                Option(id: "allow", title: "Allow Sleeping & Archiving"),
                Option(id: "never", title: "Never Sleep or Archive (Keep Awake)")
            ]
        }
    }

    /// What every site gets until the user changes the default.
    var builtInDefault: String {
        switch self {
        case .readerMode: return "off"
        case .autoPlay: return "allow"
        case .pageZoom: return "1"
        case .popups: return "allow"
        case .notifications, .camera, .microphone, .screenSharing, .location, .externalApps: return "ask"
        case .downloads: return "allow"
        case .contentBlockers: return "on"
        case .trackingPrevention: return "standard"
        case .cookies: return "allow"
        case .javaScript: return "on"
        case .webFonts: return "allow"
        case .sslCheck: return "on"
        case .userAgent: return "default"
        case .compatibilityMode: return "desktop"
        case .pictureInPicture: return "allow"
        case .tabSuspension: return "allow"
        }
    }

    func option(_ id: String) -> Option? { options.first { $0.id == id } }
}

/// Everything the user has decided per website, and the defaults.
///
/// Sites are stored by host. A setting for `example.com` covers
/// `www.example.com` and every other subdomain; one for `www.example.com`
/// covers only that. Matching prefers the longest host that applies, so a
/// subdomain can be set differently from its parent.
struct SiteSettingsState: Codable, Equatable, Sendable {
    var defaults: [SiteSettingCategory: String] = [:]
    var sites: [SiteSettingCategory: [String: String]] = [:]

    func defaultOption(for category: SiteSettingCategory) -> String {
        defaults[category] ?? category.builtInDefault
    }

    /// The hosts configured for a category, sorted.
    func configuredHosts(for category: SiteSettingCategory) -> [String] {
        (sites[category] ?? [:]).keys.sorted()
    }

    func option(for category: SiteSettingCategory, host: String) -> String? {
        sites[category]?[Self.normalise(host)]
    }

    /// The option that applies to this URL: the most specific configured
    /// host, else the default.
    func resolve(_ category: SiteSettingCategory, for url: URL?) -> String {
        guard let host = url?.host()?.lowercased(), let configured = sites[category], !configured.isEmpty else {
            return defaultOption(for: category)
        }
        var best: (host: String, option: String)?
        for (entry, option) in configured where host == entry || host.hasSuffix("." + entry) {
            if best == nil || entry.count > best!.host.count { best = (entry, option) }
        }
        return best?.option ?? defaultOption(for: category)
    }

    mutating func setDefault(_ option: String, for category: SiteSettingCategory) {
        defaults[category] = option == category.builtInDefault ? nil : option
    }

    mutating func set(_ option: String, for host: String, in category: SiteSettingCategory) {
        let host = Self.normalise(host)
        guard !host.isEmpty else { return }
        sites[category, default: [:]][host] = option
    }

    mutating func remove(_ host: String, from category: SiteSettingCategory) {
        sites[category]?[Self.normalise(host)] = nil
        if sites[category]?.isEmpty == true { sites[category] = nil }
    }

    /// Lower-cased, without a scheme, path or leading "www." the user pasted
    /// along with the host.
    static func normalise(_ text: String) -> String {
        var host = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let url = URL(string: host), let parsed = url.host() { host = parsed }
        if let slash = host.firstIndex(of: "/") { host = String(host[..<slash]) }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }
}

/// The per-website settings, on disk and applied.
@MainActor
final class SiteSettings {
    static let shared = SiteSettings()

    static func normalise(_ text: String) -> String {
        SiteSettingsState.normalise(text)
    }

    private(set) var state: SiteSettingsState
    private let file: URL
    private let settings: Settings
    /// Called on every change so panes redraw and rule lists recompile.
    ///
    /// A list rather than a single closure because more than one party cares:
    /// the content blocker recompiles its rules, and an open Websites pane
    /// redraws. As a single `var` whichever registered last silently replaced
    /// the other -- the Websites pane's `loadView` used to clobber the content
    /// blocker's hook, so per-site cookie/font/tracking rules went stale until
    /// the next launch.
    private var changeObservers: [() -> Void] = []

    /// Registers a handler for every future change. Handlers are never removed:
    /// the callers (the content blocker and the cached Websites pane) both live
    /// for the app's lifetime.
    func addChangeObserver(_ observer: @escaping () -> Void) {
        changeObservers.append(observer)
    }

    init(file: URL = AppPaths.supportDirectory.appending(path: "site-settings.json"), settings: Settings = .shared) {
        self.file = file
        self.settings = settings
        if let data = try? Data(contentsOf: file), let loaded = try? JSONDecoder().decode(SiteSettingsState.self, from: data) {
            state = loaded
        } else {
            state = SiteSettingsState()
        }
    }

    func resolve(_ category: SiteSettingCategory, for url: URL?) -> String {
        state.resolve(category, for: url)
    }

    func update(_ change: (inout SiteSettingsState) -> Void) {
        var next = state
        change(&next)
        guard next != state else { return }
        state = next
        AppPaths.ensureSupportDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(state).write(to: file, options: .atomic)
        for observer in changeObservers { observer() }
    }

    // MARK: - Applying

    /// The user-agent string a site is shown, or nil for WebKit's own.
    func userAgent(for url: URL?) -> String? {
        switch resolve(.userAgent, for: url) {
        case "safari":
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15"
        case "chrome":
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
        case "firefox":
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 14.6; rv:131.0) Gecko/20100101 Firefox/131.0"
        case "custom":
            // The string on the Privacy pane; empty leaves WebKit's own.
            return settings.customUserAgent
        default:
            return nil
        }
    }

    func pageZoom(for url: URL?) -> CGFloat {
        CGFloat(Double(resolve(.pageZoom, for: url)) ?? 1)
    }

    /// Ask, allow or deny, for the settings that have all three.
    enum Permission: String { case ask, allow, deny }

    func permission(_ category: SiteSettingCategory, for url: URL?) -> Permission {
        Permission(rawValue: resolve(category, for: url)) ?? .ask
    }

    func checksCertificates(for url: URL?) -> Bool { resolve(.sslCheck, for: url) == "on" }

    /// The values the page-side scripts read (`SitePolicy`).
    func policy(for url: URL?) -> [String: String] {
        [
            "readerMode": resolve(.readerMode, for: url),
            "autoPlay": resolve(.autoPlay, for: url),
            "notifications": resolve(.notifications, for: url),
            "location": resolve(.location, for: url),
            "screenSharing": resolve(.screenSharing, for: url),
            "pictureInPicture": resolve(.pictureInPicture, for: url)
        ]
    }

    func allowsPopups(for url: URL?) -> Bool { resolve(.popups, for: url) == "allow" }
    func allowsDownloads(for url: URL?) -> Bool { resolve(.downloads, for: url) == "allow" }
    func blocksContent(for url: URL?) -> Bool { resolve(.contentBlockers, for: url) == "on" }
    func allowsJavaScript(for url: URL?) -> Bool { resolve(.javaScript, for: url) == "on" }
    func prefersMobile(for url: URL?) -> Bool { resolve(.compatibilityMode, for: url) == "mobile" }
    func allowsSuspension(for url: URL?) -> Bool { resolve(.tabSuspension, for: url) != "never" }

    /// The content rules the per-site cookie and font choices become: a
    /// small rule list compiled beside the filter lists.
    func siteRules() -> [[String: Any]] {
        var rules: [[String: Any]] = []
        func domainTrigger(_ hosts: [String], extra: [String: Any] = [:]) -> [String: Any] {
            var trigger: [String: Any] = ["url-filter": ".*", "if-domain": hosts.map { "*" + $0 }]
            for (key, value) in extra { trigger[key] = value }
            return trigger
        }
        let cookieHosts = state.sites[.cookies]?.filter { $0.value == "block" }.map(\.key).sorted() ?? []
        if state.defaultOption(for: .cookies) == "block" {
            let allowed = state.sites[.cookies]?.filter { $0.value == "allow" }.map(\.key).sorted() ?? []
            var trigger: [String: Any] = ["url-filter": ".*"]
            if !allowed.isEmpty { trigger["unless-domain"] = allowed.map { "*" + $0 } }
            rules.append(["trigger": trigger, "action": ["type": "block-cookies"]])
        } else if !cookieHosts.isEmpty {
            rules.append(["trigger": domainTrigger(cookieHosts), "action": ["type": "block-cookies"]])
        }
        // Strict tracking prevention: no third-party cookies on the site's
        // pages, on top of WebKit's own tracking prevention, which is always on.
        let strictHosts = state.sites[.trackingPrevention]?.filter { $0.value == "strict" }.map(\.key).sorted() ?? []
        if state.defaultOption(for: .trackingPrevention) == "strict" {
            let standard = state.sites[.trackingPrevention]?.filter { $0.value == "standard" }.map(\.key).sorted() ?? []
            var trigger: [String: Any] = ["url-filter": ".*", "load-type": ["third-party"]]
            if !standard.isEmpty { trigger["unless-domain"] = standard.map { "*" + $0 } }
            rules.append(["trigger": trigger, "action": ["type": "block-cookies"]])
        } else if !strictHosts.isEmpty {
            rules.append(["trigger": domainTrigger(strictHosts, extra: ["load-type": ["third-party"]]), "action": ["type": "block-cookies"]])
        }
        let fontHosts = state.sites[.webFonts]?.filter { $0.value == "block" }.map(\.key).sorted() ?? []
        if state.defaultOption(for: .webFonts) == "block" {
            let allowed = state.sites[.webFonts]?.filter { $0.value == "allow" }.map(\.key).sorted() ?? []
            var trigger: [String: Any] = ["url-filter": ".*", "resource-type": ["font"]]
            if !allowed.isEmpty { trigger["unless-domain"] = allowed.map { "*" + $0 } }
            rules.append(["trigger": trigger, "action": ["type": "block"]])
        } else if !fontHosts.isEmpty {
            rules.append(["trigger": domainTrigger(fontHosts, extra: ["resource-type": ["font"]]), "action": ["type": "block"]])
        }
        return rules
    }
}
