import Foundation

/// A published filter list Kylmora can fetch and apply.
///
/// The catalogue is fixed and small on purpose: every entry is a list with a
/// known maintainer, a stable address and a licence that permits use, and the
/// user turns entries on and off rather than pasting in addresses. Lists are
/// fetched, never bundled, so the repository carries no third-party rules and
/// the lists are as fresh as their last download (see THIRD_PARTY.md).
struct FilterList: Identifiable, Equatable, Sendable {
    enum Category: String, CaseIterable, Sendable {
        case ads
        case trackers
        case cookieBanners
        /// Ads on sites in one language or country. Off by default: the lists
        /// are large and most of them are irrelevant to any one person.
        case regional

        var title: String {
            switch self {
            case .ads: return "Ad Blockers"
            case .trackers: return "Trackers"
            case .cookieBanners: return "Cookie Banners"
            case .regional: return "Regional"
            }
        }
    }

    let id: String
    let name: String
    let category: Category
    let url: URL
    /// One or two sentences for the info popover.
    let summary: String
    let licence: String
    /// On unless the user says otherwise.
    let isDefault: Bool

    private static func make(
        _ id: String, _ name: String, _ category: Category, _ url: String,
        _ summary: String, licence: String, isDefault: Bool
    ) -> FilterList {
        FilterList(
            id: id, name: name, category: category, url: URL(string: url)!,
            summary: summary, licence: licence, isDefault: isDefault
        )
    }

    private static let gpl3 = "GPLv3"
    private static let ccBySa = "CC BY-SA 3.0 / GPLv3"

