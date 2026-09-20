import CryptoKit
import Foundation
import WebKit

/// Makes an extension's `declarativeNetRequest` rules actually block things.
///
/// WebKit's extension engine does not implement the API, so an MV3 content
/// blocker installs cleanly, reports no error, and lets every advert through.
/// Kylmora reads the rules itself, translates them into a `WKContentRuleList`
/// and hands that to the web views of the Spaces where the extension is
/// enabled -- the same mechanism Kylmora's own filter lists use, so the
/// matching costs no more than theirs does.
@MainActor
final class DeclarativeNetRequestService {
    static let shared = DeclarativeNetRequestService()

    /// One extension's rules and what became of them.
    struct Entry {
        var folder: URL
        var definition: DeclarativeNetRequestDefinition
        /// Static rulesets currently switched on.
        var enabledRulesets: Set<String>
        /// Rules added at runtime, which outlive a launch.
        var dynamicRules: [DNRRule] = []
        /// Rules added at runtime that do not.
        var sessionRules: [DNRRule] = []
        /// The compiled result, once WebKit has it.
        var compiled: WKContentRuleList?
        var identifier: String?
        /// What could not be translated, for the Extensions pane.
        var unsupported: [DeclarativeNetRequestCompiler.Unsupported] = []
        /// What works, but only when a page or a frame navigates.
        var navigationOnly: [DeclarativeNetRequestCompiler.Unsupported] = []
        /// Rules that were not valid DNR at all.
        var rejected: [DNRRule.Rejection] = []
        var translated = 0
    }

    private(set) var entries: [UUID: Entry] = [:]
    private let ruleStore: WKContentRuleListStore
    private let defaults: UserDefaults
    private static let storageKey = "extensionNetRequestState"

    /// Whether an extension is switched on for a Space. Set by the extension
    /// manager, which is the only thing that knows.
    var isEnabledInSpace: ((UUID, Space.Identity) -> Bool)?
    /// Something changed and the web views need the new lists.
    var onChange: (() -> Void)?
    /// An extension's own `chrome-extension://` root, for a redirect that
    /// points at a file inside it.
    var extensionBaseURL: ((UUID) -> URL?)?

    init(ruleStore: WKContentRuleListStore = .default(), defaults: UserDefaults = .standard) {
        self.ruleStore = ruleStore
        self.defaults = defaults
    }

    // MARK: - What the web views ask for

    /// The lists to add to a web view in this Space: every enabled extension's,
    /// in a settled order so two web views in the same Space match alike.
    func ruleLists(for identity: Space.Identity) -> [WKContentRuleList] {
        entries
            .filter { id, entry in entry.compiled != nil && (isEnabledInSpace?(id, identity) ?? true) }
            .sorted { $0.key.uuidString < $1.key.uuidString }
            .compactMap { $0.value.compiled }
    }

    // MARK: - Loading

    /// Reads an extension's manifest and rule files and compiles them. Called
    /// on every load, not only the first, so a rule file that changed with an
    /// update is picked up.
    func load(recordID: UUID, folder: URL) async {
        guard let data = try? Data(contentsOf: folder.appending(path: "manifest.json")),
              let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              DeclarativeNetRequestDefinition.wantsAPI(manifest) else {
            forget(recordID: recordID)
            return
        }
        let definition = DeclarativeNetRequestDefinition.read(from: manifest)
        let stored = storedState()[recordID.uuidString]
        var entry = entries[recordID] ?? Entry(
            folder: folder,
            definition: definition,
            enabledRulesets: []
        )
        entry.folder = folder
        entry.definition = definition
        // An extension's own default holds until the person or the extension
        // has said otherwise; after that the stored answer wins.
        if let remembered = stored?.enabledRulesets {
            entry.enabledRulesets = Set(remembered).intersection(definition.rulesets.map(\.id))
        } else {
            entry.enabledRulesets = Set(definition.rulesets.filter(\.isEnabledByDefault).map(\.id))
        }
        if let remembered = stored?.dynamicRules {
            entry.dynamicRules = remembered
        }
        entries[recordID] = entry
        await recompile(recordID)
    }

    func forget(recordID: UUID) {
        if let identifier = entries[recordID]?.identifier {
            ruleStore.removeContentRuleList(forIdentifier: identifier) { _ in }
        }
        guard entries.removeValue(forKey: recordID) != nil else { return }
        var state = storedState()
        state.removeValue(forKey: recordID.uuidString)
        save(state)
        onChange?()
    }

