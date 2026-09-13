import Foundation

/// Where a matching URL should open.
///
/// `mostRecentSpace` is not "no destination": it is an explicit instruction to
/// leave the tab where the user is. Keeping it as a case rather than as a nil
/// space id means a rule can be written to *stop* a broader rule below it from
/// firing, which is the only way a first-match-wins list can express an
/// exception.
enum SpaceRouteDestination: Equatable, Hashable, Codable {
    case space(UUID)
    case mostRecentSpace

    private static let mostRecentToken = "most-recent-space"

    /// Encoded as one string rather than as a tagged object, so the rules file
    /// stays readable by a person editing it by hand.
    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw == Self.mostRecentToken {
            self = .mostRecentSpace
        } else if let id = UUID(uuidString: raw) {
            self = .space(id)
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Not a space id or \(Self.mostRecentToken)")
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .space(let id): try container.encode(id.uuidString)
        case .mostRecentSpace: try container.encode(Self.mostRecentToken)
        }
    }
}

/// How a rule's reference text is compared against a URL.
enum SpaceRouteMatch: String, Equatable, Codable, CaseIterable {
    /// Case-insensitive substring of the whole URL. The forgiving default, and
    /// what "add this site to a space" produces.
    case contains
    /// The whole address, compared after scheme, a leading `www.` and a
    /// trailing slash are stripped from both sides, so a rule written as
    /// `example.com` matches `https://www.example.com/`.
    case equalTo = "equal-to"
    /// A regular expression against the unmodified URL, case-sensitive. An
    /// invalid pattern never matches; it does not throw and does not fall
    /// through to the next rule as a match.
    case regex
}

/// One rule: a pattern, how to compare it, and where matches go.
struct SpaceRoute: Identifiable, Equatable, Codable {
    var id: UUID
    /// The pattern as the user typed it. Stored verbatim -- normalising it on
    /// save would mean the editor shows something different from what was
    /// entered, and for `regex` it would change the meaning.
    var reference: String
    var match: SpaceRouteMatch
    var destination: SpaceRouteDestination

    init(id: UUID = UUID(), reference: String, match: SpaceRouteMatch, destination: SpaceRouteDestination) {
        self.id = id
        self.reference = reference
        self.match = match
        self.destination = destination
    }

    var isEmpty: Bool {
        reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// The whole rule set, in the order it is evaluated.
struct SpaceRoutingRules: Equatable, Codable {
    var routes: [SpaceRoute]

    /// Where a link arriving from another application goes when no rule
    /// matches. Separate from the in-browser default because the two questions
    /// genuinely differ: a link from Mail has no "where you were" to respect.
    var externalDefault: SpaceRouteDestination

    static let empty = SpaceRoutingRules(routes: [], externalDefault: .mostRecentSpace)

    init(routes: [SpaceRoute] = [], externalDefault: SpaceRouteDestination = .mostRecentSpace) {
        self.routes = routes
        self.externalDefault = externalDefault
    }

    /// Drops rules with nothing in them. An editor row the user opened and
    /// never filled in would otherwise persist as a rule that matches every
    /// URL under `contains`, which is the worst possible failure for this
    /// feature: every tab silently moving to one space.
    func discardingEmptyRoutes() -> SpaceRoutingRules {
        SpaceRoutingRules(routes: routes.filter { !$0.isEmpty }, externalDefault: externalDefault)
    }

    /// The rule the "send this site to a space" command builds from one tab.
    static func rule(forHost host: String, destination: SpaceRouteDestination) -> SpaceRoute {
        SpaceRoute(reference: host, match: .contains, destination: destination)
    }

    /// The rule that command builds from several tabs at once.
    ///
    /// Every metacharacter in a host is escaped, so `a.com` cannot match
    /// `axcom`. Skipping this step would allow exactly that bug; an
    /// alternation of literal hosts is the whole intent here, and a host is
    /// never a pattern the user wrote.
    static func rule(forHosts hosts: [String], destination: SpaceRouteDestination) -> SpaceRoute? {
        let unique = Array(Set(hosts.filter { !$0.isEmpty })).sorted()
        guard let first = unique.first else { return nil }
        guard unique.count > 1 else { return rule(forHost: first, destination: destination) }
        let alternation = unique.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        return SpaceRoute(reference: "(\(alternation))", match: .regex, destination: destination)
    }
}
