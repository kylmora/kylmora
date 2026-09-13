import Foundation

/// Query parameters that exist to follow a person from one site to the next,
/// and nothing else. Stripping them changes no page; it only stops the site
/// learning which advert, mail or post the visit came from.
///
/// A fixed list of well-known names rather than a heuristic: a parameter
/// that looks like tracking but is part of how a site works would break the
/// page, and the well-known ones cover nearly all of what is out there.
enum TrackingParameters {
    static let names: Set<String> = [
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "twclid", "ttclid",
        "igshid", "mc_cid", "mc_eid", "_hsenc", "_hsmi", "hsctatracking", "vero_id", "vero_conv",
        "wickedid", "oly_anon_id", "oly_enc_id", "_openstat", "mkt_tok", "s_cid", "ml_subscriber",
        "ml_subscriber_hash", "rb_clickid", "_ga", "_gl", "srsltid", "ref_src", "ref_url"
    ]
    static let prefixes = ["utm_", "pk_", "piwik_", "matomo_", "hsa_"]

    static func isTracking(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return names.contains(lowered) || prefixes.contains { lowered.hasPrefix($0) }
    }

    /// The address without its tracking parameters, or nil when it had none.
    static func cleaned(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems, !items.isEmpty else { return nil }
        let kept = items.filter { !isTracking($0.name) }
        guard kept.count != items.count else { return nil }
        components.queryItems = kept.isEmpty ? nil : kept
        return components.url
    }
}

/// When cookies are deleted on their own.
enum CookieDeletion: String, CaseIterable, Sendable {
    case manually
    case onQuit
    case afterDay
    case afterWeek
    case afterMonth

    var title: String {
        switch self {
        case .manually: return "Manually"
        case .onQuit: return "When Kylmora quits"
        case .afterDay: return "After one day"
        case .afterWeek: return "After one week"
        case .afterMonth: return "After one month"
        }
    }

    /// Whether the cookies should go now, given when they last went. "When
    /// Kylmora quits" is honoured at the next launch, which is the first moment
    /// the deletion can be done reliably.
    func isDue(lastDeletion: Date?, now: Date = .now) -> Bool {
        let age: TimeInterval
        switch self {
        case .manually: return false
        case .onQuit: return true
        case .afterDay: age = 24 * 60 * 60
        case .afterWeek: age = 7 * 24 * 60 * 60
        case .afterMonth: age = 30 * 24 * 60 * 60
        }
        guard let lastDeletion else { return true }
        return now.timeIntervalSince(lastDeletion) > age
    }
}

/// How long history is kept.
enum HistoryRetention: Int, CaseIterable, Sendable {
    case manually = 0
    case day = 1
    case week = 7
    case twoWeeks = 14
    case month = 30
    case threeMonths = 90
    case year = 365

    var title: String {
        switch self {
        case .manually: return "Manually"
        case .day: return "After one day"
        case .week: return "After one week"
        case .twoWeeks: return "After two weeks"
        case .month: return "After one month"
        case .threeMonths: return "After three months"
        case .year: return "After one year"
        }
    }

    /// Everything visited before this is removed; nil keeps everything.
    func cutoff(now: Date = .now) -> Date? {
        guard self != .manually else { return nil }
        return now.addingTimeInterval(-TimeInterval(rawValue) * 24 * 60 * 60)
    }
}

/// Which addresses have their tracking parameters removed.
enum TrackerRemoval: String, CaseIterable, Sendable {
    case never
    case privateOnly
    case always

    var title: String {
        switch self {
        case .never: return "Never"
        case .privateOnly: return "For Private Browsing only"
        case .always: return "Always"
        }
    }

    func applies(isPrivate: Bool) -> Bool {
        switch self {
        case .never: return false
        case .privateOnly: return isPrivate
        case .always: return true
        }
    }
}

/// What happens to a crash report Kylmora wrote.
enum CrashReportPolicy: String, CaseIterable, Sendable {
    case ask
    case always
    case never

    var title: String {
        switch self {
        case .ask: return "Keep after asking for approval"
        case .always: return "Always keep, without asking"
        case .never: return "Never"
        }
    }
}
