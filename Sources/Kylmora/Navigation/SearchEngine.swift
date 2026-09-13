import Foundation

/// A search engine: a name, a query template, and a keyword for quick
/// searches from the command bar.
///
/// Three are built in and cannot be removed. Custom ones are the user's,
/// kept in preferences, and are how any site with a search box becomes a
/// search engine: paste the address of a search on it with the words
/// replaced by `%s`.
struct SearchEngine: Equatable, Sendable, Identifiable, Codable {
    /// Stable key used to remember the choice in preferences.
    let id: String
    var name: String
    /// Template containing a single `{query}` placeholder.
    var queryTemplate: String
    /// Opened when a new tab has nowhere else to go.
    var homeURL: URL
    /// Typed first in the command bar, then a space, to search this engine
    /// whatever the default is. Nil for engines without one.
    var keyword: String?

    init(id: String, name: String, queryTemplate: String, homeURL: URL, keyword: String? = nil) {
        self.id = id
        self.name = name
        self.queryTemplate = queryTemplate
        self.homeURL = homeURL
        self.keyword = keyword
    }

    static let duckDuckGo = SearchEngine(
        id: "duckduckgo",
        name: "DuckDuckGo",
        queryTemplate: "https://duckduckgo.com/?q={query}",
        homeURL: URL(string: "https://duckduckgo.com")!,
        keyword: "ddg"
    )

    static let google = SearchEngine(
        id: "google",
        name: "Google",
        queryTemplate: "https://www.google.com/search?q={query}",
        homeURL: URL(string: "https://www.google.com")!,
        keyword: "g"
    )

    static let bing = SearchEngine(
        id: "bing",
        name: "Bing",
        queryTemplate: "https://www.bing.com/search?q={query}",
        homeURL: URL(string: "https://www.bing.com")!,
        keyword: "b"
    )

    /// The built-in engines. The full set, custom ones included, is
    /// `Settings.searchEngines`.
    static let all: [SearchEngine] = [.duckDuckGo, .google, .bing]

    static func named(_ id: String) -> SearchEngine? {
        all.first { $0.id == id }
    }

    var isBuiltIn: Bool { SearchEngine.all.contains { $0.id == id } }

    func url(for query: String) -> URL? {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&=?"))
        guard let escaped = query.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        return URL(string: queryTemplate.replacingOccurrences(of: "{query}", with: escaped))
    }

    /// A custom engine from what the user typed: a search address with `%s`
    /// (or `{query}`) where the words go. Nil when the address is not one.
    static func custom(name: String, address: String, keyword: String?) -> SearchEngine? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var template = address.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "%s", with: "{query}")
        guard !name.isEmpty, template.contains("{query}") else { return nil }
        if !template.lowercased().hasPrefix("http://"), !template.lowercased().hasPrefix("https://") {
            template = "https://" + template
        }
        guard let probe = URL(string: template.replacingOccurrences(of: "{query}", with: "test")),
              let host = probe.host(), !host.isEmpty,
              let home = URL(string: "\(probe.scheme ?? "https")://\(host)") else { return nil }
        let word = keyword?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return SearchEngine(
            id: "custom:" + UUID().uuidString,
            name: name,
            queryTemplate: template,
            homeURL: home,
            keyword: (word?.isEmpty ?? true) ? nil : word
        )
    }
}