    // MARK: - The API's own calls

    /// `updateEnabledRulesets`.
    func setRulesets(enabled: [String], disabled: [String], for recordID: UUID) async {
        guard var entry = entries[recordID] else { return }
        let known = Set(entry.definition.rulesets.map(\.id))
        entry.enabledRulesets.subtract(disabled)
        entry.enabledRulesets.formUnion(Set(enabled).intersection(known))
        entries[recordID] = entry
        persist(recordID)
        await recompile(recordID)
    }

    /// `updateDynamicRules` and `updateSessionRules`. Removals happen before
    /// additions, which is Chrome's order and matters when a call replaces a
    /// rule by reusing its identifier.
    func updateRules(
        removeIDs: [Int],
        add: [DNRRule],
        session: Bool,
        for recordID: UUID
    ) async {
        guard var entry = entries[recordID] else { return }
        var rules = session ? entry.sessionRules : entry.dynamicRules
        let removing = Set(removeIDs).union(add.map(\.id))
        rules.removeAll { removing.contains($0.id) }
        rules.append(contentsOf: add)
        if session { entry.sessionRules = rules } else { entry.dynamicRules = rules }
        entries[recordID] = entry
        if !session { persist(recordID) }
        await recompile(recordID)
    }

    func rules(session: Bool, for recordID: UUID) -> [DNRRule] {
        guard let entry = entries[recordID] else { return [] }
        return session ? entry.sessionRules : entry.dynamicRules
    }

    /// What the Extensions pane says about an extension's blocking rules.
    /// Not an error, so it is not phrased or coloured as one -- but a blocker
    /// that silently lost a tenth of its rules is something to be told about.
    func summary(for recordID: UUID) -> String? {
        guard let entry = entries[recordID], !entry.definition.isEmpty
                || entry.translated > 0 || !entry.dynamicRules.isEmpty else { return nil }
        var parts: [String] = []
        parts.append(entry.translated == 1 ? "1 blocking rule active" : "\(entry.translated) blocking rules active")
        if !entry.navigationOnly.isEmpty {
            parts.append("\(entry.navigationOnly.count) applying to pages and frames only")
        }
        let refused = entry.unsupported.count + entry.rejected.count
        if refused > 0 {
            parts.append(refused == 1 ? "1 this browser could not take" : "\(refused) this browser could not take")
        }
        return parts.joined(separator: ", ") + "."
    }

    func enabledRulesets(for recordID: UUID) -> [String] {
        (entries[recordID]?.enabledRulesets).map { Array($0).sorted() } ?? []
    }

    // MARK: - Compiling

    /// Every rule the extension currently has, static and runtime, in the
    /// order Chrome would consider them.
    func allRules(for recordID: UUID) -> (rules: [DNRRule], rejected: [DNRRule.Rejection]) {
        guard let entry = entries[recordID] else { return ([], []) }
        var rules: [DNRRule] = []
        var rejected: [DNRRule.Rejection] = []
        for ruleset in entry.definition.rulesets where entry.enabledRulesets.contains(ruleset.id) {
            let read = DeclarativeNetRequestDefinition.rules(for: ruleset, in: entry.folder)
            rules.append(contentsOf: read.rules)
            rejected.append(contentsOf: read.rejected)
        }
        // Runtime rules sit above the static ones at equal priority, which is
        // what Chrome does: a dynamic rule is the more recent word.
        rules.append(contentsOf: entry.dynamicRules)
        rules.append(contentsOf: entry.sessionRules)
        return (rules, rejected)
    }

