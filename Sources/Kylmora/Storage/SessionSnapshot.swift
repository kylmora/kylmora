import AppKit

/// A serialisable picture of every space and tab.
///
/// Deliberately a value type with no references to live objects: writing it out
/// cannot be affected by what the browser does next.
struct SessionSnapshot: Codable, Equatable {
    struct Tab: Codable, Equatable {
        var url: URL
        var title: String?
        /// Which group the tab was filed under. Absent for ungrouped tabs and
        /// for sessions written before groups existed.
        var groupID: UUID?
        /// The name the user gave this tab, which overrides the page title.
        /// Absent for tabs that were never renamed, and for sessions written
        /// before renaming existed.
        var customName: String?
        /// The pinned shortcut this tab belongs to, if any. Absent for ordinary
        /// tabs and for sessions written before shortcuts owned their tab.
        var pinnedSiteID: UUID?
        /// `WKWebView.interactionState`, which carries scroll position, form
        /// contents and the back-forward list. Absent when the tab was never
        /// shown, in which case the URL alone is enough.
        var interactionState: Data?
        /// When the tab was last on screen. Absent in sessions written before
        /// the idle clock was persisted, which restore as "just now".
        ///
        /// Persisted because archiving measures in days: without it, quitting
        /// on Friday would hand every tab a fresh clock on Monday and nothing
        /// would ever age out of a sidebar that is closed every evening.
        var lastActiveAt: Date?
        /// Absent for tabs the user never locked, and for sessions written
        /// before the locks existed.
        var keepsAwake: Bool?
        var keepsInSidebar: Bool?
    }

    struct Space: Codable, Equatable {
        var name: String
        /// Written by builds that had a space switcher row with an icon and a
        /// colour per space. Read for compatibility, never written.
        var symbolName: String?
        var tint: String?
        var tabs: [Tab]
        var activeTabIndex: Int?
        /// Which profile this space browsed under, in sessions written while
        /// profiles were separate from spaces. Read for migration, never
        /// written; see `profiles`.
        var profileID: UUID?
        /// Where this space's website data lives. Absent in sessions written
        /// before a space was its own identity, which are migrated from
        /// `profileID`.
        var identity: Kylmora.Space.Identity?
        /// Absent in sessions written before spaces had a colour, which
        /// restore onto the default one.
        var theme: String?
        /// The rim around the window. Absent in sessions written before
        /// spaces had one, which restore with none.
        var border: WindowBorder?
        /// Appearance, fonts and bars. Absent in sessions written before a
        /// space had them, which restore with the defaults.
        var look: SpaceLook?
        /// Absent in sessions written before groups and pins existed.
        var groups: [Group]?
        var pinnedSites: [Pinned]?
        /// Tabs auto-archived out of this space's sidebar. Held on the space
        /// rather than at the top level because a snapshot identifies spaces by
        /// position, so anything filed by space id would not survive a reorder.
        /// Absent in sessions written before archiving existed.
        var archivedTabs: [Archived]?
    }

    /// A tab that left the sidebar on its own. Kept whole, so restoring it
    /// brings back the scroll position and back-forward list too, not just an
    /// address.
    struct Archived: Codable, Equatable {
        var tab: Tab
        var archivedAt: Date
    }

    struct Group: Codable, Equatable {
        var id: UUID
        var name: String
        var emoji: String?
        var tint: String
        /// How the group's plate is coloured. Absent for the default plate and
        /// for sessions written before groups could be themed.
        var appearance: TabGroupAppearance?
        var isCollapsed: Bool
        /// The folder this one is filed inside. Absent for root folders and for
        /// sessions written before folders nested.
        var parentID: UUID?
        /// An SF Symbol chosen instead of an emoji.
        var symbolName: String?
        /// Whether a provider maintains this folder's contents. The provider
        /// itself lives in `live-folders.json`, keyed by this group's id.
        var isLive: Bool?
    }

    struct Pinned: Codable, Equatable {
        var id: UUID
        var url: URL
        var title: String
    }

    /// A profile, from sessions written while profiles were a separate thing
    /// from spaces. Decoded so those sessions migrate; never written.
    struct Profile: Codable, Equatable {
        /// The shape the earlier build encoded, kept exactly so its files
        /// still decode. `ephemeral` carried no identifier then.
        enum Kind: Codable, Equatable {
            case standard
            case isolated(UUID)
            case ephemeral
        }

        var id: UUID
        var name: String
        var kind: Kind
        var theme: String?
    }

    var spaces: [Space]
    var activeSpaceIndex: Int
    /// Present only in sessions written while profiles existed.
    var profiles: [Profile]?
}

extension NSColor {
    /// `#rrggbb`, for storing a space tint in JSON. Falls back to the accent
    /// colour if the colour cannot be converted to sRGB.
    var hexString: String {
        guard let srgb = usingColorSpace(.sRGB) else { return "#007aff" }
        let components = [srgb.redComponent, srgb.greenComponent, srgb.blueComponent]
        return "#" + components.map { String(format: "%02x", Int(($0 * 255).rounded())) }.joined()
    }

    convenience init?(hexString: String) {
        var text = hexString.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = Int(text, radix: 16) else { return nil }
        self.init(
            srgbRed: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255,
            alpha: 1
        )
    }
}
