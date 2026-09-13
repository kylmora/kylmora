import Foundation
import WebKit

/// Applies the chosen filter lists to every web view.
///
/// One instance for the app, because the compiled lists are shared: WebKit
/// compiles a list once into `WKContentRuleListStore` and hands the same
/// object to every configuration that asks. Web views register their content
/// controllers here as they are made, so a switch flipped in Settings reaches
/// every open page -- on its next load, which is how Safari's blockers work
/// too.
@MainActor
final class ContentBlocker {
    static let shared = ContentBlocker()

    /// What a list is doing, for the info popover and the pane's footer.
    enum ListStatus: Equatable, Sendable {
        case idle
        case fetching
        case ready(rules: Int, fetched: Date)
        case failed(String)
    }

    private(set) var statuses: [String: ListStatus] = [:]
    /// Fires on the main actor whenever a status or the active set changes.
    var onChange: (() -> Void)?

    private let settings: Settings
    private let store: FilterListStore
    private let ruleStore: WKContentRuleListStore
    private var compiled: [String: WKContentRuleList] = [:]
    /// The per-site cookie and font choices, as one small compiled list.
    private var siteRules: WKContentRuleList?
    private var siteRulesIdentifier: String?
    /// Controllers whose page is on a site with content blockers off.
    private let exempt = NSHashTable<WKUserContentController>.weakObjects()
    private var identifiers: [String: String] = [:]
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    private var compiling: Set<String> = []

    init(settings: Settings = .shared, store: FilterListStore = .shared,
         ruleStore: WKContentRuleListStore = .default()) {
        self.settings = settings
        self.store = store
        self.ruleStore = ruleStore
    }

    /// The lists the preferences say to apply.
    var activeLists: [FilterList] { settings.contentBlocking.activeLists() }

    /// Registers a controller and gives it every list that is ready.
    func attach(_ controller: WKUserContentController) {
        controllers.add(controller)
        apply(to: controller)
    }

    /// Loads, fetching and compiling whatever is active and not yet ready.
    func start() {
        for list in activeLists { ensureCompiled(list) }
        siteSettingsChanged()
    }

    /// The per-site choices changed: recompile their list and reapply.
    func siteSettingsChanged() {
        let rules = SiteSettings.shared.siteRules()
        guard !rules.isEmpty, let data = try? JSONSerialization.data(withJSONObject: rules) else {
            siteRules = nil
            siteRulesIdentifier = nil
            applyToAll()
            return
        }
        let json = String(decoding: data, as: UTF8.self)
        let identifier = "kylmora.site-rules.\(Self.fingerprint(json))"
        guard identifier != siteRulesIdentifier else { return }
        Task { [weak self] in
            guard let self else { return }
            if let list = try? await compileList(identifier: identifier, json: json) {
                siteRules = list
                siteRulesIdentifier = identifier
                applyToAll()
            }
        }
    }

    /// A page is about to load on `url`: the filter lists come off this
    /// controller if the site has content blockers switched off, and go back
    /// on when it moves to a site that has them on.
    func applySiteChoice(for url: URL?, to controller: WKUserContentController) {
        let wasExempt = exempt.contains(controller)
        let isExempt = !SiteSettings.shared.blocksContent(for: url)
        guard wasExempt != isExempt else { return }
        if isExempt { exempt.add(controller) } else { exempt.remove(controller) }
        apply(to: controller)
    }

    /// The preferences changed: bring the set of applied lists in line.
    func preferencesChanged() {
        for list in activeLists { ensureCompiled(list) }
        applyToAll()
        onChange?()
    }

    /// Every active list fetched again, now.
    func refreshAll() {
        for list in activeLists { refresh(list) }
    }

    /// When the oldest of the applied lists was fetched, or nil while none is.
    var lastUpdated: Date? {
        activeLists.compactMap { list -> Date? in
            if case .ready(_, let fetched) = statuses[list.id] { return fetched }
            return nil
        }.min()
    }

    /// The rules in force, and how many lists they come from.
    var activeSummary: (rules: Int, lists: Int) {
        var rules = 0
        var lists = 0
        for list in activeLists {
            if case .ready(let count, _) = statuses[list.id] {
                lists += 1
                rules += max(count, 0)
            }
        }
        return (rules, lists)
    }

