import Foundation
import Testing
@testable import Kylmora

@Suite("Space routing")
@MainActor
struct RoutingTests {
    private func url(_ string: String) -> URL { URL(string: string)! }

    private let work = UUID()
    private let personal = UUID()

    private var knownSpaces: Set<UUID> { [work, personal] }

    private func rules(_ routes: [SpaceRoute], external: SpaceRouteDestination = .mostRecentSpace) -> SpaceRoutingRules {
        SpaceRoutingRules(routes: routes, externalDefault: external)
    }

    @Test("A matching rule sends the URL to its space")
    func matchRoutes() {
        let decision = SpaceRouter.decision(
            for: url("https://mail.work.example/inbox"),
            rules: rules([SpaceRoutingRules.rule(forHost: "work.example", destination: .space(work))]),
            currentSpaceID: personal,
            knownSpaceIDs: knownSpaces
        )
        #expect(decision == .route(to: work))
    }

    @Test("No rule matches, so the tab opens where the user is")
    func missStays() {
        let decision = SpaceRouter.decision(
            for: url("https://example.com"),
            rules: rules([SpaceRoutingRules.rule(forHost: "work.example", destination: .space(work))]),
            currentSpaceID: personal,
            knownSpaceIDs: knownSpaces
        )
        #expect(decision == .stay)
    }

    @Test("A rule naming the space you are already in does nothing")
    func matchingCurrentSpaceStays() {
        let decision = SpaceRouter.decision(
            for: url("https://work.example/doc"),
            rules: rules([SpaceRoutingRules.rule(forHost: "work.example", destination: .space(work))]),
            currentSpaceID: work,
            knownSpaceIDs: knownSpaces
        )
        #expect(decision == .stay)
    }

