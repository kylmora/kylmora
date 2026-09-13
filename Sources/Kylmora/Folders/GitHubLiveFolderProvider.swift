import Foundation

/// A live folder of GitHub pull requests or issues for one account.
///
/// **This provider is anonymous, by design.** Issuing the GitHub request under
/// the workspace's container would let the user's browser session come along
/// with it, which is how private work could be listed with no OAuth flow at
/// all. Kylmora does not do that: it would mean copying cookies across the
/// profile boundary that exists to enforce isolation (see
/// `LiveFolderFetcher`), so it asks GitHub's public search API about a named
/// account instead. The consequence is honest and stated in the folder's
/// empty state: public repositories only.
struct GitHubLiveFolderProvider: LiveFolderProvider {
    static let kind: LiveFolderKind = .github

    enum Scope: String, Codable, Sendable {
        case pullRequests
        case issues
    }

    struct Configuration: Codable, Sendable, Equatable {
        /// The account the folder is about. Empty means the folder was never
        /// finished being set up.
        var login: String
        var scope: Scope = .pullRequests
        /// The three filters, each of which becomes its own search query.
        var authorMe: Bool = false
        var assignedMe: Bool = true
        /// Meaningless for issues, and hidden from the menu there.
        var reviewRequested: Bool = false
        /// Pull requests only.
        var includeDrafts: Bool = true
        /// Repositories the user has switched off, in `owner/name` form. Filled
        /// from what actually turns up, so the menu only ever offers repos the
        /// folder has really seen.
        var excludedRepositories: Set<String> = []
        /// Every repository seen in a result so far, so the exclude submenu has
        /// something to list before the next fetch.
        var knownRepositories: Set<String> = []
    }

    var configuration: Configuration

    var source: LiveFolderSource { .github(configuration) }

    var metadata: LiveFolderMetadata {
        let noun = configuration.scope == .pullRequests ? "Pull Requests" : "Issues"
        return LiveFolderMetadata(
            name: configuration.login.isEmpty ? noun : "\(configuration.login) · \(noun)",
            symbolName: configuration.scope == .pullRequests
                ? "arrow.trianglehead.branch"
                : "smallcircle.filled.circle"
        )
    }

    var options: [LiveFolderOption] {
        var items: [LiveFolderOption] = [
            .toggle(key: "authorMe", title: "Created by \(displayLogin)", isOn: configuration.authorMe),
            .toggle(key: "assignedMe", title: "Assigned to \(displayLogin)", isOn: configuration.assignedMe)
        ]
        if configuration.scope == .pullRequests {
            items.append(
                .toggle(
                    key: "reviewRequested",
                    title: "Review requested from \(displayLogin)",
                    isOn: configuration.reviewRequested
                )
            )
            items.append(.separator)
            items.append(.toggle(key: "includeDrafts", title: "Include drafts", isOn: configuration.includeDrafts))
        }
        if !configuration.knownRepositories.isEmpty {
            items.append(.separator)
            items.append(
                .submenu(
                    title: "Repositories",
                    items: configuration.knownRepositories.sorted().map { repo in
                        .toggle(
                            key: "repo:\(repo)",
                            title: repo,
                            isOn: !configuration.excludedRepositories.contains(repo)
                        )
                    }
                )
            )
        }
        return items
    }

    private var displayLogin: String {
        configuration.login.isEmpty ? "me" : configuration.login
    }

    func applying(_ change: LiveFolderOptionChange) -> any LiveFolderProvider {
        var updated = configuration
        switch (change.key, change.value) {
        case ("authorMe", .bool(let on)): updated.authorMe = on
        case ("assignedMe", .bool(let on)): updated.assignedMe = on
        case ("reviewRequested", .bool(let on)): updated.reviewRequested = on
        case ("includeDrafts", .bool(let on)): updated.includeDrafts = on
        case (let key, .bool(let on)) where key.hasPrefix("repo:"):
            let repo = String(key.dropFirst("repo:".count))
            if on { updated.excludedRepositories.remove(repo) } else { updated.excludedRepositories.insert(repo) }
        default:
            break
        }
        return GitHubLiveFolderProvider(configuration: updated)
    }

    // MARK: - Fetching

