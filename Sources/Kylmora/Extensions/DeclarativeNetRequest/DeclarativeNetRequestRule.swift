import Foundation

/// One `declarativeNetRequest` rule, as an extension wrote it.
///
/// Parsed rather than trusted: these come out of an extension's own JSON, and
/// a rule Kylmora cannot make sense of must be refused by name so the pane can
/// say which one and why, instead of the whole list quietly doing nothing.
struct DNRRule: Equatable, Sendable {
    /// What to do with a request that matches.
    enum Action: Equatable, Sendable {
        case block
        case allow
        /// Everything inside the matching frame is allowed, not just the
        /// request itself.
        case allowAllRequests
        case upgradeScheme
        /// Send the request somewhere else. WebKit's content matcher cannot do
        /// this, so it is carried and applied at navigation time instead --
        /// which is possible for a page or a frame, and not for a subresource.
        case redirect(Redirect)
        /// Rewrite the request's headers, with the same limitation.
        case modifyHeaders([HeaderChange])
    }

    /// Where a `redirect` rule sends the request. Chrome allows four ways of
    /// saying it and an extension may use any one of them.
    struct Redirect: Equatable, Sendable {
        var url: String?
        /// A file inside the extension itself.
        var extensionPath: String?
        /// A replacement built from a `regexFilter`'s capture groups.
        var regexSubstitution: String?
        var transform: Transform?
    }

    /// A redirect written as changes to the parts of the URL.
    struct Transform: Equatable, Sendable {
        var scheme: String?
        var host: String?
        var port: String?
        var path: String?
        var query: String?
        var fragment: String?
        var queryTransform: QueryTransform?
    }

    struct QueryTransform: Equatable, Sendable {
        var removeParams: [String] = []
        var addOrReplaceParams: [QueryParameter] = []
    }

    struct QueryParameter: Equatable, Sendable {
        var key: String
        var value: String
        /// Only replace one that is already there; do not add it.
        var replaceOnly: Bool
    }

    /// One change to one header.
    struct HeaderChange: Equatable, Sendable {
        var header: String
        /// `set`, `remove` or `append`.
        var operation: String
        var value: String?
    }

    /// Which requests it matches.
    struct Condition: Equatable, Sendable {
        var urlFilter: String?
        var regexFilter: String?
        var isUrlFilterCaseSensitive = false
        /// The page the request was made from.
        var initiatorDomains: [String] = []
        var excludedInitiatorDomains: [String] = []
        /// The host being requested.
        var requestDomains: [String] = []
        var excludedRequestDomains: [String] = []
        var resourceTypes: [String] = []
        var excludedResourceTypes: [String] = []
        var requestMethods: [String] = []
        var excludedRequestMethods: [String] = []
        /// `firstParty` or `thirdParty`.
        var domainType: String?
        var tabIDs: [Int] = []
        var excludedTabIDs: [Int] = []
    }

    let id: Int
    /// Chrome's default when a rule does not say. Higher wins.
    let priority: Int
    let action: Action
    let condition: Condition

    /// Why a rule was not taken, in words the Extensions pane can print.
    struct Rejection: Error, Equatable, Sendable {
        let id: Int?
        let reason: String
    }

    /// Reads one rule. The identifier and the action are the only parts
    /// Chrome insists on, so those are the only parts refused outright.
    static func parse(_ value: Any) -> Result<DNRRule, Rejection> {
        guard let object = value as? [String: Any] else {
            return .failure(Rejection(id: nil, reason: "A rule must be a JSON object."))
        }
        guard let id = integer(object["id"]) else {
            return .failure(Rejection(id: nil, reason: "A rule needs a numeric \"id\"."))
        }
        guard let actionObject = object["action"] as? [String: Any],
              let actionType = actionObject["type"] as? String else {
            return .failure(Rejection(id: id, reason: "A rule needs an \"action\" with a \"type\"."))
        }
        let action: Action
        switch actionType {
        case "block": action = .block
        case "allow": action = .allow
        case "allowAllRequests": action = .allowAllRequests
        case "upgradeScheme": action = .upgradeScheme
        case "redirect":
            guard let redirect = readRedirect(actionObject["redirect"]) else {
                return .failure(Rejection(id: id, reason: "A redirect rule needs somewhere to redirect to."))
            }
            action = .redirect(redirect)
        case "modifyHeaders":
            // Only request headers: a response has already been fetched by the
            // time this browser could see it.
            let changes = readHeaderChanges(actionObject["requestHeaders"])
            guard !changes.isEmpty else {
                return .failure(Rejection(id: id, reason: "This rule only changes response headers, which cannot be changed here."))
            }
            action = .modifyHeaders(changes)
        default:
            return .failure(Rejection(id: id, reason: "\"\(actionType)\" is not a rule action."))
        }

        var condition = Condition()
        if let source = object["condition"] as? [String: Any] {
            condition.urlFilter = source["urlFilter"] as? String
            condition.regexFilter = source["regexFilter"] as? String
            condition.isUrlFilterCaseSensitive = (source["isUrlFilterCaseSensitive"] as? Bool) ?? false
            // `domains` and `excludedDomains` are what the same condition was
            // called before Chrome renamed them; extensions in the wild still
            // ship both spellings.
            condition.initiatorDomains = strings(source["initiatorDomains"]) + strings(source["domains"])
            condition.excludedInitiatorDomains =
                strings(source["excludedInitiatorDomains"]) + strings(source["excludedDomains"])
            condition.requestDomains = strings(source["requestDomains"])
            condition.excludedRequestDomains = strings(source["excludedRequestDomains"])
            condition.resourceTypes = strings(source["resourceTypes"])
            condition.excludedResourceTypes = strings(source["excludedResourceTypes"])
            condition.requestMethods = strings(source["requestMethods"])
            condition.excludedRequestMethods = strings(source["excludedRequestMethods"])
            condition.domainType = source["domainType"] as? String
            condition.tabIDs = integers(source["tabIds"])
            condition.excludedTabIDs = integers(source["excludedTabIds"])
        }
        if condition.urlFilter != nil && condition.regexFilter != nil {
            return .failure(Rejection(id: id, reason: "A rule may have \"urlFilter\" or \"regexFilter\", not both."))
        }
        return .success(DNRRule(
            id: id,
            priority: integer(object["priority"]) ?? 1,
            action: action,
            condition: condition
        ))
    }

