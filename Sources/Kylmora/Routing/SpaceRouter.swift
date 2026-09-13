import Foundation

/// Decides which space a URL belongs to.
///
/// Pure, like `URLResolver`: given a URL, a rule set and where the user is
/// now, it answers with a destination and nothing else. Moving the tab,
/// switching space and raising a toast are the caller's business, which is what
/// lets every rule below -- first match wins, the normalisation `equalTo` does,
/// and the guard against routing into the space you are already in -- be a
/// test rather than a click.
enum SpaceRouter {
    enum Decision: Equatable {
        /// Open where the user already is.
        case stay
        /// Open in this space, which is never the current one.
        case route(to: UUID)
    }

    /// Where a navigation came from. External links get their own default
    /// because they arrive with no context to respect.
    enum Origin: Equatable {
        case inBrowser
        case external
    }

    /// The single entry point.
    ///
    /// `knownSpaceIDs` is required rather than looked up later because a rule
    /// pointing at a deleted space must behave as a miss, not as a route to
    /// nowhere. Deleting a space does not go back and rewrite the rules file,
    /// so this is the normal case after a space is removed, not a corruption.
    static func decision(
        for url: URL,
        rules: SpaceRoutingRules,
        origin: Origin = .inBrowser,
        currentSpaceID: UUID,
        knownSpaceIDs: Set<UUID>
    ) -> Decision {
        let matched = rules.routes.first { matches($0, url: url) }?.destination
        let destination = matched ?? (origin == .external ? rules.externalDefault : .mostRecentSpace)

        guard case .space(let id) = destination else { return .stay }
        // Routing a tab into the space it would have opened in anyway is a
        // move with no effect and a space switch to where you already are.
        // The same guard matters even more on an in-place navigation path,
        // where skipping it would be an infinite redirect.
        guard id != currentSpaceID, knownSpaceIDs.contains(id) else { return .stay }
        return .route(to: id)
    }

    /// Whether one rule matches one URL.
    static func matches(_ route: SpaceRoute, url: URL) -> Bool {
        let reference = route.reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty else { return false }
        let address = url.absoluteString

        switch route.match {
        case .contains:
            return address.range(of: reference, options: [.caseInsensitive]) != nil
        case .equalTo:
            return normalizedForEquality(address) == normalizedForEquality(reference)
        case .regex:
            // Case-sensitive and against the raw URL: a regex is the escape
            // hatch, and silently changing what the user wrote would make it
            // the one match type whose behaviour cannot be reasoned about.
            guard let expression = try? NSRegularExpression(pattern: reference) else { return false }
            let range = NSRange(address.startIndex..<address.endIndex, in: address)
            return expression.firstMatch(in: address, range: range) != nil
        }
    }

    /// Strips the parts of an address a person does not think of as part of it:
    /// the scheme, a leading `www.`, and a trailing slash. Without this,
    /// `equalTo` would only ever match a URL pasted from the address bar, which
    /// is not what anybody types into a rule.
    static func normalizedForEquality(_ address: String) -> String {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) {
            text.removeFirst(scheme.count)
        }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }
}
