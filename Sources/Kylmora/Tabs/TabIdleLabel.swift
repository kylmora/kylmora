import Foundation

/// How long a tab has been untouched, as the shortest honest string.
///
/// `1s`, `10m`, `1h`, `3d`. Not `RelativeDateTimeFormatter`, which says "1
/// minute ago" -- five times the width for the same fact, in a sidebar row that
/// has a title to show. Every value is floored rather than rounded, so the badge
/// never claims more idleness than has actually passed.
enum TabIdleLabel {
    /// Below this, no badge at all. A tab you were just looking at does not
    /// need a timer on it, and a row that redraws every second to count "3s,
    /// 4s, 5s" is noise wearing the costume of information.
    static let floor: TimeInterval = 5

    static func text(for idle: TimeInterval) -> String? {
        guard idle >= floor else { return nil }
        let seconds = Int(idle)
        switch seconds {
        case ..<60: return "\(seconds)s"
        case ..<3_600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3_600)h"
        default: return "\(seconds / 86_400)d"
        }
    }

    /// Spoken by VoiceOver, where the abbreviation would be read as a letter.
    static func spoken(for idle: TimeInterval) -> String? {
        guard idle >= floor else { return nil }
        let seconds = Int(idle)
        let (value, unit): (Int, String)
        switch seconds {
        case ..<60: (value, unit) = (seconds, "second")
        case ..<3_600: (value, unit) = (seconds / 60, "minute")
        case ..<86_400: (value, unit) = (seconds / 3_600, "hour")
        default: (value, unit) = (seconds / 86_400, "day")
        }
        return "idle \(value) \(unit)\(value == 1 ? "" : "s")"
    }

    /// How long until the string above would change, so the sidebar can tick
    /// once per visible change instead of once per second forever. A row
    /// showing `4m` does not need redrawing for another minute.
    static func refreshInterval(for idle: TimeInterval) -> TimeInterval {
        switch idle {
        case ..<60: 1
        case ..<3_600: 60
        case ..<86_400: 3_600
        default: 3_600
        }
    }
}

/// Which rows carry an idle badge.
///
/// Three settings rather than a checkbox because the honest answer differs by
/// person: someone running a tidy sidebar wants the timer everywhere, someone
/// with sixty tabs wants it only where it explains something, and someone who
/// finds a clock on their tabs stressful wants it gone. None of those is the
/// wrong answer, so none of them is hard-coded.
enum TabIdleBadgeMode: String, CaseIterable, Sendable {
    /// No badge anywhere.
    case never
    /// Only on tabs that are asleep. The default: the badge then reads as an
    /// explanation -- this is why the row is dimmed -- rather than as a
    /// countdown running on everything you own.
    case asleep
    /// On every idle tab, asleep or not.
    case all

    var title: String {
        switch self {
        case .never: "Never"
        case .asleep: "On sleeping tabs"
        case .all: "On every idle tab"
        }
    }

    /// - Parameter isAsleep: whether the tab is holding a web view. False only
    ///   for a tab that is actually open.
    func showsBadge(isAsleep: Bool) -> Bool {
        switch self {
        case .never: false
        case .asleep: isAsleep
        case .all: true
        }
    }
}