    /// Fetches the list again now, whatever its age.
    func refresh(_ list: FilterList) {
        guard !compiling.contains(list.id) else { return }
        compiling.insert(list.id)
        statuses[list.id] = .fetching
        onChange?()
        Task { [weak self] in
            guard let self else { return }
            do {
                let cached = try await store.download(list)
                await compile(list, text: cached)
            } catch {
                statuses[list.id] = .failed(Self.describe(error))
                compiling.remove(list.id)
                onChange?()
            }
        }
    }

    // MARK: - Compilation

    private func ensureCompiled(_ list: FilterList) {
        guard compiled[list.id] == nil, !compiling.contains(list.id) else { return }
        compiling.insert(list.id)
        statuses[list.id] = .fetching
        onChange?()
        Task { [weak self] in
            guard let self else { return }
            do {
                let cached = try await store.text(for: list, refreshingStale: settings.autoUpdatesFilterLists)
                await compile(list, text: cached)
            } catch {
                statuses[list.id] = .failed(Self.describe(error))
                compiling.remove(list.id)
                onChange?()
            }
        }
    }

    private func compile(_ list: FilterList, text cached: FilterListStore.Cached) async {
        defer { compiling.remove(list.id) }
        // The identifier carries the text's fingerprint and the converter's
        // version, so a fresh download or a changed converter compiles anew
        // and an unchanged one is found in WebKit's cache without converting.
        let identifier = "kylmora.filter.\(list.id).v\(AdblockRuleConverter.version).\(Self.fingerprint(cached.text))"
        if let existing = await lookUp(identifier) {
            var rules = await store.ruleCount(for: list, identifier: identifier)
            if rules == nil {
                // Compiled by an earlier build that kept no count. Counting is
                // a conversion without the compile, once, in the background.
                let text = cached.text
                let counted = await Task.detached(priority: .utility) { AdblockRuleConverter().convert(text).rules.count }.value
                await store.recordRuleCount(counted, for: list, identifier: identifier)
                rules = counted
            }
            adopt(existing, for: list, identifier: identifier, rules: rules, fetched: cached.fetched)
            return
        }
        let text = cached.text
        let output = await Task.detached(priority: .utility) { AdblockRuleConverter().convert(text) }.value
        do {
            let json = try output.encoded()
            let ruleList = try await compileList(identifier: identifier, json: json)
            await store.recordRuleCount(output.rules.count, for: list, identifier: identifier)
            adopt(ruleList, for: list, identifier: identifier, rules: output.rules.count, fetched: cached.fetched)
        } catch {
            statuses[list.id] = .failed(Self.describe(error))
            onChange?()
        }
    }

    private func adopt(_ ruleList: WKContentRuleList, for list: FilterList, identifier: String, rules: Int?, fetched: Date) {
        if let previous = identifiers[list.id], previous != identifier {
            ruleStore.removeContentRuleList(forIdentifier: previous) { _ in }
        }
        identifiers[list.id] = identifier
        compiled[list.id] = ruleList
        statuses[list.id] = .ready(rules: rules ?? -1, fetched: fetched)
        applyToAll()
        onChange?()
    }

    private func lookUp(_ identifier: String) async -> WKContentRuleList? {
        await withCheckedContinuation { continuation in
            ruleStore.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
                continuation.resume(returning: list)
            }
        }
    }

    private func compileList(identifier: String, json: String) async throws -> WKContentRuleList {
        try await withCheckedThrowingContinuation { continuation in
            ruleStore.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, error in
                if let list {
                    continuation.resume(returning: list)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.coderInvalidValue))
                }
            }
        }
    }

    // MARK: - Applying

    private func applyToAll() {
        for controller in controllers.allObjects { apply(to: controller) }
    }

    private func apply(to controller: WKUserContentController) {
        controller.removeAllContentRuleLists()
        if !exempt.contains(controller) {
            for list in activeLists {
                if let ruleList = compiled[list.id] { controller.add(ruleList) }
            }
        }
        // The user's own per-site rules apply whatever the filter lists do.
        if let siteRules { controller.add(siteRules) }
    }

    // MARK: - Helpers

    /// Cheap and stable; collisions only cost a recompile.
    private static func fingerprint(_ text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func describe(_ error: Error) -> String {
        if let failure = error as? LiveFolderFetcher.Failure {
            switch failure {
            case .notFound: return "The list's address was not found."
            case .tooLarge: return "The list is too large to download."
            case .transport(let message): return message
            case .status(let code): return "The server answered \(code)."
            case .rateLimited: return "The server asked us to slow down."
            case .unsupportedScheme: return "The list's address is not a web address."
            }
        }
        return error.localizedDescription
    }
}
