import Foundation

/// Reads and writes the routing rules as one JSON file.
///
/// Its own file rather than a section of the session, because rules are
/// configuration and the session is state: a user who turns session restore
/// off still expects their rules to be there, and a corrupt session must not
/// take the rules with it.
struct SpaceRoutingStore {
    let fileURL: URL

    init(fileURL: URL = AppPaths.supportDirectory.appending(path: "space-routing.json")) {
        self.fileURL = fileURL
    }

    /// A missing or unreadable file is an empty rule set, not an error. With no
    /// rules the feature is simply inert, which is the correct behaviour for a
    /// browser that has never had any.
    func load() -> SpaceRoutingRules {
        guard let data = try? Data(contentsOf: fileURL),
              let rules = try? JSONDecoder().decode(SpaceRoutingRules.self, from: data) else {
            return .empty
        }
        return rules.discardingEmptyRoutes()
    }

    /// Atomic, so a crash mid-write cannot leave half a rule set behind.
    func save(_ rules: SpaceRoutingRules) throws {
        AppPaths.ensureSupportDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(rules.discardingEmptyRoutes())
        try data.write(to: fileURL, options: [.atomic])
    }
}