    func fetchItems(using fetcher: LiveFolderFetcher) async -> LiveFolderFetch {
        let login = configuration.login.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !login.isEmpty else { return .blocked(.notConfigured) }

        let qualifiers = enabledQualifiers(login: login)
        // No filter means no question. Short-circuited before any request, both
        // because a request with nothing to ask is waste and because GitHub's
        // unauthenticated search budget is ten calls a minute.
        guard !qualifiers.isEmpty else { return .blocked(.noFilterSelected) }

        var merged: [String: LiveFolderItem] = [:]
        var repositories: Set<String> = []

        // Sequential, not parallel: fanning these out would be the fastest
        // way to spend the whole per-minute budget against an unauthenticated
        // endpoint in one poll and get everything rate limited.
        for qualifier in qualifiers {
            guard let url = searchURL(qualifier: qualifier, login: login) else {
                return .blocked(.notConfigured)
            }
            do {
                let response = try await fetcher.get(url, accept: "application/vnd.github+json")
                let decoded = try JSONDecoder().decode(SearchResponse.self, from: response.data)
                for entry in decoded.items {
                    guard let item = makeItem(entry) else { continue }
                    if let repo = entry.repositoryName { repositories.insert(repo) }
                    if let repo = entry.repositoryName, configuration.excludedRepositories.contains(repo) { continue }
                    merged[item.id] = item
                }
            } catch let failure as LiveFolderFetcher.Failure {
                if case .notFound = failure { return .blocked(.unknownAccount(login)) }
                // **One failed query fails the whole fetch.** Returning the
                // queries that did succeed would look like an authoritative
                // list, and the reconciler would close every tab the failed
                // query would have accounted for.
                return .blocked(.from(failure))
            } catch is DecodingError {
                return .blocked(.malformedResponse)
            } catch {
                return .blocked(.network((error as NSError).localizedDescription))
            }
        }

        let items = merged.values.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        return .items(Array(items))
    }

    /// The exclude submenu can only offer repositories the folder has really
    /// seen, so every fetch widens the list. Item ids are `owner/repo#number`,
    /// which is where the names come from.
    func learning(from items: [LiveFolderItem]) -> any LiveFolderProvider {
        let seen = Set(items.compactMap { item in item.id.split(separator: "#").first.map(String.init) })
        guard !seen.isSubset(of: configuration.knownRepositories) else { return self }
        var updated = configuration
        updated.knownRepositories.formUnion(seen)
        return GitHubLiveFolderProvider(configuration: updated)
    }

    private func enabledQualifiers(login: String) -> [String] {
        var result: [String] = []
        if configuration.authorMe { result.append("author:\(login)") }
        if configuration.assignedMe { result.append("assignee:\(login)") }
        if configuration.scope == .pullRequests && configuration.reviewRequested {
            result.append("review-requested:\(login)")
        }
        return result
    }

    private func searchURL(qualifier: String, login: String) -> URL? {
        let type = configuration.scope == .pullRequests ? "pr" : "issue"
        var query = "is:\(type) is:open \(qualifier)"
        if configuration.scope == .pullRequests && !configuration.includeDrafts {
            query += " draft:false"
        }
        var components = URLComponents(string: "https://api.github.com/search/issues")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "sort", value: "updated"),
            URLQueryItem(name: "order", value: "desc"),
            URLQueryItem(name: "per_page", value: "30")
        ]
        return components?.url
    }

    private func makeItem(_ entry: SearchResponse.Item) -> LiveFolderItem? {
        guard let url = URL(string: entry.htmlURL), FeedParser.isNavigable(url) else { return nil }
        // GitHub's search endpoint answers with `draft` absent on issues, so a
        // missing value has to mean "not a draft" rather than "unknown".
        if configuration.scope == .pullRequests, !configuration.includeDrafts, entry.draft == true {
            return nil
        }
        let repo = entry.repositoryName ?? url.host() ?? "github"
        return LiveFolderItem(
            id: "\(repo)#\(entry.number)",
            title: entry.title,
            url: url,
            subtitle: entry.user?.login,
            date: FeedDate.parse(entry.updatedAt ?? "")
        )
    }

    /// Only the fields a tab needs. Decoding GitHub's whole issue object would
    /// be a hundred keys that exist solely to break when one of them changes
    /// shape.
    private struct SearchResponse: Decodable {
        struct User: Decodable {
            let login: String
        }

        struct Item: Decodable {
            let number: Int
            let title: String
            let htmlURL: String
            let repositoryURL: String?
            let user: User?
            let draft: Bool?
            let updatedAt: String?

            enum CodingKeys: String, CodingKey {
                case number, title, user, draft
                case htmlURL = "html_url"
                case repositoryURL = "repository_url"
                case updatedAt = "updated_at"
            }

            /// `https://api.github.com/repos/owner/name` -> `owner/name`.
            var repositoryName: String? {
                guard let repositoryURL, let url = URL(string: repositoryURL) else { return nil }
                let parts = url.pathComponents.filter { $0 != "/" }
                guard parts.count >= 3, parts[parts.count - 3] == "repos" else { return nil }
                return "\(parts[parts.count - 2])/\(parts[parts.count - 1])"
            }
        }

        let items: [Item]
    }
}
