import AppKit

/// Everything about how the window looks and behaves that a space decides
/// for itself, beyond its colour (`SpaceTheme`) and its rim (`WindowBorder`).
///
/// Orion keeps these on its Appearance pane, one setting for the whole app.
/// Here each space has its own: a work space can be light with a bookmarks
/// bar and a serif font, a personal one dark with neither, and switching
/// space switches all of it. Everything here has a default that leaves the
/// window as it was before the setting existed.
struct SpaceLook: Codable, Hashable, Sendable {
    /// Light, dark, or whatever the General pane says.
    var appearance: AppearancePreference = .system
    /// The colour behind the wash when the theme is `.custom`. Kept as a hex
    /// string so the struct stays a plain value; `customColor` is the view.
    var customColorHex: String?
    /// A gradient wash, chosen when the space was made or from its settings.
    /// When set it supersedes the solid theme colour: the chrome is washed with
    /// the gradient rather than one flat hue. Nil is the plain solid wash.
    var gradient: SpaceGradient?
    /// How strongly the space's own colour washes the chrome, 0...1. 1 is the
    /// standard wash; lower fades the tint towards the plain material, so a
    /// customised space can be as faint as the user likes. Applies to both the
    /// solid and gradient wash; presets and website-colour ignore it.
    var washOpacity: Double = 1
    /// A page's `theme-color` takes over the wash while it is in front.
    var allowsWebsiteThemeColor = false
    /// In macOS full screen, the bar above the page stays. Off, it hides and
    /// comes back on a hover at the top.
    var alwaysShowsToolbarInFullScreen = true
    /// In macOS full screen, the sidebar hides and comes back on a hover at
    /// its edge. Off, it stays where it is.
    var autoShowsSidebarInFullScreen = true
    /// In macOS full screen, the chrome stops showing the desktop through it.
    var isOpaqueInFullScreen = true
    var showsBookmarksBar = false
    var bookmarksBarStyle: BookmarksBarStyle = .iconAndText
    var fonts: WebFonts = .webKitDefaults

    init() {}

    var customColor: NSColor? {
        get { customColorHex.flatMap(NSColor.init(hexString:)) }
        set { customColorHex = newValue?.hexString }
    }

    // MARK: - Tolerant decoding

    /// Each field falls back on its own, so a session from a build with more
    /// or fewer of them still restores.
    private enum CodingKeys: String, CodingKey {
        case appearance, customColorHex, gradient, washOpacity, allowsWebsiteThemeColor
        case alwaysShowsToolbarInFullScreen, autoShowsSidebarInFullScreen, isOpaqueInFullScreen
        case showsBookmarksBar, bookmarksBarStyle, fonts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = SpaceLook()
        appearance = AppearancePreference(storedValue: try? container.decodeIfPresent(String.self, forKey: .appearance))
        customColorHex = try? container.decodeIfPresent(String.self, forKey: .customColorHex)
        gradient = try? container.decodeIfPresent(SpaceGradient.self, forKey: .gradient)
        washOpacity = (try? container.decodeIfPresent(Double.self, forKey: .washOpacity)).flatMap { $0 }.map { min(max($0, 0), 1) } ?? fallback.washOpacity
        allowsWebsiteThemeColor = (try? container.decodeIfPresent(Bool.self, forKey: .allowsWebsiteThemeColor)) ?? fallback.allowsWebsiteThemeColor
        alwaysShowsToolbarInFullScreen = (try? container.decodeIfPresent(Bool.self, forKey: .alwaysShowsToolbarInFullScreen)) ?? fallback.alwaysShowsToolbarInFullScreen
        autoShowsSidebarInFullScreen = (try? container.decodeIfPresent(Bool.self, forKey: .autoShowsSidebarInFullScreen)) ?? fallback.autoShowsSidebarInFullScreen
        isOpaqueInFullScreen = (try? container.decodeIfPresent(Bool.self, forKey: .isOpaqueInFullScreen)) ?? fallback.isOpaqueInFullScreen
        showsBookmarksBar = (try? container.decodeIfPresent(Bool.self, forKey: .showsBookmarksBar)) ?? fallback.showsBookmarksBar
        bookmarksBarStyle = (try? container.decodeIfPresent(String.self, forKey: .bookmarksBarStyle)).flatMap { $0 }.flatMap(BookmarksBarStyle.init(rawValue:)) ?? fallback.bookmarksBarStyle
        fonts = (try? container.decodeIfPresent(WebFonts.self, forKey: .fonts)) ?? fallback.fonts
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(appearance.rawValue, forKey: .appearance)
        try container.encodeIfPresent(customColorHex, forKey: .customColorHex)
        try container.encodeIfPresent(gradient, forKey: .gradient)
        try container.encode(washOpacity, forKey: .washOpacity)
        try container.encode(allowsWebsiteThemeColor, forKey: .allowsWebsiteThemeColor)
        try container.encode(alwaysShowsToolbarInFullScreen, forKey: .alwaysShowsToolbarInFullScreen)
        try container.encode(autoShowsSidebarInFullScreen, forKey: .autoShowsSidebarInFullScreen)
        try container.encode(isOpaqueInFullScreen, forKey: .isOpaqueInFullScreen)
        try container.encode(showsBookmarksBar, forKey: .showsBookmarksBar)
        try container.encode(bookmarksBarStyle.rawValue, forKey: .bookmarksBarStyle)
        try container.encode(fonts, forKey: .fonts)
    }
}

