import Foundation

/// Turns a filter list in Adblock Plus syntax into WebKit content-blocker
/// rules.
///
/// WebKit's content blocker is Safari's: a JSON list of triggers and actions,
/// compiled once and then applied inside the engine to every request and
/// element. The published lists are written in the Adblock Plus syntax that
/// every blocker reads, so a converter is the whole bridge. This one covers
/// what the two formats share and skips, counted, what WebKit cannot express:
/// regular-expression filters, scriptlets, extended CSS, redirects and the
/// like. Skipping is correct here; a rule mistranslated blocks the wrong thing.
///
/// Pure and `Sendable`, so a two-megabyte list converts off the main thread.
struct AdblockRuleConverter: Sendable {

    /// One WebKit rule. Keys are WebKit's, hence the strings.
    struct Rule: Equatable, Sendable {
        var urlFilter: String
        var isCaseSensitive = false
        var resourceTypes: [String]? = nil
        var loadTypes: [String]? = nil
        var ifDomain: [String]? = nil
        var unlessDomain: [String]? = nil
        var ifTopURL: [String]? = nil
        var actionType: String
        var selector: String? = nil

        var json: [String: Any] {
            var trigger: [String: Any] = ["url-filter": urlFilter]
            if isCaseSensitive { trigger["url-filter-is-case-sensitive"] = true }
            if let resourceTypes { trigger["resource-type"] = resourceTypes }
            if let loadTypes { trigger["load-type"] = loadTypes }
            if let ifDomain { trigger["if-domain"] = ifDomain }
            if let unlessDomain { trigger["unless-domain"] = unlessDomain }
            if let ifTopURL { trigger["if-top-url"] = ifTopURL }
            var action: [String: Any] = ["type": actionType]
            if let selector { action["selector"] = selector }
            return ["trigger": trigger, "action": action]
        }
    }

    struct Output: Sendable {
        var rules: [Rule]
        /// Lines that were filters but could not be expressed.
        var skipped: Int
        /// Rules dropped to stay under WebKit's limit.
        var truncated: Int

