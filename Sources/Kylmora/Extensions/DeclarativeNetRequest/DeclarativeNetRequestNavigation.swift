import Foundation
import WebKit

/// The half of `declarativeNetRequest` WebKit's content matcher cannot do.
///
/// A content rule list can block and it can upgrade a scheme, but it cannot
/// send a request somewhere else and it cannot touch a header. Those are
/// applied here instead, at the moment a navigation is decided -- which works
/// for a page or a frame, because Kylmora sees those and may cancel and
/// re-issue them, and cannot work for a subresource, which WebKit fetches out
/// of process without asking.
///
/// So a redirect rule aimed at a page or a frame is honoured, and the same
/// rule aimed at an image is not. That is a real limit and it is reported as
/// one rather than papered over.
enum DeclarativeNetRequestNavigation {
    enum Outcome: Equatable {
        case proceed
        case block
        /// Load this instead: a redirect, or the same request with its headers
        /// rewritten.
        case replace(URLRequest)
    }

    /// The rule that won, and what it wants done.
    struct Decision {
        var outcome: Outcome
        var ruleID: Int?
    }

    /// Chrome's order: highest priority wins, and at equal priority an allow
    /// beats everything else.
    static func decide(
        request: URLRequest,
        isMainFrame: Bool,
        pageURL: URL?,
        rules: [DNRRule],
        extensionBaseURL: URL?
    ) -> Decision {
        guard let url = request.url else { return Decision(outcome: .proceed, ruleID: nil) }

        let candidates = rules.filter {
            matches($0, url: url, request: request, isMainFrame: isMainFrame, pageURL: pageURL)
        }
        guard !candidates.isEmpty else { return Decision(outcome: .proceed, ruleID: nil) }

        let winner = candidates.max { left, right in
            if left.priority != right.priority { return left.priority < right.priority }
            return rank(left.action) < rank(right.action)
        }
        guard let winner else { return Decision(outcome: .proceed, ruleID: nil) }

        switch winner.action {
        case .allow, .allowAllRequests:
            return Decision(outcome: .proceed, ruleID: winner.id)
        case .block:
            return Decision(outcome: .block, ruleID: winner.id)
        case .upgradeScheme:
            guard url.scheme?.lowercased() == "http",
                  var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                return Decision(outcome: .proceed, ruleID: nil)
            }
            components.scheme = "https"
            guard let upgraded = components.url else { return Decision(outcome: .proceed, ruleID: nil) }
            return Decision(outcome: .replace(rebuild(request, url: upgraded)), ruleID: winner.id)
        case .redirect(let redirect):
            guard let target = destination(
                for: redirect, from: url, rule: winner, extensionBaseURL: extensionBaseURL
            ), target != url else {
                // A redirect onto itself is a loop, not a redirect.
                return Decision(outcome: .proceed, ruleID: nil)
            }
            return Decision(outcome: .replace(rebuild(request, url: target)), ruleID: winner.id)
        case .modifyHeaders(let changes):
            // Re-issuing a request is the only way to change its headers here,
            // and re-issuing anything with a body would lose the body. A GET is
            // safe; nothing else is touched.
            guard (request.httpMethod ?? "GET").uppercased() == "GET", request.httpBody == nil else {
                return Decision(outcome: .proceed, ruleID: nil)
            }
            var modified = request
            for change in changes {
                switch change.operation {
                case "remove":
                    modified.setValue(nil, forHTTPHeaderField: change.header)
                case "set":
                    modified.setValue(change.value, forHTTPHeaderField: change.header)
                case "append":
                    modified.addValue(change.value ?? "", forHTTPHeaderField: change.header)
                default:
                    break
                }
            }
            guard modified != request else { return Decision(outcome: .proceed, ruleID: nil) }
            return Decision(outcome: .replace(modified), ruleID: winner.id)
        }
    }

    private static func rank(_ action: DNRRule.Action) -> Int {
        switch action {
        case .allow, .allowAllRequests: return 3
        case .block: return 2
        case .redirect, .upgradeScheme: return 1
        case .modifyHeaders: return 0
        }
    }

    /// The same request pointed somewhere else, keeping the method and the
    /// headers the page had set.
    private static func rebuild(_ request: URLRequest, url: URL) -> URLRequest {
        var replacement = request
        replacement.url = url
        return replacement
    }

    // MARK: - Matching

    static func matches(
        _ rule: DNRRule,
        url: URL,
        request: URLRequest,
        isMainFrame: Bool,
        pageURL: URL?
    ) -> Bool {
        let condition = rule.condition

        // A rule that names no resource types does not apply to a top-level
        // page: that is Chrome's default and the reason an unqualified rule
        // does not stop you opening a website.
        if condition.resourceTypes.isEmpty {
            if isMainFrame { return false }
            if condition.excludedResourceTypes.contains("sub_frame") { return false }
        } else {
            let wanted = isMainFrame ? "main_frame" : "sub_frame"
            guard condition.resourceTypes.contains(wanted) else { return false }
        }

        // Tabs are Chrome's own numbering, which this engine does not share.
        // A rule scoped to one is not applied rather than applied to the wrong
        // tab.
        if !condition.tabIDs.isEmpty || !condition.excludedTabIDs.isEmpty { return false }

        let method = (request.httpMethod ?? "GET").lowercased()
        if !condition.requestMethods.isEmpty,
           !condition.requestMethods.map({ $0.lowercased() }).contains(method) { return false }
        if condition.excludedRequestMethods.map({ $0.lowercased() }).contains(method) { return false }

        let text = url.absoluteString
        if let regexFilter = condition.regexFilter {
            guard regex(regexFilter, caseSensitive: condition.isUrlFilterCaseSensitive)?
                .firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { return false }
        } else if let urlFilter = condition.urlFilter, !urlFilter.isEmpty {
            guard let pattern = AdblockRuleConverter.regex(for: urlFilter),
                  regex(pattern, caseSensitive: condition.isUrlFilterCaseSensitive)?
                    .firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { return false }
        }

        let host = url.host()?.lowercased()
        if !condition.requestDomains.isEmpty {
            guard let host, condition.requestDomains.contains(where: { covers($0, host) }) else { return false }
        }
        if let host, condition.excludedRequestDomains.contains(where: { covers($0, host) }) { return false }

        let initiator = pageURL?.host()?.lowercased()
        if !condition.initiatorDomains.isEmpty {
            guard let initiator, condition.initiatorDomains.contains(where: { covers($0, initiator) }) else { return false }
        }
        if let initiator, condition.excludedInitiatorDomains.contains(where: { covers($0, initiator) }) { return false }

        switch condition.domainType {
        case "firstParty":
            guard let host, let initiator, covers(registrable(initiator), host) else { return false }
        case "thirdParty":
            if let host, let initiator, covers(registrable(initiator), host) { return false }
        default:
            break
        }
        return true
    }

    /// A domain covers itself and anything under it, which is what a bare
    /// domain means in a DNR condition.
    private static func covers(_ domain: String, _ host: String) -> Bool {
        let base = domain.hasPrefix("*.") ? String(domain.dropFirst(2)) : domain
        let lowered = base.lowercased()
        return host == lowered || host.hasSuffix("." + lowered)
    }

    /// Good enough for first versus third party: the last two labels. A real
    /// public-suffix list would do better on `co.uk`, and this errs towards
    /// calling something third party, which is the safe way to be wrong.
    private static func registrable(_ host: String) -> String {
        let parts = host.split(separator: ".")
        guard parts.count > 2 else { return host }
        return parts.suffix(2).joined(separator: ".")
    }

    private static func regex(_ pattern: String, caseSensitive: Bool) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive])
    }

    // MARK: - Where a redirect goes

    static func destination(
        for redirect: DNRRule.Redirect,
        from url: URL,
        rule: DNRRule,
        extensionBaseURL: URL?
    ) -> URL? {
        if let path = redirect.extensionPath, let base = extensionBaseURL {
            return URL(string: path.hasPrefix("/") ? String(path.dropFirst()) : path, relativeTo: base)?.absoluteURL
        }
        if let substitution = redirect.regexSubstitution, let pattern = rule.condition.regexFilter {
            return substituted(pattern: pattern, substitution: substitution, in: url)
        }
        if let text = redirect.url {
            return URL(string: text)
        }
        if let transform = redirect.transform {
            return transformed(url, by: transform)
        }
        return nil
    }

    /// `\\1`-style back references against the rule's own `regexFilter`.
    private static func substituted(pattern: String, substitution: String, in url: URL) -> URL? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let text = url.absoluteString
        let range = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, range: range) else { return nil }
        var result = ""
        var iterator = substitution.makeIterator()
        var pending: Character?
        while let character = pending ?? iterator.next() {
            pending = nil
            guard character == "\\" else {
                result.append(character)
                continue
            }
            guard let next = iterator.next() else { break }
            guard let group = next.wholeNumberValue, (0...9).contains(group) else {
                // `\\\\` and anything else escaped stands for itself.
                result.append(next)
                continue
            }
            guard group < match.numberOfRanges,
                  let captured = Range(match.range(at: group), in: text) else { continue }
            result.append(contentsOf: text[captured])
        }
        return URL(string: result)
    }

    private static func transformed(_ url: URL, by transform: DNRRule.Transform) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        if let scheme = transform.scheme { components.scheme = scheme }
        if let host = transform.host { components.host = host }
        if let port = transform.port { components.port = Int(port) }
        if let path = transform.path { components.path = path.hasPrefix("/") ? path : "/" + path }
        if let fragment = transform.fragment {
            components.fragment = fragment.hasPrefix("#") ? String(fragment.dropFirst()) : fragment
        }
        if let query = transform.query {
            let trimmed = query.hasPrefix("?") ? String(query.dropFirst()) : query
            components.query = trimmed.isEmpty ? nil : trimmed
        } else if let queryTransform = transform.queryTransform {
            var items = components.queryItems ?? []
            let removing = Set(queryTransform.removeParams)
            items.removeAll { removing.contains($0.name) }
            for parameter in queryTransform.addOrReplaceParams {
                if let position = items.firstIndex(where: { $0.name == parameter.key }) {
                    items[position].value = parameter.value
                } else if !parameter.replaceOnly {
                    items.append(URLQueryItem(name: parameter.key, value: parameter.value))
                }
            }
            components.queryItems = items.isEmpty ? nil : items
        }
        return components.url
    }
}