    private func recompile(_ recordID: UUID) async {
        guard var entry = entries[recordID] else { return }
        let read = allRules(for: recordID)
        let compilation = DeclarativeNetRequestCompiler.compile(read.rules)
        entry.rejected = read.rejected
        entry.unsupported = compilation.unsupported
        entry.navigationOnly = compilation.navigationOnly
        entry.translated = compilation.translated

        let previous = entry.identifier
        if compilation.translated == 0 {
            // Nothing for the content list. The navigation rules still stand.
            entry.compiled = nil
            entry.identifier = nil
            entries[recordID] = entry
            if let previous { ruleStore.removeContentRuleList(forIdentifier: previous) { _ in } }
            onChange?()
            return
        }

        // Keyed by what was compiled, so an unchanged extension reuses the
        // list WebKit already holds instead of compiling it again at launch.
        let identifier = "kylmora-dnr-\(recordID.uuidString)-\(Self.fingerprint(compilation.json))"
        entry.identifier = identifier
        entries[recordID] = entry

        if let existing = await lookUp(identifier) {
            adopt(existing, identifier: identifier, for: recordID, replacing: previous)
            return
        }
        do {
            let list = try await ruleStore.compileContentRuleList(
                forIdentifier: identifier, encodedContentRuleList: compilation.json
            )
            guard let list else { return }
            adopt(list, identifier: identifier, for: recordID, replacing: previous)
        } catch {
            guard var failed = entries[recordID] else { return }
            failed.compiled = nil
            failed.identifier = nil
            failed.unsupported.append(DeclarativeNetRequestCompiler.Unsupported(
                id: 0, reason: "The rules could not be compiled: \(error.localizedDescription)"
            ))
            entries[recordID] = failed
            onChange?()
        }
    }

    private func adopt(_ list: WKContentRuleList, identifier: String, for recordID: UUID, replacing previous: String?) {
        guard var entry = entries[recordID], entry.identifier == identifier else { return }
        entry.compiled = list
        entries[recordID] = entry
        if let previous, previous != identifier {
            ruleStore.removeContentRuleList(forIdentifier: previous) { _ in }
        }
        onChange?()
    }

    private func lookUp(_ identifier: String) async -> WKContentRuleList? {
        await withCheckedContinuation { continuation in
            ruleStore.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
                continuation.resume(returning: list)
            }
        }
    }

    private static func fingerprint(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    // MARK: - What survives a launch

    private struct StoredEntry {
        var enabledRulesets: [String]?
        var dynamicRules: [DNRRule]?
    }

    private func storedState() -> [String: StoredEntry] {
        guard let raw = defaults.dictionary(forKey: Self.storageKey) else { return [:] }
        var state: [String: StoredEntry] = [:]
        for (key, value) in raw {
            guard let object = value as? [String: Any] else { continue }
            var entry = StoredEntry()
            entry.enabledRulesets = (object["enabledRulesets"] as? [Any])?.compactMap { $0 as? String }
            if let text = object["dynamicRules"] as? String,
               let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)) {
                entry.dynamicRules = DNRRule.parseAll(value).rules
            }
            state[key] = entry
        }
        return state
    }

    private func persist(_ recordID: UUID) {
        guard let entry = entries[recordID] else { return }
        var state = defaults.dictionary(forKey: Self.storageKey) ?? [:]
        var object: [String: Any] = ["enabledRulesets": Array(entry.enabledRulesets).sorted()]
        if !entry.dynamicRules.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: entry.dynamicRules.map(Self.encode)),
           let text = String(data: data, encoding: .utf8) {
            object["dynamicRules"] = text
        }
        state[recordID.uuidString] = object
        defaults.set(state, forKey: Self.storageKey)
    }

    private func save(_ state: [String: StoredEntry]) {
        var raw: [String: Any] = [:]
        for (key, entry) in state {
            var object: [String: Any] = [:]
            if let rulesets = entry.enabledRulesets { object["enabledRulesets"] = rulesets }
            if let rules = entry.dynamicRules, !rules.isEmpty,
               let data = try? JSONSerialization.data(withJSONObject: rules.map(Self.encode)),
               let text = String(data: data, encoding: .utf8) {
                object["dynamicRules"] = text
            }
            raw[key] = object
        }
        defaults.set(raw, forKey: Self.storageKey)
    }

    /// A rule back in the shape it arrived in, so a stored one reads the same
    /// way an extension's own does.
    static func encode(_ rule: DNRRule) -> [String: Any] {
        var action: [String: Any] = [:]
        switch rule.action {
        case .block: action["type"] = "block"
        case .allow: action["type"] = "allow"
        case .allowAllRequests: action["type"] = "allowAllRequests"
        case .upgradeScheme: action["type"] = "upgradeScheme"
        case .redirect(let redirect):
            action["type"] = "redirect"
            var target: [String: Any] = [:]
            if let value = redirect.url { target["url"] = value }
            if let value = redirect.extensionPath { target["extensionPath"] = value }
            if let value = redirect.regexSubstitution { target["regexSubstitution"] = value }
            if let transform = redirect.transform {
                var encoded: [String: Any] = [:]
                if let value = transform.scheme { encoded["scheme"] = value }
                if let value = transform.host { encoded["host"] = value }
                if let value = transform.port { encoded["port"] = value }
                if let value = transform.path { encoded["path"] = value }
                if let value = transform.query { encoded["query"] = value }
                if let value = transform.fragment { encoded["fragment"] = value }
                if let query = transform.queryTransform {
                    var queryEncoded: [String: Any] = [:]
                    if !query.removeParams.isEmpty { queryEncoded["removeParams"] = query.removeParams }
                    if !query.addOrReplaceParams.isEmpty {
                        queryEncoded["addOrReplaceParams"] = query.addOrReplaceParams.map {
                            ["key": $0.key, "value": $0.value, "replaceOnly": $0.replaceOnly]
                        }
                    }
                    encoded["queryTransform"] = queryEncoded
                }
                target["transform"] = encoded
            }
            action["redirect"] = target
        case .modifyHeaders(let changes):
            action["type"] = "modifyHeaders"
            action["requestHeaders"] = changes.map { change -> [String: Any] in
                var encoded: [String: Any] = ["header": change.header, "operation": change.operation]
                if let value = change.value { encoded["value"] = value }
                return encoded
            }
        }
        var condition: [String: Any] = [:]
        if let value = rule.condition.urlFilter { condition["urlFilter"] = value }
        if let value = rule.condition.regexFilter { condition["regexFilter"] = value }
        if rule.condition.isUrlFilterCaseSensitive { condition["isUrlFilterCaseSensitive"] = true }
        if !rule.condition.initiatorDomains.isEmpty { condition["initiatorDomains"] = rule.condition.initiatorDomains }
        if !rule.condition.excludedInitiatorDomains.isEmpty {
            condition["excludedInitiatorDomains"] = rule.condition.excludedInitiatorDomains
        }
        if !rule.condition.requestDomains.isEmpty { condition["requestDomains"] = rule.condition.requestDomains }
        if !rule.condition.excludedRequestDomains.isEmpty {
            condition["excludedRequestDomains"] = rule.condition.excludedRequestDomains
        }
        if !rule.condition.resourceTypes.isEmpty { condition["resourceTypes"] = rule.condition.resourceTypes }
        if !rule.condition.excludedResourceTypes.isEmpty {
            condition["excludedResourceTypes"] = rule.condition.excludedResourceTypes
        }
        if !rule.condition.requestMethods.isEmpty { condition["requestMethods"] = rule.condition.requestMethods }
        if let value = rule.condition.domainType { condition["domainType"] = value }
        return ["id": rule.id, "priority": rule.priority, "action": action, "condition": condition]
    }
}