    /// Reads a whole ruleset, keeping the rules it understood and the reasons
    /// for the ones it did not. A single bad rule does not lose the file.
    static func parseAll(_ value: Any) -> (rules: [DNRRule], rejected: [Rejection]) {
        guard let list = value as? [Any] else {
            return ([], [Rejection(id: nil, reason: "A ruleset file must be a JSON array of rules.")])
        }
        var rules: [DNRRule] = []
        var rejected: [Rejection] = []
        for entry in list {
            switch parse(entry) {
            case .success(let rule): rules.append(rule)
            case .failure(let rejection): rejected.append(rejection)
            }
        }
        return (rules, rejected)
    }


    private static func readRedirect(_ value: Any?) -> Redirect? {
        guard let object = value as? [String: Any] else { return nil }
        var redirect = Redirect()
        redirect.url = object["url"] as? String
        redirect.extensionPath = object["extensionPath"] as? String
        redirect.regexSubstitution = object["regexSubstitution"] as? String
        if let source = object["transform"] as? [String: Any] {
            var transform = Transform()
            transform.scheme = source["scheme"] as? String
            transform.host = source["host"] as? String
            transform.port = source["port"] as? String
            transform.path = source["path"] as? String
            transform.query = source["query"] as? String
            transform.fragment = source["fragment"] as? String
            if let query = source["queryTransform"] as? [String: Any] {
                var queryTransform = QueryTransform()
                queryTransform.removeParams = strings(query["removeParams"])
                for entry in (query["addOrReplaceParams"] as? [Any]) ?? [] {
                    guard let parameter = entry as? [String: Any],
                          let key = parameter["key"] as? String else { continue }
                    queryTransform.addOrReplaceParams.append(QueryParameter(
                        key: key,
                        value: (parameter["value"] as? String) ?? "",
                        replaceOnly: (parameter["replaceOnly"] as? Bool) ?? false
                    ))
                }
                transform.queryTransform = queryTransform
            }
            redirect.transform = transform
        }
        // A redirect that says nothing is not a redirect.
        guard redirect.url != nil || redirect.extensionPath != nil
                || redirect.regexSubstitution != nil || redirect.transform != nil else { return nil }
        return redirect
    }

    private static func readHeaderChanges(_ value: Any?) -> [HeaderChange] {
        guard let list = value as? [Any] else { return [] }
        return list.compactMap { entry in
            guard let object = entry as? [String: Any],
                  let header = object["header"] as? String,
                  let operation = object["operation"] as? String,
                  ["set", "remove", "append"].contains(operation) else { return nil }
            // A header that is being set must have something to be set to.
            let text = object["value"] as? String
            if operation != "remove", text == nil { return nil }
            return HeaderChange(header: header, operation: operation, value: text)
        }
    }

    // JSON numbers arrive as `NSNumber`, and an extension that wrote `"id": 1`
    // as a string is common enough to be worth reading rather than refusing.
    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    private static func integers(_ value: Any?) -> [Int] {
        (value as? [Any])?.compactMap { integer($0) } ?? []
    }

    private static func strings(_ value: Any?) -> [String] {
        (value as? [Any])?.compactMap { $0 as? String } ?? []
    }
}
