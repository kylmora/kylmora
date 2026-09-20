import Foundation

/// Turns `declarativeNetRequest` rules into the content rule list WebKit
/// actually enforces.
///
/// WebKit's engine does not implement `declarativeNetRequest` at all, so an
/// MV3 blocker installs, looks healthy and blocks nothing. It does implement
/// `WKContentRuleList`, which is the same idea with a different vocabulary and
/// a smaller one -- so the rules are translated rather than interpreted, and
/// the matching runs in WebKit's own matcher at full speed.
///
/// What cannot be translated is named rather than dropped quietly. A blocker
/// that half works without saying so is worse than one that says which of its
/// rules this browser could not take.
enum DeclarativeNetRequestCompiler {
    /// A rule that could not be translated, and the reason in plain English.
    struct Unsupported: Equatable, Sendable {
        let id: Int
        let reason: String
    }

    struct Compilation: Equatable, Sendable {
        /// The content rule list JSON, ready for `WKContentRuleListStore`.
        var json: String
        /// How many rules made it across.
        var translated: Int
        var unsupported: [Unsupported]
        /// Rules WebKit's matcher cannot hold, but which Kylmora applies when
        /// a page or a frame navigates. They work; they just do not work for a
        /// subresource, which nothing here can intercept.
        var navigationOnly: [Unsupported] = []

        var isEmpty: Bool { translated == 0 }
    }

    /// The ceiling Kylmora already compiles its own filter lists against.
    ///
    /// It is deliberately not a rule count as an extension writes them: a
    /// condition listing many requested hosts becomes one rule per host,
    /// because WebKit's matcher has no alternation -- verified against the
    /// real compiler, not assumed -- so a blocker's 18,000 rules can become
    /// six figures here.
    static let maximumRules = 150_000

    /// DNR's resource types in WebKit's vocabulary. `main_frame` and
    /// `sub_frame` are both documents to WebKit; they are told apart by
    /// load context rather than by type.
    private static let resourceTypes: [String: String] = [
        "main_frame": "document",
        "sub_frame": "document",
        "stylesheet": "style-sheet",
        "script": "script",
        "image": "image",
        "font": "font",
        "media": "media",
        "object": "raw",
        "xmlhttprequest": "raw",
        "csp_report": "raw",
        "websocket": "raw",
        "webtransport": "raw",
        "webbundle": "raw",
        "ping": "ping",
        "other": "raw"
    ]

    /// Everything WebKit will match when a rule names no type. `document` is
    /// left out on purpose: a DNR rule with no `resourceTypes` does not apply
    /// to top-level navigation, and a translation that blocked the page itself
    /// would be a browser that will not load a site.
    private static let defaultResourceTypes =
        ["script", "image", "style-sheet", "font", "media", "raw", "ping", "popup"]

    static func compile(_ rules: [DNRRule]) -> Compilation {
        var unsupported: [Unsupported] = []
        var navigationOnly: [Unsupported] = []
        var translatable: [(rule: DNRRule, trigger: [String: Any], action: [String: Any])] = []

        for rule in rules {
            switch translate(rule) {
            case .failure(let reason):
                unsupported.append(Unsupported(id: rule.id, reason: reason))
            case .navigationOnly(let reason):
                navigationOnly.append(Unsupported(id: rule.id, reason: reason))
            case .success(let triggers, let action):
                for trigger in triggers { translatable.append((rule, trigger, action)) }
            }
        }

        // WebKit has no notion of priority: it runs every rule in order and
        // the last `ignore-previous-rules` to match wins. Chrome's order is
        // the other way round -- higher priority wins, and at equal priority
        // an allow beats a block -- so the list is emitted lowest priority
        // first, blocks before allows, which makes WebKit's "last wins"
        // produce Chrome's answer.
        translatable.sort { left, right in
            if left.rule.priority != right.rule.priority { return left.rule.priority < right.rule.priority }
            if overrideRank(left.rule.action) != overrideRank(right.rule.action) {
                return overrideRank(left.rule.action) < overrideRank(right.rule.action)
            }
            return left.rule.id < right.rule.id
        }

        if translatable.count > maximumRules {
            for dropped in translatable[maximumRules...] {
                unsupported.append(Unsupported(
                    id: dropped.rule.id,
                    reason: "Past the \(maximumRules)-rule limit this browser compiles."
                ))
            }
            translatable = Array(translatable[..<maximumRules])
        }

        let payload = translatable.map { ["trigger": $0.trigger, "action": $0.action] }
        let json: String
        if payload.isEmpty {
            json = "[]"
        } else if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
                  let text = String(data: data, encoding: .utf8) {
            json = text
        } else {
            json = "[]"
        }
        return Compilation(json: json, translated: payload.count,
                           unsupported: unsupported, navigationOnly: navigationOnly)
    }

    /// Later beats earlier in WebKit, so a bigger number is emitted later.
    private static func overrideRank(_ action: DNRRule.Action) -> Int {
        switch action {
        case .block, .upgradeScheme, .redirect, .modifyHeaders: return 0
        case .allow: return 1
        case .allowAllRequests: return 2
        }
    }

    private enum Translation {
        /// One rule can become several: WebKit's matcher will not take a group
        /// of alternatives, so a list of requested hosts is emitted as one
        /// rule per host instead.
        case success(triggers: [[String: Any]], action: [String: Any])
        case failure(String)
        /// Not for the content list, but honoured at navigation time.
        case navigationOnly(String)
    }