    static let all: [FilterList] = [
        // Ads
        make("easylist", "EasyList", .ads, "https://easylist.to/easylist/easylist.txt",
             "The primary list most ad blockers are built on. Removes adverts, including most banners, pop-ups and sponsored placements, on English-language sites.",
             licence: ccBySa, isDefault: true),
        make("ublock-ads", "uBlock - Ads", .ads,
             "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/filters.txt",
             "uBlock Origin's own additions to EasyList: adverts and ad-serving domains EasyList has not caught up with yet.",
             licence: gpl3, isDefault: true),
        make("ublock-unbreak", "uBlock - Unbreak", .ads,
             "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/unbreak.txt",
             "Exceptions that repair sites the other lists break. Keeping this on is what stops blocking from taking a working page down with the adverts.",
             licence: gpl3, isDefault: true),

        // Trackers
        make("easyprivacy", "EasyPrivacy", .trackers, "https://easylist.to/easylist/easyprivacy.txt",
             "Blocks tracking scripts, beacons and analytics that follow you between sites.",
             licence: ccBySa, isDefault: true),
        make("ublock-privacy", "uBlock - Privacy", .trackers,
             "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/privacy.txt",
             "uBlock Origin's additions to EasyPrivacy.",
             licence: gpl3, isDefault: true),

        // Cookie banners
        make("easylist-cookies", "EasyList - Cookie Notices", .cookieBanners,
             "https://secure.fanboy.co.nz/fanboy-cookiemonster.txt",
             "Hides cookie consent banners and overlays. It hides the banner rather than answering it, so a site that insists on an answer may still ask.",
             licence: ccBySa, isDefault: true),
        make("ublock-cookies", "uBlock \u{2013} Cookie Notices", .cookieBanners,
             "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/annoyances-cookies.txt",
             "uBlock Origin's cookie-notice filters, which cover banners the EasyList one does not.",
             licence: gpl3, isDefault: true),

        // Regional
        make("easylist-polish", "EasyList - Polska lista", .regional,
             "https://easylist-downloads.adblockplus.org/easylistpolish.txt",
             "Adverts on Polish sites.", licence: ccBySa, isDefault: false),
        make("ru-adlist", "RU AdList", .regional,
             "https://easylist-downloads.adblockplus.org/advblock.txt",
             "Adverts on Russian and Ukrainian sites.", licence: ccBySa, isDefault: false),
        make("albania", "Adblock List for Albania", .regional,
             "https://raw.githubusercontent.com/AnXh3L0/blocklist/master/albanian-easylist-addition/Adblock.txt",
             "Adverts on Albanian sites.", licence: gpl3, isDefault: false),
        make("bulgaria", "Adblock List for Bulgaria", .regional,
             "https://stanev.org/abp/adblock_bg.txt",
             "Adverts on Bulgarian sites.", licence: gpl3, isDefault: false),
        make("easylist-china", "EasyList China", .regional,
             "https://easylist-downloads.adblockplus.org/easylistchina.txt",
             "Adverts on Chinese sites.", licence: ccBySa, isDefault: false),
        make("easylist-czech-slovak", "EasyList Czech and Slovak", .regional,
             "https://raw.githubusercontent.com/tomasko126/easylistczechandslovak/master/filters.txt",
             "Adverts on Czech and Slovak sites.", licence: ccBySa, isDefault: false),
        make("easylist-dutch", "EasyList Dutch", .regional,
             "https://easylist-downloads.adblockplus.org/easylistdutch.txt",
             "Adverts on Dutch sites.", licence: ccBySa, isDefault: false),
        make("liste-fr", "Liste FR", .regional,
             "https://easylist-downloads.adblockplus.org/liste_fr.txt",
             "Adverts on French sites.", licence: ccBySa, isDefault: false),
        make("easylist-germany", "EasyList Germany", .regional,
             "https://easylist.to/easylistgermany/easylistgermany.txt",
             "Adverts on German sites.", licence: ccBySa, isDefault: false),
        make("easylist-hebrew", "EasyList Hebrew", .regional,
             "https://raw.githubusercontent.com/easylist/EasyListHebrew/master/EasyListHebrew.txt",
             "Adverts on Hebrew sites.", licence: ccBySa, isDefault: false),
        make("easylist-italy", "EasyList Italy", .regional,
             "https://easylist-downloads.adblockplus.org/easylistitaly.txt",
             "Adverts on Italian sites.", licence: ccBySa, isDefault: false),
        make("easylist-portuguese", "EasyList Portuguese", .regional,
             "https://easylist-downloads.adblockplus.org/easylistportuguese.txt",
             "Adverts on Portuguese and Brazilian sites.", licence: ccBySa, isDefault: false),
        make("slovenian", "Slovenian List", .regional,
             "https://raw.githubusercontent.com/betterwebleon/slovenian-list/master/filters.txt",
             "Adverts on Slovenian sites.", licence: gpl3, isDefault: false),
        make("easylist-spanish", "EasyList Spanish", .regional,
             "https://easylist-downloads.adblockplus.org/easylistspanish.txt",
             "Adverts on Spanish sites.", licence: ccBySa, isDefault: false),
        make("frellwit-swedish", "Frellwit's Swedish Filter", .regional,
             "https://raw.githubusercontent.com/lassekongo83/Frellwits-filter-lists/master/Frellwits-Swedish-Filter.txt",
             "Adverts on Swedish sites.", licence: gpl3, isDefault: false),
        make("easylist-thailand", "EasyList Thailand", .regional,
             "https://raw.githubusercontent.com/easylist-thailand/easylist-thailand/master/subscription/easylist-thailand.txt",
             "Adverts on Thai sites.", licence: ccBySa, isDefault: false),
        make("adguard-turkish", "AdGuard Turkish", .regional,
             "https://filters.adtidy.org/extension/ublock/filters/13.txt",
             "Adverts on Turkish sites, from AdGuard's list.", licence: gpl3, isDefault: false),
        make("abpvn", "ABPVN List (Vietnamese)", .regional,
             "https://raw.githubusercontent.com/abpvn/abpvn/master/filter/abpvn.txt",
             "Adverts on Vietnamese sites.", licence: gpl3, isDefault: false)
    ]

    static func named(_ id: String) -> FilterList? { all.first { $0.id == id } }

    static func lists(in category: Category) -> [FilterList] { all.filter { $0.category == category } }
}

/// The three switches and the per-list choices under them.
struct ContentBlockingPreferences: Equatable, Sendable {
    var blocksAds = true
    var blocksCookieBanners = true
    var blocksTrackers = true
    /// Lists the user has switched away from their default, by id.
    var listOverrides: [String: Bool] = [:]

    /// Whether the switch that governs this category is on. Regional lists
    /// are ad lists for one region, so they ride on the ads switch.
    func isCategoryEnabled(_ category: FilterList.Category) -> Bool {
        switch category {
        case .ads, .regional: return blocksAds
        case .trackers: return blocksTrackers
        case .cookieBanners: return blocksCookieBanners
        }
    }

    /// The user's choice for one list, default included.
    func isListChosen(_ list: FilterList) -> Bool {
        listOverrides[list.id] ?? list.isDefault
    }

    /// The lists that should be applied right now: chosen, and in a category
    /// whose switch is on.
    func activeLists(in catalogue: [FilterList] = FilterList.all) -> [FilterList] {
        catalogue.filter { isCategoryEnabled($0.category) && isListChosen($0) }
    }
}
