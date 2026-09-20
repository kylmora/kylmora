import Foundation

/// What an extension's manifest says about `declarativeNetRequest`.
///
/// The static rulesets are the part that matters most: an MV3 content blocker
/// ships its whole filter list this way, declares it once in the manifest, and
/// never touches the API again at runtime.
struct DeclarativeNetRequestDefinition: Equatable, Sendable {
    /// One `rule_resources` entry.
    struct Ruleset: Equatable, Sendable {
        let id: String
        /// Whether it starts switched on. An extension ships most of its
        /// optional lists off.
        let isEnabledByDefault: Bool
        /// The rule file, relative to the extension's folder.
        let path: String
    }

    var rulesets: [Ruleset] = []

    var isEmpty: Bool { rulesets.isEmpty }

    /// Whether the manifest asks for the API at all, by declaring rulesets or
    /// by requesting one of its permissions. An extension that only adds rules
    /// at runtime has no `rule_resources` but does ask for the permission.
    static func wantsAPI(_ manifest: [String: Any]) -> Bool {
        if manifest["declarative_net_request"] is [String: Any] { return true }
        let permissions = (manifest["permissions"] as? [Any])?.compactMap { $0 as? String } ?? []
        return permissions.contains { $0.hasPrefix("declarativeNetRequest") }
    }

    static func read(from manifest: [String: Any]) -> DeclarativeNetRequestDefinition {
        var definition = DeclarativeNetRequestDefinition()
        guard let section = manifest["declarative_net_request"] as? [String: Any],
              let resources = section["rule_resources"] as? [Any] else { return definition }
        for entry in resources {
            guard let object = entry as? [String: Any],
                  let id = object["id"] as? String,
                  let path = object["path"] as? String,
                  !id.isEmpty, !path.isEmpty else { continue }
            definition.rulesets.append(Ruleset(
                id: id,
                isEnabledByDefault: (object["enabled"] as? Bool) ?? false,
                path: normalise(path)
            ))
        }
        return definition
    }

    /// A manifest path may be written with a leading slash or a `./`; the
    /// folder does not have either.
    private static func normalise(_ path: String) -> String {
        var trimmed = path
        while trimmed.hasPrefix("/") { trimmed.removeFirst() }
        while trimmed.hasPrefix("./") { trimmed.removeFirst(2) }
        return trimmed
    }

    /// Reads a ruleset's rules off disk, refusing to walk out of the
    /// extension's own folder on the way.
    static func rules(for ruleset: Ruleset, in folder: URL) -> (rules: [DNRRule], rejected: [DNRRule.Rejection]) {
        let file = folder.appending(path: ruleset.path)
        let root = folder.standardizedFileURL.path
        guard file.standardizedFileURL.path.hasPrefix(root) else {
            return ([], [DNRRule.Rejection(id: nil, reason: "\"\(ruleset.path)\" points outside the extension.")])
        }
        guard let data = try? Data(contentsOf: file) else {
            return ([], [DNRRule.Rejection(id: nil, reason: "\"\(ruleset.path)\" could not be read.")])
        }
        guard let value = try? JSONSerialization.jsonObject(with: data) else {
            return ([], [DNRRule.Rejection(id: nil, reason: "\"\(ruleset.path)\" is not valid JSON.")])
        }
        return DNRRule.parseAll(value)
    }
}