    @Test("The first matching rule wins, so an exception can be written above a broad rule")
    func firstMatchWins() {
        let ruleSet = rules([
            SpaceRoute(reference: "work.example/personal", match: .contains, destination: .mostRecentSpace),
            SpaceRoute(reference: "work.example", match: .contains, destination: .space(work))
        ])
        #expect(
            SpaceRouter.decision(
                for: url("https://work.example/personal/notes"),
                rules: ruleSet,
                currentSpaceID: personal,
                knownSpaceIDs: knownSpaces
            ) == .stay
        )
        #expect(
            SpaceRouter.decision(
                for: url("https://work.example/tickets"),
                rules: ruleSet,
                currentSpaceID: personal,
                knownSpaceIDs: knownSpaces
            ) == .route(to: work)
        )
    }

    @Test("A rule pointing at a deleted space behaves as a miss")
    func danglingRuleIsAMiss() {
        let decision = SpaceRouter.decision(
            for: url("https://work.example"),
            rules: rules([SpaceRoutingRules.rule(forHost: "work.example", destination: .space(UUID()))]),
            currentSpaceID: personal,
            knownSpaceIDs: knownSpaces
        )
        #expect(decision == .stay)
    }

    @Test("An external link with no match takes the external default")
    func externalDefaultApplies() {
        let ruleSet = rules([], external: .space(work))
        #expect(
            SpaceRouter.decision(
                for: url("https://example.com"),
                rules: ruleSet,
                origin: .external,
                currentSpaceID: personal,
                knownSpaceIDs: knownSpaces
            ) == .route(to: work)
        )
        // The same URL opened inside the browser is not external, so the
        // default does not apply to it.
        #expect(
            SpaceRouter.decision(
                for: url("https://example.com"),
                rules: ruleSet,
                origin: .inBrowser,
                currentSpaceID: personal,
                knownSpaceIDs: knownSpaces
            ) == .stay
        )
    }

    @Test("`contains` ignores case and looks at the whole address")
    func containsMatching() {
        let route = SpaceRoute(reference: "GitHub.com", match: .contains, destination: .space(work))
        #expect(SpaceRouter.matches(route, url: url("https://github.com/example")))
        #expect(SpaceRouter.matches(SpaceRoute(reference: "/pulls", match: .contains, destination: .space(work)),
                                    url: url("https://github.com/example/pulls")))
        #expect(!SpaceRouter.matches(route, url: url("https://example.com")))
    }

    @Test("`equalTo` ignores scheme, a leading www. and a trailing slash")
    func equalToNormalisation() {
        let route = SpaceRoute(reference: "example.com", match: .equalTo, destination: .space(work))
        #expect(SpaceRouter.matches(route, url: url("https://www.example.com/")))
        #expect(SpaceRouter.matches(route, url: url("http://example.com")))
        // A path is part of the address, so it is not equal to the bare host.
        #expect(!SpaceRouter.matches(route, url: url("https://example.com/inbox")))
    }

    @Test("`regex` is case-sensitive against the raw URL, and a bad pattern never matches")
    func regexMatching() {
        let route = SpaceRoute(reference: "^https://[a-z]+\\.work\\.example/", match: .regex, destination: .space(work))
        #expect(SpaceRouter.matches(route, url: url("https://mail.work.example/inbox")))
        #expect(!SpaceRouter.matches(route, url: url("https://MAIL.work.example/inbox")))

        let broken = SpaceRoute(reference: "([unclosed", match: .regex, destination: .space(work))
        #expect(!SpaceRouter.matches(broken, url: url("https://anything.example")))
    }

    @Test("A blank pattern matches nothing, so an unfinished rule cannot capture every tab")
    func blankReferenceMatchesNothing() {
        let route = SpaceRoute(reference: "   ", match: .contains, destination: .space(work))
        #expect(!SpaceRouter.matches(route, url: url("https://example.com")))
        #expect(rules([route]).discardingEmptyRoutes().routes.isEmpty)
    }

    @Test("A rule built from several hosts escapes them, so a.com does not match axcom")
    func multiHostRuleEscapesDots() {
        let route = SpaceRoutingRules.rule(forHosts: ["a.com", "b.com"], destination: .space(work))
        #expect(route?.match == .regex)
        #expect(SpaceRouter.matches(route!, url: url("https://a.com/x")))
        #expect(!SpaceRouter.matches(route!, url: url("https://axcom/x")))
    }

    @Test("A single host builds the forgiving rule, and no hosts build none")
    func singleHostRule() {
        #expect(SpaceRoutingRules.rule(forHosts: ["a.com"], destination: .space(work))?.match == .contains)
        #expect(SpaceRoutingRules.rule(forHosts: [], destination: .space(work)) == nil)
    }

    @Test("Rules survive a round trip through the file, empty ones dropped")
    func persistenceRoundTrip() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "kylmora-routing-\(UUID().uuidString).json")
        let store = SpaceRoutingStore(fileURL: file)
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(store.load() == .empty)

        let saved = rules(
            [
                SpaceRoutingRules.rule(forHost: "work.example", destination: .space(work)),
                SpaceRoute(reference: "", match: .contains, destination: .space(personal))
            ],
            external: .space(work)
        )
        try store.save(saved)

        let loaded = store.load()
        #expect(loaded.routes.count == 1)
        #expect(loaded.routes.first?.reference == "work.example")
        #expect(loaded.externalDefault == .space(work))
    }

    @Test("Routing is skipped for restored and pre-placed tabs")
    func contextsThatSkipRouting() {
        let file = FileManager.default.temporaryDirectory.appending(path: "kylmora-routing-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let service = SpaceRoutingService(store: SpaceRoutingStore(fileURL: file))
        service.add(SpaceRoutingRules.rule(forHost: "work.example", destination: .space(work)))

        let target = url("https://work.example/doc")
        #expect(service.decision(for: target, context: .restore, currentSpaceID: personal, knownSpaceIDs: knownSpaces) == .stay)
        #expect(service.decision(for: target, context: .placed, currentSpaceID: personal, knownSpaceIDs: knownSpaces) == .stay)
        #expect(
            service.decision(
                for: target,
                context: .newTab(.inBrowser),
                currentSpaceID: personal,
                knownSpaceIDs: knownSpaces
            ) == .route(to: work)
        )
    }

    @Test("Deleting a space prunes the rules that pointed at it")
    func pruningDanglingRules() {
        let file = FileManager.default.temporaryDirectory.appending(path: "kylmora-routing-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let service = SpaceRoutingService(store: SpaceRoutingStore(fileURL: file))
        service.replace(
            with: rules(
                [
                    SpaceRoutingRules.rule(forHost: "work.example", destination: .space(work)),
                    SpaceRoutingRules.rule(forHost: "example.com", destination: .space(personal))
                ],
                external: .space(work)
            )
        )

        service.removeRoutes(toSpacesNotIn: [personal])
        #expect(service.rules.routes.count == 1)
        #expect(service.rules.routes.first?.reference == "example.com")
        #expect(service.rules.externalDefault == .mostRecentSpace)
    }

    @Test("An empty rule set is inert, so nothing is matched at all")
    func inertWhenEmpty() {
        let file = FileManager.default.temporaryDirectory.appending(path: "kylmora-routing-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let service = SpaceRoutingService(store: SpaceRoutingStore(fileURL: file))
        #expect(!service.isActive)
        #expect(
            service.decision(
                for: url("https://work.example"),
                context: .newTab(.external),
                currentSpaceID: personal,
                knownSpaceIDs: knownSpaces
            ) == .stay
        )
    }
}
