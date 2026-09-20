import Foundation
import Testing
import WebKit
@testable import Kylmora


/// Reading a parse result the way the tests want to talk about it.
private extension Result where Success == DNRRule, Failure == DNRRule.Rejection {
    var value: DNRRule? { try? get() }
    var failureReason: String? {
        if case .failure(let rejection) = self { return rejection.reason }
        return nil
    }
}

@Suite("declarativeNetRequest")
@MainActor
struct DeclarativeNetRequestTests {
    private func rules(_ json: String) -> [DNRRule] {
        let value = try! JSONSerialization.jsonObject(with: Data(json.utf8))
        let parsed = DNRRule.parseAll(value)
        #expect(parsed.rejected.isEmpty, "fixture should parse cleanly")
        return parsed.rules
    }

    @Test("What the compiler emits is something WebKit will actually compile")
    func realWebKitAcceptsTheOutput() async throws {
        let compiled = DeclarativeNetRequestCompiler.compile(rules("""
        [
          {"id": 1, "priority": 1, "action": {"type": "block"},
           "condition": {"urlFilter": "||ads.example.com^", "resourceTypes": ["script", "image"]}},
          {"id": 2, "priority": 2, "action": {"type": "allow"},
           "condition": {"urlFilter": "||ads.example.com/ok", "initiatorDomains": ["news.example"]}},
          {"id": 3, "priority": 1, "action": {"type": "block"},
           "condition": {"urlFilter": "/track", "resourceTypes": ["sub_frame"]}},
          {"id": 4, "priority": 1, "action": {"type": "block"},
           "condition": {"urlFilter": "/topad", "resourceTypes": ["main_frame"]}},
          {"id": 5, "priority": 1, "action": {"type": "upgradeScheme"},
           "condition": {"urlFilter": "||insecure.example^"}},
          {"id": 6, "priority": 1, "action": {"type": "block"},
           "condition": {"regexFilter": "^https?://[a-z]+\\\\.doubleclick\\\\.net/", "domainType": "thirdParty"}},
          {"id": 7, "priority": 1, "action": {"type": "block"},
           "condition": {"requestDomains": ["tracker.example", "beacon.example"]}}
        ]
        """))
        #expect(compiled.translated == 8, "the two requested hosts become a rule each")
        #expect(compiled.unsupported.isEmpty)

        // The real store, the real compiler. If WebKit will not take a trigger
        // this produces, that is a bug here and not a detail.
        let store = try #require(WKContentRuleListStore.default())
        let entries = try JSONSerialization.jsonObject(with: Data(compiled.json.utf8)) as! [[String: Any]]
        for entry in entries {
            let one = String(data: try JSONSerialization.data(withJSONObject: [entry]), encoding: .utf8)!
            let identifier = "kylmora-dnr-test-\(UUID().uuidString)"
            do {
                _ = try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: one)
                try? await store.removeContentRuleList(forIdentifier: identifier)
            } catch {
                Issue.record("WebKit refused: \(one) -- \(error)")
            }
        }
    }

    private func trigger(_ compiled: DeclarativeNetRequestCompiler.Compilation, _ index: Int) -> [String: Any] {
        let entries = (try? JSONSerialization.jsonObject(with: Data(compiled.json.utf8))) as? [[String: Any]] ?? []
        return entries.indices.contains(index) ? (entries[index]["trigger"] as? [String: Any] ?? [:]) : [:]
    }

    private func action(_ compiled: DeclarativeNetRequestCompiler.Compilation, _ index: Int) -> String {
        let entries = (try? JSONSerialization.jsonObject(with: Data(compiled.json.utf8))) as? [[String: Any]] ?? []
        guard entries.indices.contains(index) else { return "" }
        return (entries[index]["action"] as? [String: Any])?["type"] as? String ?? ""
    }

    // MARK: - Reading an extension's rules

    @Test("A rule needs an id and an action, and says so when it has neither")
    func parsingRefusals() {
        #expect(DNRRule.parse(["action": ["type": "block"]]).failureReason?.contains("id") == true)
        #expect(DNRRule.parse(["id": 1]).failureReason?.contains("action") == true)
        #expect(DNRRule.parse(["id": 1, "action": ["type": "teleport"]]).failureReason?.contains("teleport") == true)
        #expect(DNRRule.parse("not an object").failureReason != nil)
        #expect(DNRRule.parse([
            "id": 1, "action": ["type": "block"],
            "condition": ["urlFilter": "a", "regexFilter": "b"]
        ]).failureReason?.contains("not both") == true)
    }

    @Test("One bad rule does not lose the rest of the file")
    func parsingKeepsTheGood() {
        let parsed = DNRRule.parseAll([
            ["id": 1, "action": ["type": "block"], "condition": ["urlFilter": "a"]],
            ["action": ["type": "block"]],
            ["id": 3, "action": ["type": "allow"], "condition": ["urlFilter": "b"]]
        ])
        #expect(parsed.rules.map(\.id) == [1, 3])
        #expect(parsed.rejected.count == 1)
    }

    @Test("Priority defaults to Chrome's, and the older spelling of domains is still read")
    func parsingDefaults() throws {
        let rule = try #require(DNRRule.parse([
            "id": 7, "action": ["type": "block"],
            "condition": ["urlFilter": "x", "domains": ["old.example"], "excludedDomains": ["skip.example"]]
        ]).value)
        #expect(rule.priority == 1)
        #expect(rule.condition.initiatorDomains == ["old.example"])
        #expect(rule.condition.excludedInitiatorDomains == ["skip.example"])
    }

    // MARK: - Translating them

    @Test("An allow rule is emitted after the block it is meant to beat")
    func priorityBecomesOrder() {
        let compiled = DeclarativeNetRequestCompiler.compile([
            DNRRule.parse(["id": 1, "priority": 2, "action": ["type": "allow"],
                           "condition": ["urlFilter": "||example.com/ok"]]).value!,
            DNRRule.parse(["id": 2, "priority": 1, "action": ["type": "block"],
                           "condition": ["urlFilter": "||example.com^"]]).value!
        ])
        // WebKit takes the last match that says so, so the winner goes last.
        #expect(action(compiled, 0) == "block")
        #expect(action(compiled, 1) == "ignore-previous-rules")
    }

    @Test("At equal priority an allow still beats a block, which is Chrome's rule")
    func allowBeatsBlockAtEqualPriority() {
        let compiled = DeclarativeNetRequestCompiler.compile([
            DNRRule.parse(["id": 1, "priority": 1, "action": ["type": "allow"],
                           "condition": ["urlFilter": "/ok"]]).value!,
            DNRRule.parse(["id": 2, "priority": 1, "action": ["type": "block"],
                           "condition": ["urlFilter": "/ad"]]).value!
        ])
        #expect(action(compiled, 0) == "block")
        #expect(action(compiled, 1) == "ignore-previous-rules")
    }

    @Test("A sub-frame rule does not take the whole page down with it")
    func subFrameKeepsTheTopFrameLoading() {
        let child = DeclarativeNetRequestCompiler.compile([
            DNRRule.parse(["id": 1, "action": ["type": "block"],
                           "condition": ["urlFilter": "/ad", "resourceTypes": ["sub_frame"]]]).value!
        ])
        #expect(trigger(child, 0)["load-context"] as? [String] == ["child-frame"])

        let top = DeclarativeNetRequestCompiler.compile([
            DNRRule.parse(["id": 1, "action": ["type": "block"],
                           "condition": ["urlFilter": "/ad", "resourceTypes": ["main_frame"]]]).value!
        ])
        #expect(trigger(top, 0)["load-context"] as? [String] == ["top-frame"])

        // Both named: no context, because there is nothing to tell apart.
        let either = DeclarativeNetRequestCompiler.compile([
            DNRRule.parse(["id": 1, "action": ["type": "block"],
                           "condition": ["urlFilter": "/ad", "resourceTypes": ["main_frame", "sub_frame"]]]).value!
        ])
        #expect(trigger(either, 0)["load-context"] == nil)
    }

    @Test("A rule that names no type does not block the page itself")
    func untypedRulesSpareTheDocument() {
        let compiled = DeclarativeNetRequestCompiler.compile([
            DNRRule.parse(["id": 1, "action": ["type": "block"], "condition": ["urlFilter": "/ad"]]).value!
        ])
        let types = trigger(compiled, 0)["resource-type"] as? [String]
        #expect(types == nil || types?.contains("document") == false,
                "a browser that blocks the top-level document will not load the site")
    }

    @Test("Initiator domains become WebKit's domain trigger, subdomains included")
    func initiatorDomains() {
        let compiled = DeclarativeNetRequestCompiler.compile([
            DNRRule.parse(["id": 1, "action": ["type": "block"],
                           "condition": ["urlFilter": "/ad",
                                         "initiatorDomains": ["Example.COM"],
                                         "excludedInitiatorDomains": ["safe.example"]]]).value!
        ])
        #expect(trigger(compiled, 0)["if-domain"] as? [String] == ["*example.com"])
        #expect(trigger(compiled, 0)["unless-domain"] as? [String] == ["*safe.example"])
    }

    @Test("Third-party becomes WebKit's load type")
    func domainType() {
        let compiled = DeclarativeNetRequestCompiler.compile([
            DNRRule.parse(["id": 1, "action": ["type": "block"],
                           "condition": ["urlFilter": "/ad", "domainType": "thirdParty"]]).value!
        ])
        #expect(trigger(compiled, 0)["load-type"] as? [String] == ["third-party"])
    }

    @Test("A list of requested hosts becomes one rule each, because the matcher refuses a group")
    func requestedHostsExpand() {
        let compiled = DeclarativeNetRequestCompiler.compile([
            DNRRule.parse(["id": 1, "action": ["type": "block"],
                           "condition": ["requestDomains": ["a.example", "b.example"]]]).value!
        ])
        #expect(compiled.translated == 2)
        #expect((trigger(compiled, 0)["url-filter"] as? String)?.contains("a\\.example") == true)
        #expect((trigger(compiled, 1)["url-filter"] as? String)?.contains("b\\.example") == true)
    }

    @Test("What cannot be translated is refused by name, with a reason", arguments: [
        ("{\"type\": \"block\"}", "{\"urlFilter\": \"/a\", \"requestMethods\": [\"post\"]}", "method"),
        ("{\"type\": \"block\"}", "{\"urlFilter\": \"/a\", \"tabIds\": [3]}", "tab"),
        ("{\"type\": \"block\"}", "{\"urlFilter\": \"/a\", \"excludedRequestDomains\": [\"x.example\"]}", "requested host"),
        ("{\"type\": \"block\"}", "{\"regexFilter\": \"(?=ad)\"}", "regular expression")
    ])
    func unsupportedIsNamed(action: String, condition: String, expected: String) throws {
        let text = "{\"id\": 42, \"action\": \(action), \"condition\": \(condition)}"
        let value = try JSONSerialization.jsonObject(with: Data(text.utf8))
        let rule = try #require(DNRRule.parse(value).value)
        let compiled = DeclarativeNetRequestCompiler.compile([rule])
        #expect(compiled.translated == 0)
        let reason = try #require(compiled.unsupported.first)
        #expect(reason.id == 42)
        #expect(reason.reason.lowercased().contains(expected.lowercased()), "got: \(reason.reason)")
    }

    @Test("A rule count past the limit is cut, and every dropped rule is named")
    func cap() {
        let rules = (0..<(DeclarativeNetRequestCompiler.maximumRules + 5)).map { index in
            DNRRule.parse(["id": index + 1, "action": ["type": "block"],
                           "condition": ["urlFilter": "/ad\(index)"]]).value!
        }
        let compiled = DeclarativeNetRequestCompiler.compile(rules)
        #expect(compiled.translated == DeclarativeNetRequestCompiler.maximumRules)
        #expect(compiled.unsupported.count == 5)
    }

    @Test("Regular expressions WebKit's matcher cannot take are spotted before it sees them", arguments: [
        ("^https://ads\\.example/", true),
        ("(?=lookahead)", false),
        ("(?!negative)", false),
        ("a*?", false),
        ("([unclosed", false)
    ])
    func regexSupport(pattern: String, supported: Bool) {
        #expect(DeclarativeNetRequestCompiler.isSupportedRegex(pattern) == supported)
    }

    // MARK: - The manifest

    @Test("Static rulesets are read, paths normalised, and defaults respected")
    func definition() {
        let definition = DeclarativeNetRequestDefinition.read(from: [
            "declarative_net_request": [
                "rule_resources": [
                    ["id": "ads", "enabled": true, "path": "/rules/ads.json"],
                    ["id": "extra", "enabled": false, "path": "./rules/extra.json"],
                    ["id": "broken"]
                ]
            ]
        ])
        #expect(definition.rulesets.map(\.id) == ["ads", "extra"])
        #expect(definition.rulesets[0].path == "rules/ads.json")
        #expect(definition.rulesets[1].path == "rules/extra.json")
        #expect(definition.rulesets[0].isEnabledByDefault)
        #expect(!definition.rulesets[1].isEnabledByDefault)
    }

    @Test("An extension asking only for the permission still wants the API")
    func wantsAPI() {
        #expect(DeclarativeNetRequestDefinition.wantsAPI(["permissions": ["declarativeNetRequest"]]))
        #expect(DeclarativeNetRequestDefinition.wantsAPI(["permissions": ["declarativeNetRequestWithHostAccess"]]))
        #expect(DeclarativeNetRequestDefinition.wantsAPI(["declarative_net_request": ["rule_resources": []]]))
        #expect(!DeclarativeNetRequestDefinition.wantsAPI(["permissions": ["tabs"]]))
    }

    @Test("A ruleset path is not allowed to point out of the extension's folder")
    func pathEscape() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "dnr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let read = DeclarativeNetRequestDefinition.rules(
            for: .init(id: "x", isEnabledByDefault: true, path: "../../../etc/passwd"), in: folder
        )
        #expect(read.rules.isEmpty)
        #expect(read.rejected.first?.reason.contains("outside") == true)
    }

    // MARK: - The service, against the real rule store

    /// A real extension folder on disk: a manifest and a rules file, exactly
    /// as an MV3 blocker ships them.
    private func makeExtension(rules: String, enabled: Bool = true) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "dnr-ext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "manifest_version": 3,
            "name": "Blocker",
            "version": "1.0",
            "permissions": ["declarativeNetRequest"],
            "declarative_net_request": [
                "rule_resources": [["id": "ads", "enabled": enabled, "path": "rules.json"]]
            ]
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appending(path: "manifest.json"))
        try Data(rules.utf8).write(to: folder.appending(path: "rules.json"))
        return folder
    }

    private func makeService() -> (DeclarativeNetRequestService, UserDefaults, String) {
        let name = "kylmora-dnr-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (DeclarativeNetRequestService(defaults: defaults), defaults, name)
    }

    @Test("An extension's static ruleset is read, translated and compiled by WebKit")
    func serviceLoadsStaticRules() async throws {
        let folder = try makeExtension(rules: """
        [{"id": 1, "priority": 1, "action": {"type": "block"},
          "condition": {"urlFilter": "||ads.example^", "resourceTypes": ["script"]}}]
        """)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (service, _, suite) = makeService()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let id = UUID()
        await service.load(recordID: id, folder: folder)
        #expect(service.entries[id]?.translated == 1)
        #expect(service.entries[id]?.compiled != nil, "WebKit holds a compiled list for it")
        #expect(service.ruleLists(for: .standard).count == 1)
        service.forget(recordID: id)
        #expect(service.ruleLists(for: .standard).isEmpty)
    }

    @Test("A ruleset the manifest ships switched off is not applied until it is turned on")
    func disabledRulesetStaysOff() async throws {
        let folder = try makeExtension(rules: """
        [{"id": 1, "action": {"type": "block"}, "condition": {"urlFilter": "||ads.example^"}}]
        """, enabled: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (service, _, suite) = makeService()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let id = UUID()
        await service.load(recordID: id, folder: folder)
        #expect(service.entries[id]?.translated == 0)
        #expect(service.enabledRulesets(for: id).isEmpty)

        await service.setRulesets(enabled: ["ads"], disabled: [], for: id)
        #expect(service.enabledRulesets(for: id) == ["ads"])
        #expect(service.entries[id]?.translated == 1)
    }

    @Test("Rules added at runtime are kept, and survive the extension being loaded again")
    func dynamicRulesPersist() async throws {
        let folder = try makeExtension(rules: "[]")
        defer { try? FileManager.default.removeItem(at: folder) }
        let name = "kylmora-dnr-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        let id = UUID()
        let service = DeclarativeNetRequestService(defaults: defaults)
        await service.load(recordID: id, folder: folder)
        let reply = await service.perform("updateDynamicRules", arguments: [
            "addRules": [["id": 5, "action": ["type": "block"], "condition": ["urlFilter": "||tracker.example^"]]]
        ], for: id)
        if case .failure(let reason) = reply { Issue.record("refused: \(reason)") }
        #expect(service.rules(session: false, for: id).map(\.id) == [5])

        // A second service over the same storage is what the next launch sees.
        let reopened = DeclarativeNetRequestService(defaults: defaults)
        await reopened.load(recordID: id, folder: folder)
        #expect(reopened.rules(session: false, for: id).map(\.id) == [5])
        #expect(reopened.entries[id]?.translated == 1)
    }

    @Test("Session rules do not outlive the launch that made them")
    func sessionRulesDoNotPersist() async throws {
        let folder = try makeExtension(rules: "[]")
        defer { try? FileManager.default.removeItem(at: folder) }
        let name = "kylmora-dnr-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        let id = UUID()
        let service = DeclarativeNetRequestService(defaults: defaults)
        await service.load(recordID: id, folder: folder)
        _ = await service.perform("updateSessionRules", arguments: [
            "addRules": [["id": 9, "action": ["type": "block"], "condition": ["urlFilter": "||x.example^"]]]
        ], for: id)
        #expect(service.rules(session: true, for: id).map(\.id) == [9])

        let reopened = DeclarativeNetRequestService(defaults: defaults)
        await reopened.load(recordID: id, folder: folder)
        #expect(reopened.rules(session: true, for: id).isEmpty)
    }

    @Test("Adding a rule that reuses an identifier replaces it rather than doubling it")
    func addingReplacesByIdentifier() async throws {
        let folder = try makeExtension(rules: "[]")
        defer { try? FileManager.default.removeItem(at: folder) }
        let (service, _, suite) = makeService()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let id = UUID()
        await service.load(recordID: id, folder: folder)
        for filter in ["||one.example^", "||two.example^"] {
            _ = await service.perform("updateDynamicRules", arguments: [
                "addRules": [["id": 1, "action": ["type": "block"], "condition": ["urlFilter": filter]]]
            ], for: id)
        }
        let rules = service.rules(session: false, for: id)
        #expect(rules.count == 1)
        #expect(rules.first?.condition.urlFilter == "||two.example^")
    }

    @Test("A removal is honoured before the additions in the same call")
    func removalsComeFirst() async throws {
        let folder = try makeExtension(rules: "[]")
        defer { try? FileManager.default.removeItem(at: folder) }
        let (service, _, suite) = makeService()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let id = UUID()
        await service.load(recordID: id, folder: folder)
        _ = await service.perform("updateDynamicRules", arguments: [
            "addRules": [
                ["id": 1, "action": ["type": "block"], "condition": ["urlFilter": "||a.example^"]],
                ["id": 2, "action": ["type": "block"], "condition": ["urlFilter": "||b.example^"]]
            ]
        ], for: id)
        _ = await service.perform("updateDynamicRules", arguments: ["removeRuleIds": [1]], for: id)
        #expect(service.rules(session: false, for: id).map(\.id) == [2])
    }

    @Test("An extension's rules only reach the Spaces it is enabled in")
    func perSpace() async throws {
        let folder = try makeExtension(rules: """
        [{"id": 1, "action": {"type": "block"}, "condition": {"urlFilter": "||ads.example^"}}]
        """)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (service, _, suite) = makeService()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let allowed = Space.Identity.isolated(UUID())
        service.isEnabledInSpace = { _, identity in identity == allowed }
        let id = UUID()
        await service.load(recordID: id, folder: folder)
        #expect(service.ruleLists(for: allowed).count == 1)
        #expect(service.ruleLists(for: .standard).isEmpty, "a Space it is switched off in gets nothing")
    }

    @Test("The API answers the calls an extension actually makes")
    func brokerMethods() async throws {
        let folder = try makeExtension(rules: """
        [{"id": 1, "action": {"type": "block"}, "condition": {"urlFilter": "||ads.example^"}}]
        """)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (service, _, suite) = makeService()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let id = UUID()
        await service.load(recordID: id, folder: folder)

        guard case .value(let rulesets) = await service.perform("getEnabledRulesets", arguments: [:], for: id) else {
            Issue.record("getEnabledRulesets refused"); return
        }
        #expect(rulesets as? [String] == ["ads"])

        guard case .value(let regex) = await service.perform("isRegexSupported", arguments: ["regex": "(?=x)"], for: id) else {
            Issue.record("isRegexSupported refused"); return
        }
        #expect((regex as? [String: Any])?["isSupported"] as? Bool == false)

        guard case .value(let remaining) = await service.perform("getAvailableStaticRuleCount", arguments: [:], for: id) else {
            Issue.record("getAvailableStaticRuleCount refused"); return
        }
        #expect((remaining as? Int) == DeclarativeNetRequestCompiler.maximumRules - 1)

        if case .value = await service.perform("nonsense", arguments: [:], for: id) {
            Issue.record("an unknown method should be refused, not answered")
        }
    }

    @Test("An extension that never asked for the API gets nothing from it")
    func unknownExtension() async {
        let (service, _, suite) = makeService()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        if case .value = await service.perform("getEnabledRulesets", arguments: [:], for: UUID()) {
            Issue.record("an extension with no rules should be refused")
        }
    }

    // MARK: - The rules WebKit's matcher cannot hold

    @Test("A redirect is kept out of the content list and reported as page-and-frame only")
    func redirectIsNavigationOnly() throws {
        let text = "{QidQ: 1, QactionQ: {QtypeQ: QredirectQ, QredirectQ: {QurlQ: Qhttps://example.org/Q}}, QconditionQ: {QurlFilterQ: Q/adQ}}".replacingOccurrences(of: "Q", with: "\"")
        let rule = try #require(DNRRule.parse(try JSONSerialization.jsonObject(with: Data(text.utf8))).value)
        let compiled = DeclarativeNetRequestCompiler.compile([rule])
        #expect(compiled.translated == 0)
        #expect(compiled.unsupported.isEmpty, "it is not unsupported, it is handled elsewhere")
        #expect(compiled.navigationOnly.first?.id == 1)
        #expect(compiled.navigationOnly.first?.reason.contains("subresource") == true)
    }

    @Test("A rule that only rewrites response headers is refused, because nothing can")
    func responseHeadersRefused() {
        let text = "{QidQ: 1, QactionQ: {QtypeQ: QmodifyHeadersQ, QresponseHeadersQ: [{QheaderQ: QxQ, QoperationQ: QremoveQ}]}}".replacingOccurrences(of: "Q", with: "\"")
        let value = try! JSONSerialization.jsonObject(with: Data(text.utf8))
        #expect(DNRRule.parse(value).failureReason?.contains("response headers") == true)
    }

    private func navigationRule(_ json: String) throws -> DNRRule {
        let text = json.replacingOccurrences(of: "Q", with: "\"")
        return try #require(DNRRule.parse(try JSONSerialization.jsonObject(with: Data(text.utf8))).value)
    }

    private func decide(_ rules: [DNRRule], url: String, isMainFrame: Bool = true,
                        page: String? = nil, method: String = "GET",
                        base: URL? = nil) -> DeclarativeNetRequestNavigation.Outcome {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        return DeclarativeNetRequestNavigation.decide(
            request: request, isMainFrame: isMainFrame,
            pageURL: page.flatMap { URL(string: $0) },
            rules: rules, extensionBaseURL: base
        ).outcome
    }

    @Test("A redirect to a plain URL sends the navigation there")
    func redirectToURL() throws {
        let rule = try navigationRule("""
        {QidQ: 1, QactionQ: {QtypeQ: QredirectQ, QredirectQ: {QurlQ: Qhttps://good.example/Q}},
         QconditionQ: {QurlFilterQ: Q||bad.example^Q, QresourceTypesQ: [Qmain_frameQ]}}
        """)
        guard case .replace(let request) = decide([rule], url: "https://bad.example/page") else {
            Issue.record("expected a redirect"); return
        }
        #expect(request.url?.absoluteString == "https://good.example/")
    }

    @Test("A redirect into the extension's own files resolves against its root")
    func redirectToExtensionPath() throws {
        let rule = try navigationRule("""
        {QidQ: 1, QactionQ: {QtypeQ: QredirectQ, QredirectQ: {QextensionPathQ: Q/blocked.htmlQ}},
         QconditionQ: {QurlFilterQ: Q||bad.example^Q, QresourceTypesQ: [Qmain_frameQ]}}
        """)
        let base = URL(string: "chrome-extension://abcdef/")!
        guard case .replace(let request) = decide([rule], url: "https://bad.example/x", base: base) else {
            Issue.record("expected a redirect"); return
        }
        #expect(request.url?.absoluteString == "chrome-extension://abcdef/blocked.html")
    }

    @Test("A transform rewrites only the parts it names, and can drop query parameters")
    func redirectByTransform() throws {
        let rule = try navigationRule("""
        {QidQ: 1, QactionQ: {QtypeQ: QredirectQ, QredirectQ: {QtransformQ: {QhostQ: Qproxy.exampleQ,
          QqueryTransformQ: {QremoveParamsQ: [Qutm_sourceQ]}}}},
         QconditionQ: {QurlFilterQ: Q||news.example^Q, QresourceTypesQ: [Qmain_frameQ]}}
        """)
        guard case .replace(let request) = decide([rule], url: "https://news.example/a?utm_source=x&id=7") else {
            Issue.record("expected a redirect"); return
        }
        let result = try #require(request.url?.absoluteString)
        #expect(result.contains("proxy.example"))
        #expect(result.contains("id=7"))
        #expect(!result.contains("utm_source"))
    }

    @Test("A regex substitution puts the captured part into the replacement")
    func redirectByRegexSubstitution() throws {
        let rule = try navigationRule("""
        {QidQ: 1, QactionQ: {QtypeQ: QredirectQ, QredirectQ: {QregexSubstitutionQ: Qhttps://reader.example/?u=\\\\1Q}},
         QconditionQ: {QregexFilterQ: Q^https://news\\\\.example/(.*)$Q, QresourceTypesQ: [Qmain_frameQ]}}
        """)
        guard case .replace(let request) = decide([rule], url: "https://news.example/story/7") else {
            Issue.record("expected a redirect"); return
        }
        #expect(request.url?.absoluteString == "https://reader.example/?u=story/7")
    }

    @Test("A redirect onto the very same address is not followed")
    func redirectLoopRefused() throws {
        let rule = try navigationRule("""
        {QidQ: 1, QactionQ: {QtypeQ: QredirectQ, QredirectQ: {QurlQ: Qhttps://x.example/aQ}},
         QconditionQ: {QurlFilterQ: Q||x.example^Q, QresourceTypesQ: [Qmain_frameQ]}}
        """)
        #expect(decide([rule], url: "https://x.example/a") == .proceed)
    }

    @Test("Request headers are set, appended and removed on a GET")
    func headerChanges() throws {
        let rule = try navigationRule("""
        {QidQ: 1, QactionQ: {QtypeQ: QmodifyHeadersQ, QrequestHeadersQ: [
            {QheaderQ: QRefererQ, QoperationQ: QremoveQ},
            {QheaderQ: QX-TestQ, QoperationQ: QsetQ, QvalueQ: QyesQ}]},
         QconditionQ: {QurlFilterQ: Q||example.org^Q, QresourceTypesQ: [Qmain_frameQ]}}
        """)
        var request = URLRequest(url: URL(string: "https://example.org/a")!)
        request.setValue("https://elsewhere.example/", forHTTPHeaderField: "Referer")
        let decision = DeclarativeNetRequestNavigation.decide(
            request: request, isMainFrame: true, pageURL: nil, rules: [rule], extensionBaseURL: nil
        )
        guard case .replace(let changed) = decision.outcome else {
            Issue.record("expected the request to be re-issued"); return
        }
        #expect(changed.value(forHTTPHeaderField: "Referer") == nil)
        #expect(changed.value(forHTTPHeaderField: "X-Test") == "yes")
    }

    @Test("A request with a body is left alone, because re-issuing it would lose the body")
    func headersLeavePostsAlone() throws {
        let rule = try navigationRule("""
        {QidQ: 1, QactionQ: {QtypeQ: QmodifyHeadersQ, QrequestHeadersQ: [
            {QheaderQ: QX-TestQ, QoperationQ: QsetQ, QvalueQ: QyesQ}]},
         QconditionQ: {QurlFilterQ: Q||example.org^Q, QresourceTypesQ: [Qmain_frameQ]}}
        """)
        var request = URLRequest(url: URL(string: "https://example.org/a")!)
        request.httpMethod = "POST"
        request.httpBody = Data("a=1".utf8)
        let decision = DeclarativeNetRequestNavigation.decide(
            request: request, isMainFrame: true, pageURL: nil, rules: [rule], extensionBaseURL: nil
        )
        #expect(decision.outcome == .proceed)
    }

    @Test("A rule naming no resource types never touches the top-level page")
    func navigationSparesTheMainFrameByDefault() throws {
        let rule = try navigationRule("""
        {QidQ: 1, QactionQ: {QtypeQ: QredirectQ, QredirectQ: {QurlQ: Qhttps://good.example/Q}},
         QconditionQ: {QurlFilterQ: Q||bad.example^Q}}
        """)
        #expect(decide([rule], url: "https://bad.example/x", isMainFrame: true) == .proceed)
        guard case .replace = decide([rule], url: "https://bad.example/x", isMainFrame: false) else {
            Issue.record("a sub-frame should still be redirected"); return
        }
    }

    @Test("An allow of higher priority stops a redirect")
    func allowBeatsRedirect() throws {
        let redirect = try navigationRule("""
        {QidQ: 1, QpriorityQ: 1, QactionQ: {QtypeQ: QredirectQ, QredirectQ: {QurlQ: Qhttps://good.example/Q}},
         QconditionQ: {QurlFilterQ: Q||bad.example^Q, QresourceTypesQ: [Qmain_frameQ]}}
        """)
        let allow = try navigationRule("""
        {QidQ: 2, QpriorityQ: 5, QactionQ: {QtypeQ: QallowQ},
         QconditionQ: {QurlFilterQ: Q||bad.example/keepQ, QresourceTypesQ: [Qmain_frameQ]}}
        """)
        #expect(decide([redirect, allow], url: "https://bad.example/keep") == .proceed)
        guard case .replace = decide([redirect, allow], url: "https://bad.example/other") else {
            Issue.record("an unmatched allow should not stop the redirect"); return
        }
    }

    @Test("Third party means a different site from the page doing the asking")
    func partyMatching() throws {
        let rule = try navigationRule("""
        {QidQ: 1, QactionQ: {QtypeQ: QredirectQ, QredirectQ: {QurlQ: Qhttps://good.example/Q}},
         QconditionQ: {QurlFilterQ: Q||tracker.example^Q, QresourceTypesQ: [Qsub_frameQ], QdomainTypeQ: QthirdPartyQ}}
        """)
        guard case .replace = decide([rule], url: "https://tracker.example/x",
                                     isMainFrame: false, page: "https://news.example/") else {
            Issue.record("a different site is third party"); return
        }
        #expect(decide([rule], url: "https://a.tracker.example/x", isMainFrame: false,
                       page: "https://b.tracker.example/") == .proceed,
                "the same site is not third party")
    }

    @Test("The pane is told how many rules are live and how many were refused")
    func paneSummary() async throws {
        let folder = try makeExtension(rules: """
        [{"id": 1, "action": {"type": "block"}, "condition": {"urlFilter": "||ads.example^"}},
         {"id": 2, "action": {"type": "block"}, "condition": {"urlFilter": "/a", "tabIds": [3]}},
         {"id": 3, "action": {"type": "redirect", "redirect": {"url": "https://ok.example/"}},
          "condition": {"urlFilter": "/b"}}]
        """)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (service, _, suite) = makeService()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let id = UUID()
        await service.load(recordID: id, folder: folder)
        let summary = try #require(service.summary(for: id))
        #expect(summary.contains("1 blocking rule active"))
        #expect(summary.contains("1 applying to pages and frames only"))
        #expect(summary.contains("1 this browser could not take"))
    }

    @Test("An extension with no blocking rules at all says nothing about them")
    func noSummaryWithoutRules() {
        let (service, _, suite) = makeService()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        #expect(service.summary(for: UUID()) == nil)
    }
}