/// How a bookmark shows in the bar.
enum BookmarksBarStyle: String, CaseIterable, Codable, Sendable {
    case iconAndText
    case iconOnly
    case textOnly

    var title: String {
        switch self {
        case .iconAndText: return "Icon and text"
        case .iconOnly: return "Icon only"
        case .textOnly: return "Text only"
        }
    }

    var showsIcon: Bool { self != .textOnly }
    var showsText: Bool { self != .iconOnly }
}

/// The fonts a page gets when it does not choose its own.
///
/// Applied as a style sheet at the front of every document, so it sets the
/// starting point and a page that names its own fonts still wins -- which is
/// what "default" means. The values WebKit ships with are the default, and
/// with them nothing is injected at all.
struct WebFonts: Codable, Hashable, Sendable {
    var standardFamily: String
    var standardSize: Int
    var fixedFamily: String
    var fixedSize: Int

    /// What WebKit uses on macOS when nobody says otherwise.
    static let webKitDefaults = WebFonts(standardFamily: "Times", standardSize: 16, fixedFamily: "Courier", fixedSize: 13)

    static let sizeRange = 9...72

    var isDefault: Bool { self == .webKitDefaults }

    /// The style sheet, or nil when the defaults are in force.
    var styleSheet: String? {
        guard !isDefault else { return nil }
        func quoted(_ family: String) -> String {
            "\"" + family.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let standard = Self.sizeRange.clamps(standardSize)
        let fixed = Self.sizeRange.clamps(fixedSize)
        return """
        html { font-family: \(quoted(standardFamily)); font-size: \(standard)px; }
        pre, code, kbd, samp, tt, xmp, plaintext, listing, textarea { font-family: \(quoted(fixedFamily)); font-size: \(fixed)px; }
        """
    }

    private enum CodingKeys: String, CodingKey {
        case standardFamily, standardSize, fixedFamily, fixedSize
    }

    init(standardFamily: String, standardSize: Int, fixedFamily: String, fixedSize: Int) {
        self.standardFamily = standardFamily
        self.standardSize = standardSize
        self.fixedFamily = fixedFamily
        self.fixedSize = fixedSize
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Self.webKitDefaults
        standardFamily = (try? container.decodeIfPresent(String.self, forKey: .standardFamily)) ?? fallback.standardFamily
        standardSize = Self.sizeRange.clamps((try? container.decodeIfPresent(Int.self, forKey: .standardSize)) ?? fallback.standardSize)
        fixedFamily = (try? container.decodeIfPresent(String.self, forKey: .fixedFamily)) ?? fallback.fixedFamily
        fixedSize = Self.sizeRange.clamps((try? container.decodeIfPresent(Int.self, forKey: .fixedSize)) ?? fallback.fixedSize)
    }
}

private extension ClosedRange where Bound == Int {
    func clamps(_ value: Int) -> Int { Swift.min(Swift.max(value, lowerBound), upperBound) }
}

/// A space's gradient wash: two colours and the direction between them.
///
/// A space's colour is an identity marker (`SpaceTheme`), and a gradient is the
/// same idea with more of it -- a work space that fades blue-to-teal is as
/// recognisable at a glance as one flat blue, and the direction is what stops
/// two blue-ish spaces reading the same. Colours are hex, the same convention
/// the theme's custom colour uses, so the whole thing stays a plain value that
/// drops into the session JSON.
struct SpaceGradient: Codable, Hashable, Sendable {
    var startHex: String
    var endHex: String
    var direction: GradientDirection

    init(startHex: String, endHex: String, direction: GradientDirection = .down) {
        self.startHex = startHex
        self.endHex = endHex
        self.direction = direction
    }

    /// The first stop. Falls back to the default space colour so a half-written
    /// gradient still resolves rather than vanishing.
    var startColor: NSColor { NSColor(hexString: startHex) ?? SpaceTheme.default.color }
    /// The second stop, falling back to the first.
    var endColor: NSColor { NSColor(hexString: endHex) ?? startColor }

    var startColorValue: NSColor {
        get { startColor }
        set { startHex = newValue.hexString }
    }
    var endColorValue: NSColor {
        get { endColor }
        set { endHex = newValue.hexString }
    }

    // MARK: - Tolerant decoding

    private enum CodingKeys: String, CodingKey { case startHex, endHex, direction }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startHex = (try? container.decode(String.self, forKey: .startHex)) ?? SpaceTheme.default.color.hexString
        endHex = (try? container.decode(String.self, forKey: .endHex)) ?? startHex
        direction = (try? container.decodeIfPresent(String.self, forKey: .direction)).flatMap(GradientDirection.init(rawValue:)) ?? .down
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(startHex, forKey: .startHex)
        try container.encode(endHex, forKey: .endHex)
        try container.encode(direction.rawValue, forKey: .direction)
    }
}
