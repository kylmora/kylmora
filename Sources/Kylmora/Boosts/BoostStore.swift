import Foundation

/// Persistent store for per-site Boosts (user CSS, JavaScript, and Dark Mode).
@MainActor
final class BoostStore {
    static let shared = BoostStore()

    private let file: URL
    private(set) var boosts: [Boost] = []
    var onChange: (() -> Void)?

    init(file: URL = AppPaths.supportDirectory.appending(path: "boosts.json")) {
        self.file = file
        load()
    }

    convenience init(folder: URL) {
        self.init(file: folder.appending(path: "boosts.json"))
    }

    private func load() {
        guard let data = try? Data(contentsOf: file),
              let loaded = try? JSONDecoder().decode([Boost].self, from: data)
        else {
            boosts = []
            return
        }
        boosts = loaded
    }

    private func persist() {
        AppPaths.ensureSupportDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(boosts).write(to: file, options: .atomic)
        onChange?()
    }

    /// Finds a boost matching the given host or URL.
    func boost(for url: URL?) -> Boost? {
        guard let host = url?.host() else { return nil }
        return boost(forHost: host)
    }

    func boost(for host: String) -> Boost? {
        boost(forHost: host)
    }

    func boost(forHost rawHost: String) -> Boost? {
        let host = SiteSettings.normalise(rawHost)
        guard !host.isEmpty else { return nil }
        // Exact match first
        if let exact = boosts.first(where: { $0.host == host }) {
            return exact
        }
        // Domain suffix match (e.g. "sub.example.com" matches "example.com")
        for boost in boosts where host.hasSuffix("." + boost.host) {
            return boost
        }
        // Wildcard / global fallback
        return boosts.first(where: { $0.host == "*" })
    }

    /// Creates or updates a boost.
    func save(_ boost: Boost) {
        var updated = boost
        updated.dateModified = .now
        if let idx = boosts.firstIndex(where: { $0.id == boost.id || $0.host == boost.host }) {
            boosts[idx] = updated
        } else {
            boosts.append(updated)
        }
        persist()
    }

    /// Deletes a boost by identifier.
    func delete(id: UUID) {
        boosts.removeAll(where: { $0.id == id })
        persist()
    }

    func remove(id: UUID) {
        delete(id: id)
    }

    /// Toggles dark mode for a site. Returns the new state.
    @discardableResult
    func toggleDarkMode(forHost rawHost: String) -> Bool {
        let host = SiteSettings.normalise(rawHost)
        guard !host.isEmpty else { return false }
        var boost = self.boost(forHost: host) ?? Boost(host: host)
        boost.isDarkModeEnabled.toggle()
        save(boost)
        return boost.isDarkModeEnabled
    }

    @discardableResult
    func toggleDarkMode(for host: String) -> Bool {
        toggleDarkMode(forHost: host)
    }

    @discardableResult
    func toggleDarkMode(for url: URL?) -> Bool {
        guard let rawHost = url?.host() else { return false }
        return toggleDarkMode(forHost: rawHost)
    }
}