extension DeclarativeNetRequestService {
    /// What the shim's calls come back as. Not `Sendable`: the values are
    /// JSON the engine hands straight back to the page, and they never leave
    /// the main actor.
    enum Reply {
        case value(Any?)
        case failure(String)
    }

    /// One call from an extension's own code. The method names are Chrome's.
    func perform(_ method: String, arguments: [String: Any], for recordID: UUID) async -> Reply {
        guard entries[recordID] != nil else {
            return .failure("This extension did not ask for declarativeNetRequest.")
        }
        switch method {
        case "updateDynamicRules", "updateSessionRules":
            let session = method == "updateSessionRules"
            let removals = (arguments["removeRuleIds"] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? []
            var additions: [DNRRule] = []
            for entry in (arguments["addRules"] as? [Any]) ?? [] {
                switch DNRRule.parse(entry) {
                case .success(let rule): additions.append(rule)
                case .failure(let rejection): return .failure(rejection.reason)
                }
            }
            await updateRules(removeIDs: removals, add: additions, session: session, for: recordID)
            return .value(nil)

        case "getDynamicRules", "getSessionRules":
            let session = method == "getSessionRules"
            var answer = rules(session: session, for: recordID)
            // Chrome's optional filter, which uBO and friends do pass.
            if let filter = arguments["filter"] as? [String: Any],
               let wanted = (filter["ruleIds"] as? [Any])?.compactMap({ ($0 as? NSNumber)?.intValue }),
               !wanted.isEmpty {
                let keep = Set(wanted)
                answer = answer.filter { keep.contains($0.id) }
            }
            return .value(answer.map(Self.encode))

        case "updateEnabledRulesets":
            let enable = (arguments["enableRulesetIds"] as? [Any])?.compactMap { $0 as? String } ?? []
            let disable = (arguments["disableRulesetIds"] as? [Any])?.compactMap { $0 as? String } ?? []
            await setRulesets(enabled: enable, disabled: disable, for: recordID)
            return .value(nil)

        case "getEnabledRulesets":
            return .value(enabledRulesets(for: recordID))

        case "getAvailableStaticRuleCount":
            let used = entries[recordID]?.translated ?? 0
            return .value(max(0, DeclarativeNetRequestCompiler.maximumRules - used))

        case "isRegexSupported":
            let pattern = arguments["regex"] as? String ?? ""
            let supported = DeclarativeNetRequestCompiler.isSupportedRegex(pattern)
            return .value(supported
                ? ["isSupported": true]
                : ["isSupported": false, "reason": "syntaxError"])

        case "getMatchedRules":
            // Kylmora does not keep a log of what matched: the matching happens
            // inside WebKit's own engine, which does not report it. An empty
            // list is the honest answer, and the shape Chrome returns.
            return .value(["rulesMatchedInfo": []])

        case "setExtensionActionOptions":
            // Badge counts of blocked requests: nothing to count, for the same
            // reason `getMatchedRules` is empty.
            return .value(nil)

        default:
            return .failure("\"\(method)\" is not a declarativeNetRequest method Kylmora answers.")
        }
    }

    static func isBrokerHost(_ name: String?) -> Bool {
        name == DeclarativeNetRequestShim.brokerHostName
    }
}

extension DeclarativeNetRequestService {
    /// What an extension wants done with a navigation, for the rules WebKit's
    /// content matcher cannot express. Nothing here touches subresources --
    /// only a page or a frame, which is all that can be intercepted.
    ///
    /// Across extensions the first decisive answer wins, extensions taken in a
    /// settled order, except that an explicit `allow` stops the search: a rule
    /// that says to leave a request alone should not be overruled by one that
    /// merely happens to be considered later.
    func navigationDecision(
        request: URLRequest,
        isMainFrame: Bool,
        pageURL: URL?,
        identity: Space.Identity
    ) -> DeclarativeNetRequestNavigation.Outcome {
        // Two rules can point at each other. Whatever was just redirected to
        // is left alone for a moment, which turns a ping-pong into a single
        // hop rather than a browser that never settles.
        if let url = request.url?.absoluteString,
           let sent = Self.recentRedirects[url], Date().timeIntervalSince(sent) < 3 {
            return .proceed
        }
        let applicable = entries
            .filter { id, _ in isEnabledInSpace?(id, identity) ?? true }
            .sorted { $0.key.uuidString < $1.key.uuidString }
        for (id, _) in applicable {
            let rules = allRules(for: id).rules.filter(Self.actsAtNavigationTime)
            guard !rules.isEmpty else { continue }
            let decision = DeclarativeNetRequestNavigation.decide(
                request: request,
                isMainFrame: isMainFrame,
                pageURL: pageURL,
                rules: rules,
                extensionBaseURL: extensionBaseURL?(id)
            )
            switch decision.outcome {
            case .proceed where decision.ruleID != nil:
                return .proceed
            case .proceed:
                continue
            case .replace(let replacement):
                if let url = replacement.url?.absoluteString {
                    Self.recentRedirects = Self.recentRedirects.filter { Date().timeIntervalSince($0.value) < 3 }
                    Self.recentRedirects[url] = Date()
                }
                return decision.outcome
            default:
                return decision.outcome
            }
        }
        return .proceed
    }

    /// Where a redirect has just sent something, and when.
    private static var recentRedirects: [String: Date] = [:]

    /// The rules worth asking about at navigation time: the two actions the
    /// content matcher cannot do, plus the allows that could countermand them.
    private static func actsAtNavigationTime(_ rule: DNRRule) -> Bool {
        switch rule.action {
        case .redirect, .modifyHeaders, .allow, .allowAllRequests: return true
        case .block, .upgradeScheme: return false
        }
    }

    /// Whether any loaded extension has a rule that needs deciding at
    /// navigation time. Checked first so an ordinary page load costs nothing.
    var hasNavigationRules: Bool {
        entries.keys.contains { !allRules(for: $0).rules.filter(Self.actsAtNavigationTime).isEmpty }
    }
}
