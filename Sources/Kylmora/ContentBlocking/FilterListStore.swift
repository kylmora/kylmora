import Foundation

/// Fetches filter lists and keeps a copy on disk.
///
/// Anonymous, through the live folders' client: a list download is a
/// background request the user did not make, and nothing about it should
/// carry a site login. The copy on disk is what makes the second launch fast
/// -- WebKit caches the compiled form, but the text is needed again whenever
/// the converter changes -- and what keeps blocking working offline.
actor FilterListStore {
    static let shared = FilterListStore()

    /// A list older than this is fetched again. A week: lists change daily,
    /// but a day-old list blocks almost exactly what a fresh one does.
    static let refreshInterval: TimeInterval = 7 * 24 * 60 * 60

    struct Cached: Sendable {
        var text: String
        var fetched: Date
        var isStale: Bool { Date.now.timeIntervalSince(fetched) > FilterListStore.refreshInterval }
    }

    private let directory: URL
    private let fetcher: LiveFolderFetcher

    init(directory: URL = AppPaths.supportDirectory.appending(path: "filter-lists", directoryHint: .isDirectory),
         fetcher: LiveFolderFetcher = .shared) {
        self.directory = directory
        self.fetcher = fetcher
    }

    private func file(for list: FilterList) -> URL {
        directory.appending(path: "\(list.id).txt")
    }

    func cached(_ list: FilterList) -> Cached? {
        let url = file(for: list)
        guard let data = try? Data(contentsOf: url),
              let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        else { return nil }
        return Cached(text: String(decoding: data, as: UTF8.self), fetched: modified)
    }

    /// The list's text: the copy on disk while it is fresh, a new download
    /// when it is stale or missing, and the stale copy again if the download
    /// fails. Nil only when there has never been a copy and the download
    /// failed too.
    func text(for list: FilterList, refreshingStale: Bool = true) async throws -> Cached {
        if let cached = cached(list), !cached.isStale || !refreshingStale { return cached }
        do {
            return try await download(list)
        } catch {
            if let cached = cached(list) { return cached }
            throw error
        }
    }

    /// How many rules a compilation produced, kept beside the text so a
    /// list found in WebKit's cache on the next launch still has a number.
    /// Keyed on the compilation's identifier, so a stale count is never
    /// reported for a new download.
    func recordRuleCount(_ count: Int, for list: FilterList, identifier: String) {
        let record = ["identifier": identifier, "rules": String(count)]
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: directory.appending(path: "\(list.id).rules.json"), options: .atomic)
    }

    func ruleCount(for list: FilterList, identifier: String) -> Int? {
        guard let data = try? Data(contentsOf: directory.appending(path: "\(list.id).rules.json")),
              let record = try? JSONDecoder().decode([String: String].self, from: data),
              record["identifier"] == identifier, let count = record["rules"].flatMap(Int.init)
        else { return nil }
        return count
    }

    func download(_ list: FilterList) async throws -> Cached {
        let response = try await fetcher.get(list.url, accept: "text/plain")
        // A filter list is lines starting with "!" or "[Adblock"; a sign-in
        // page or an error page is not, and must not be cached as one.
        let head = response.text.prefix(200)
        guard head.contains("[Adblock") || head.hasPrefix("!") || head.contains("\n!") else {
            throw LiveFolderFetcher.Failure.status(response.status)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try response.data.write(to: file(for: list), options: .atomic)
        return Cached(text: response.text, fetched: .now)
    }

    // MARK: - Custom Filter Lists

    private func file(forCustomId id: String) -> URL {
        directory.appending(path: "custom-\(id).txt")
    }

    func cachedCustom(id: String) -> Cached? {
        let url = file(forCustomId: id)
        guard let data = try? Data(contentsOf: url),
              let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        else { return nil }
        return Cached(text: String(decoding: data, as: UTF8.self), fetched: modified)
    }

    func textForCustom(id: String, url: URL, refreshingStale: Bool = true) async throws -> Cached {
        if let cached = cachedCustom(id: id), !cached.isStale || !refreshingStale { return cached }
        do {
            return try await downloadCustom(id: id, url: url)
        } catch {
            if let cached = cachedCustom(id: id) { return cached }
            throw error
        }
    }

    func downloadCustom(id: String, url: URL) async throws -> Cached {
        let response = try await fetcher.get(url, accept: "text/plain")
        let head = response.text.prefix(200)
        guard head.contains("[Adblock") || head.hasPrefix("!") || head.contains("\n!") || head.contains("##") || head.contains("||") else {
            throw LiveFolderFetcher.Failure.status(response.status)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try response.data.write(to: file(forCustomId: id), options: .atomic)
        return Cached(text: response.text, fetched: .now)
    }

    func recordCustomRuleCount(_ count: Int, id: String, identifier: String) {
        let record = ["identifier": identifier, "rules": String(count)]
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: directory.appending(path: "custom-\(id).rules.json"), options: .atomic)
    }

    func customRuleCount(id: String, identifier: String) -> Int? {
        guard let data = try? Data(contentsOf: directory.appending(path: "custom-\(id).rules.json")),
              let record = try? JSONDecoder().decode([String: String].self, from: data),
              record["identifier"] == identifier, let count = record["rules"].flatMap(Int.init)
        else { return nil }
        return count
    }
}

