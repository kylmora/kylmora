import Foundation

/// Something that happened, for the rules to look at.
enum AutomationEvent: Equatable {
    case pageLoaded(url: URL)
    case tabIdle(url: URL, idleMinutes: Int)
    case mediaStarted(url: URL)
    case downloadFinished(fileURL: URL)
}

/// Decides which rules fire for an event. Pure, like `SpaceRouter`: no
/// tabs, no timers, no files, so every matching rule below is a test.
enum AutomationEngine {
    /// The enabled rules that match `event`, in rule order.
    static func rules(firing event: AutomationEvent, in rules: [AutomationRule]) -> [AutomationRule] {
        rules.filter { $0.isEnabled && matches($0.trigger, event: event) }
    }

    static func matches(_ trigger: AutomationTrigger, event: AutomationEvent) -> Bool {
        switch (trigger, event) {
        case (.pageLoaded(let pattern, let match), .pageLoaded(let url)):
            return urlMatches(pattern, match, url)
        case (.mediaStarted(let pattern, let match), .mediaStarted(let url)):
            return urlMatches(pattern, match, url)
        case (.tabIdle(let minutes, let pattern, let match), .tabIdle(let url, let idle)):
            return idle >= max(1, minutes) && urlMatches(pattern, match, url)
        case (.downloadFinished(let ext), .downloadFinished(let file)):
            let wanted = ext.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
            return wanted.isEmpty || file.pathExtension.lowercased() == wanted
        default:
            return false
        }
    }

    /// An empty pattern is every address; otherwise the routing rules'
    /// comparison, so `contains`, `equal-to` and `regex` mean the same here.
    static func urlMatches(_ pattern: String, _ match: SpaceRouteMatch, _ url: URL) -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        return SpaceRouter.matches(SpaceRoute(reference: trimmed, match: match, destination: .mostRecentSpace), url: url)
    }
}