        /// The JSON WebKit compiles.
        func encoded() throws -> String {
            let data = try JSONSerialization.data(withJSONObject: rules.map(\.json), options: [])
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// WebKit refuses to compile a list with more rules than this.
    static let maximumRules = 150_000

    /// Bumped whenever the output for the same input changes, so cached
    /// compilations are redone.
    static let version = 1

    private static let separatorClass = "[^-_.%a-zA-Z0-9]"
    private static let hostPrefix = "^[^:]+:(//)?([^/]+\\.)?"

    private static let resourceTypes: [String: String] = [
        "script": "script", "image": "image", "stylesheet": "style-sheet", "css": "style-sheet",
        "xmlhttprequest": "raw", "xhr": "raw", "subdocument": "document", "frame": "document",
        "font": "font", "media": "media", "popup": "popup", "websocket": "raw",
        "ping": "ping", "beacon": "ping", "other": "raw"
    ]
    private static let allResourceTypes = ["script", "image", "style-sheet", "raw", "document", "font", "media", "popup", "ping"]

    /// Pseudo-classes only extension blockers implement. A selector using one
    /// would silently match nothing or, worse, something else.
    private static let unsupportedSelectorMarkers = [
        ":has(", ":-abp-", ":style(", ":xpath(", ":matches-css", ":contains(", ":upward(", ":remove(",
        ":watch-attr", ":min-text-length", ":nth-ancestor", ":matches-path", ":others(", ":matches-attr",
        ":if(", ":if-not(", ":has-text(", ":matches-media", ":remove-attr", ":remove-class", "^"
    ]

    func convert(_ text: String) -> Output {
        var blocks: [Rule] = []
        var hides: [Rule] = []
        var exceptions: [Rule] = []
        var skipped = 0

        text.enumerateLines { line, _ in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("[") else { return }

            if let hiding = Self.splitHiding(line) {
                if let rule = Self.hidingRule(domains: hiding.domains, selector: hiding.selector) {
                    hides.append(rule)
                } else {
                    skipped += 1
                }
                return
            }
            if line.contains("#@#") || line.contains("#?#") || line.contains("#$#") || line.contains("#%#")
                || line.contains("#@?#") || line.contains("#$?#") {
                skipped += 1
                return
            }
            switch Self.networkRule(line) {
            case .block(let rule): blocks.append(rule)
            case .exception(let rule): exceptions.append(rule)
            case .unsupported: skipped += 1
            }
        }

        // Exceptions must follow what they except: WebKit reads the list in
        // order and "ignore previous rules" means exactly that.
        var rules = blocks + hides + exceptions
        var truncated = 0
        if rules.count > Self.maximumRules {
            // Cosmetic rules go first: an advert that is blocked but not
            // hidden leaves a gap, an advert that is hidden but not blocked
            // still loads.
            let keepHides = max(0, hides.count - (rules.count - Self.maximumRules))
            let droppedHides = hides.count - keepHides
            rules = blocks + Array(hides.prefix(keepHides)) + exceptions
            truncated += droppedHides
            if rules.count > Self.maximumRules {
                let over = rules.count - Self.maximumRules
                rules = Array(blocks.dropLast(over)) + Array(hides.prefix(keepHides)) + exceptions
                truncated += over
            }
        }
        return Output(rules: rules, skipped: skipped, truncated: truncated)
    }

    // MARK: - Element hiding

    private static func splitHiding(_ line: String) -> (domains: String, selector: String)? {
        guard let range = line.range(of: "##") else { return nil }
        // "#@#" and the rest are handled by the caller; only plain "##" here.
        let before = line[..<range.lowerBound]
        if before.hasSuffix("#") { return nil }
        return (String(before), String(line[range.upperBound...]))
    }

    static func hidingRule(domains: String, selector: String) -> Rule? {
        let selector = selector.trimmingCharacters(in: .whitespaces)
        guard !selector.isEmpty, selector.utf8.allSatisfy({ $0 < 128 }) else { return nil }
        guard !selector.hasPrefix("+js("), !unsupportedSelectorMarkers.contains(where: selector.contains) else {
            return nil
        }
        guard let (include, exclude) = parseDomains(domains) else { return nil }
        var rule = Rule(urlFilter: ".*", actionType: "css-display-none", selector: selector)
        if !include.isEmpty {
            rule.ifDomain = include
        } else if !exclude.isEmpty {
            rule.unlessDomain = exclude
        }
        return rule
    }

    /// `a.com,~b.com` into WebKit's forms. A wildcard TLD (`example.*`) has
    /// no WebKit equivalent and fails the whole rule rather than widening it.
    private static func parseDomains(_ text: String) -> (include: [String], exclude: [String])? {
        var include: [String] = []
        var exclude: [String] = []
        for raw in text.split(separator: ",") where !raw.isEmpty {
            var domain = String(raw).trimmingCharacters(in: .whitespaces)
            let negated = domain.hasPrefix("~")
            if negated { domain.removeFirst() }
            guard !domain.isEmpty, !domain.contains("*"), domain.utf8.allSatisfy({ $0 < 128 }) else { return nil }
            // A leading star makes WebKit match the domain and its subdomains.
            if negated {
                exclude.append("*" + domain.lowercased())
            } else {
                include.append("*" + domain.lowercased())
            }
        }
        return (include, exclude)
    }

    // MARK: - Network filters

    private enum Network {
        case block(Rule)
        case exception(Rule)
        case unsupported
    }

    private static func networkRule(_ line: String) -> Network {
        var body = Substring(line)
        let isException = body.hasPrefix("@@")
        if isException { body = body.dropFirst(2) }

        // A regular-expression filter: WebKit's dialect is too different to
        // pass one through.
        if body.hasPrefix("/"), body.hasSuffix("/"), body.count > 2 { return .unsupported }

        var pattern = body
        var options: [Substring] = []
        if let dollar = body.lastIndex(of: "$"), !body[body.index(after: dollar)...].contains("/") {
            pattern = body[..<dollar]
            options = body[body.index(after: dollar)...].split(separator: ",")
        }
        guard pattern.utf8.allSatisfy({ $0 < 128 }) else { return .unsupported }

        var resourceTypes: Set<String> = []
        var excludedTypes: Set<String> = []
        var loadTypes: [String]? = nil
        var include: [String] = []
        var exclude: [String] = []
        var caseSensitive = false
        var wholePage = false

        for option in options {
            let option = option.trimmingCharacters(in: .whitespaces)
            let negated = option.hasPrefix("~")
            let name = negated ? String(option.dropFirst()) : option
            if name.hasPrefix("domain=") || name.hasPrefix("from=") {
                let list = name.drop { $0 != "=" }.dropFirst()
                guard let parsed = parseDomains(list.replacingOccurrences(of: "|", with: ",")) else { return .unsupported }
                include = parsed.include
                exclude = parsed.exclude
                continue
            }
            switch name {
            case "third-party", "3p": loadTypes = [negated ? "first-party" : "third-party"]
            case "first-party", "1p": loadTypes = [negated ? "third-party" : "first-party"]
            case "match-case": caseSensitive = true
            case "document", "doc", "elemhide", "ehide", "generichide", "ghide", "genericblock":
                guard isException else { return .unsupported }
                wholePage = true
            case "important", "all": break
            case "badfilter": return .unsupported
            default:
                if let type = resourceTypes_(name) {
                    if negated { excludedTypes.insert(type) } else { resourceTypes.insert(type) }
                } else {
                    // redirect=, csp=, removeparam, replace=, header=, denyallow=,
                    // method=, object, webrtc, and anything newer.
                    return .unsupported
                }
            }
        }
        if resourceTypes.isEmpty, !excludedTypes.isEmpty {
            resourceTypes = Set(allResourceTypes).subtracting(excludedTypes)
        }

        guard let urlFilter = regex(for: String(pattern)) else { return .unsupported }

        if isException {
            var rule = Rule(urlFilter: wholePage ? ".*" : urlFilter, actionType: "ignore-previous-rules")
            if wholePage {
                rule.ifTopURL = [urlFilter]
            } else {
                if !resourceTypes.isEmpty { rule.resourceTypes = allResourceTypes.filter(resourceTypes.contains) }
                rule.loadTypes = loadTypes
                if !include.isEmpty { rule.ifDomain = include } else if !exclude.isEmpty { rule.unlessDomain = exclude }
            }
            rule.isCaseSensitive = caseSensitive
            return .exception(rule)
        }
        guard !wholePage else { return .unsupported }
        var rule = Rule(urlFilter: urlFilter, actionType: "block")
        rule.isCaseSensitive = caseSensitive
        if !resourceTypes.isEmpty { rule.resourceTypes = allResourceTypes.filter(resourceTypes.contains) }
        rule.loadTypes = loadTypes
        if !include.isEmpty { rule.ifDomain = include } else if !exclude.isEmpty { rule.unlessDomain = exclude }
        return .block(rule)
    }

    private static func resourceTypes_(_ name: String) -> String? { resourceTypes[name] }

    /// The Adblock pattern as the regular expression WebKit's matcher takes:
    /// `||` anchors to a host and its subdomains, `|` to either end, `^` is a
    /// separator, `*` is anything. Everything else is literal.
    static func regex(for pattern: String) -> String? {
        var pattern = Substring(pattern)
        var out = ""
        if pattern.hasPrefix("||") {
            out += hostPrefix
            pattern = pattern.dropFirst(2)
        } else if pattern.hasPrefix("|") {
            out += "^"
            pattern = pattern.dropFirst()
        }
        var anchoredEnd = false
        if pattern.hasSuffix("|") {
            anchoredEnd = true
            pattern = pattern.dropLast()
        }
        if pattern.isEmpty, out.isEmpty { return ".*" }
        for character in pattern {
            switch character {
            case "*": out += ".*"
            case "^": out += separatorClass
            case ".", "+", "?", "(", ")", "[", "]", "{", "}", "|", "\\", "$":
                out += "\\" + String(character)
            default:
                out.append(character)
            }
        }
        if anchoredEnd { out += "$" }
        return out
    }
}
