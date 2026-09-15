import Foundation

/// Reads and writes the routing rules as one JSON file.
///
/// Its own file rather than a section of the session, because rules are
/// configuration and the session is state: a user who turns session restore
/// off still expects their rules to be there, and a corrupt session must not
/// take the rules with it.
struct SpaceRoutingStore {
    private let file: JSONFile<SpaceRoutingRules>
    var fileURL: URL { file.url }

    init(fileURL: URL = AppPaths.supportDirectory.appending(path: "space-routing.json")) {
        file = JSONFile(fileURL)
    }

    /// A missing or unreadable file is an empty rule set, not an error. With no
    /// rules the feature is simply inert, which is the correct behaviour for a
    /// browser that has never had any.
    func load() -> SpaceRoutingRules {
        (file.load() ?? .empty).discardingEmptyRoutes()
    }

    /// Atomic, so a crash mid-write cannot leave half a rule set behind.
    func save(_ rules: SpaceRoutingRules) throws {
        try file.save(rules.discardingEmptyRoutes())
    }
}