    private static func translate(_ rule: DNRRule) -> Translation {
        let condition = rule.condition

        let action: [String: Any]
        switch rule.action {
        case .block:
            action = ["type": "block"]
        case .allow, .allowAllRequests:
            action = ["type": "ignore-previous-rules"]
        case .upgradeScheme:
            action = ["type": "make-https"]
        case .redirect:
            return .navigationOnly("Redirects apply to pages and frames; a subresource cannot be intercepted.")
        case .modifyHeaders:
            return .navigationOnly("Header changes apply to pages and frames, and only to requests without a body.")
        }

        if !condition.requestMethods.isEmpty || !condition.excludedRequestMethods.isEmpty {
            return .failure("Matching on the request method is not something this browser's matcher can do.")
        }
        if !condition.tabIDs.isEmpty || !condition.excludedTabIDs.isEmpty {
            return .failure("Matching on a tab is not something this browser's matcher can do.")
        }
        if !condition.excludedRequestDomains.isEmpty {
            return .failure("Excluding the requested host is not something this browser's matcher can do.")
        }

        var trigger: [String: Any] = [:]
        // Filled when the rule names requested hosts, which expand into one
        // rule each rather than a single alternation.
        var urlFilters: [String] = []

        // The URL to match. A `regexFilter` is WebKit's own regex dialect and
        // goes through as written; a `urlFilter` is Adblock's pattern syntax,
        // which Kylmora already knows how to turn into one.
        if let regexFilter = condition.regexFilter {
            guard isSupportedRegex(regexFilter) else {
                return .failure("This browser's matcher does not take that regular expression.")
            }
            trigger["url-filter"] = regexFilter
        } else if let urlFilter = condition.urlFilter, !urlFilter.isEmpty {
            guard condition.requestDomains.isEmpty else {
                return .failure("A rule cannot match both a URL pattern and a list of requested hosts here.")
            }
            guard let regex = AdblockRuleConverter.regex(for: urlFilter) else {
                return .failure("The URL pattern could not be read.")
            }
            trigger["url-filter"] = regex
        } else if !condition.requestDomains.isEmpty {
            urlFilters = condition.requestDomains.map(hostRegex)
        } else {
            trigger["url-filter"] = ".*"
        }

        if condition.isUrlFilterCaseSensitive {
            trigger["url-filter-is-case-sensitive"] = true
        }

        // `if-domain` is about the page the request came from, which is what
        // DNR calls the initiator. A leading `*` is WebKit's way of saying
        // "and its subdomains", which is what DNR means by a bare domain.
        if !condition.initiatorDomains.isEmpty {
            trigger["if-domain"] = condition.initiatorDomains.map(subdomainForm)
        }
        if !condition.excludedInitiatorDomains.isEmpty {
            trigger["unless-domain"] = condition.excludedInitiatorDomains.map(subdomainForm)
        }

        let (types, contexts) = webKitTypes(for: condition)
        if let types { trigger["resource-type"] = types }
        if let contexts { trigger["load-context"] = contexts }

        switch condition.domainType {
        case "firstParty": trigger["load-type"] = ["first-party"]
        case "thirdParty": trigger["load-type"] = ["third-party"]
        default: break
        }

        guard urlFilters.isEmpty else {
            return .success(triggers: urlFilters.map { filter in
                var copy = trigger
                copy["url-filter"] = filter
                return copy
            }, action: action)
        }
        return .success(triggers: [trigger], action: action)
    }

    /// DNR's types and, where the pair of them only differ by where the
    /// document is loading, the load context that tells them apart.
    private static func webKitTypes(for condition: DNRRule.Condition) -> ([String]?, [String]?) {
        var named = condition.resourceTypes
        if named.isEmpty, !condition.excludedResourceTypes.isEmpty {
            named = Array(resourceTypes.keys).filter { !condition.excludedResourceTypes.contains($0) }
        }
        guard !named.isEmpty else { return (nil, nil) }

        let mapped = Set(named.compactMap { resourceTypes[$0] })
        guard !mapped.isEmpty else { return (defaultResourceTypes, nil) }

        // A rule for sub-frames only must not take the top-level page with it:
        // that would be a rule that refuses to load the site.
        var contexts: [String]?
        let wantsTop = named.contains("main_frame")
        let wantsChild = named.contains("sub_frame")
        if mapped.contains("document"), wantsTop != wantsChild {
            contexts = wantsTop ? ["top-frame"] : ["child-frame"]
        }
        return (mapped.sorted(), contexts)
    }

    /// A host and its subdomains, anchored at the start of the URL. The shape
    /// is the one Kylmora's Adblock converter already uses, which is to say
    /// the one WebKit's matcher is known to take: it refuses a group of
    /// alternatives, so each host gets its own rule.
    private static func hostRegex(_ domain: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: domain.lowercased())
        return "^[^:]+:(//)?([^/]+\\.)?" + escaped + "[:/]"
    }

    private static func subdomainForm(_ domain: String) -> String {
        let trimmed = domain.hasPrefix("*") ? String(domain.dropFirst()) : domain
        return "*" + trimmed.lowercased()
    }

    /// WebKit's matcher takes a restricted regular expression: no lookaround,
    /// no backreferences, no non-greedy quantifiers. A rule using one compiles
    /// to nothing useful, so it is refused by name instead.
    static func isSupportedRegex(_ pattern: String) -> Bool {
        let refused = ["(?=", "(?!", "(?<", "\\1", "\\2", "\\3", "*?", "+?", "??", "{,"]
        for marker in refused where pattern.contains(marker) { return false }
        // It still has to be a regular expression at all.
        return (try? NSRegularExpression(pattern: pattern)) != nil
    }
}
