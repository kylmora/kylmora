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
    private(set) var customStatuses: [UUID: ListStatus] = [:]
    /// Fires on the main actor whenever a status or the active set changes.
    /// Multicast: every subscriber is notified, so the Privacy footer and the
    /// Advanced Blocking rows can both listen without clobbering each other.
    var onChange: (() -> Void)? {
        get { legacyChangeHandler }
        set {
            if let token = legacyChangeToken {
                changeObservers.removeValue(forKey: token)
                legacyChangeToken = nil
            }
            legacyChangeHandler = newValue
            if let newValue {
                legacyChangeToken = addChangeObserver(newValue)
            }
        }
    }
    private var legacyChangeHandler: (() -> Void)?
    private var legacyChangeToken: UUID?
    private var changeObservers: [UUID: () -> Void] = [:]

    /// Adds a change observer, returning a token for `removeChangeObserver`.
    func addChangeObserver(_ observer: @escaping () -> Void) -> UUID {
        let token = UUID()
        changeObservers[token] = observer
        return token
    }

    func removeChangeObserver(_ token: UUID) {
        changeObservers.removeValue(forKey: token)
    }

    private func notifyChange() {
        for observer in changeObservers.values {
            observer()
        }
    }

    private let settings: Settings
    private let store: FilterListStore
    private let ruleStore: WKContentRuleListStore
    private var compiled: [String: WKContentRuleList] = [:]
    private var customCompiled: [UUID: WKContentRuleList] = [:]
    private var customIdentifiers: [UUID: String] = [:]
    private var customCompiling: Set<UUID> = []
    /// The user's custom ABP cosmetic and network rules.
    private var userRules: WKContentRuleList?
    private var userRulesIdentifier: String?
    private(set) var userRulesCount: Int = 0
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
    ///
    /// The Space is remembered because an extension's `declarativeNetRequest`
    /// rules apply only where that extension is enabled, and the controller is
    /// the only handle on the page this far down.
    func attach(_ controller: WKUserContentController, identity: Space.Identity? = nil) {
        controllers.add(controller)
        if let identity { identities.setObject(IdentityBox(identity), forKey: controller) }
        apply(to: controller)
    }

    /// A Space identity is an enum, and `NSMapTable` wants an object.
    private final class IdentityBox {
        let identity: Space.Identity
        init(_ identity: Space.Identity) { self.identity = identity }
    }

    private let identities = NSMapTable<WKUserContentController, IdentityBox>.weakToStrongObjects()

    /// An extension's translated rules changed: every open page's controller
    /// takes the new list on its next load, as with any other list here.
    func extensionRulesChanged() {
        applyToAll()
    }

    /// Loads, fetching and compiling whatever is active and not yet ready.
    func start() {
        for list in activeLists { ensureCompiled(list) }
        compileCustomLists()
        compileUserRules()
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
        compileCustomLists()
        compileUserRules()
        applyToAll()
        notifyChange()
    }

    /// Every active list fetched again, now.
    func refreshAll() {
        for list in activeLists { refresh(list) }
        for customList in settings.customFilterLists where customList.isEnabled {
            refreshCustomList(customList)
        }
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
        for customList in settings.customFilterLists where customList.isEnabled {
            if case .ready(let count, _) = customStatuses[customList.id] {
                lists += 1
                rules += max(count, 0)
            }
        }
        rules += userRulesCount
        return (rules, lists)
    }

    /// Fetches the list again now, whatever its age.
    func refresh(_ list: FilterList) {
        guard !compiling.contains(list.id) else { return }
        compiling.insert(list.id)
        statuses[list.id] = .fetching
        notifyChange()
        Task { [weak self] in
            guard let self else { return }
            do {
                let cached = try await store.download(list)
                await compile(list, text: cached)
            } catch {
                statuses[list.id] = .failed(Self.describe(error))
                compiling.remove(list.id)
                notifyChange()
            }
        }
    }

    // MARK: - Compilation

    private func ensureCompiled(_ list: FilterList) {
        guard compiled[list.id] == nil, !compiling.contains(list.id) else { return }
        compiling.insert(list.id)
        statuses[list.id] = .fetching
        notifyChange()
        Task { [weak self] in
            guard let self else { return }
            do {
                let cached = try await store.text(for: list, refreshingStale: settings.autoUpdatesFilterLists)
                await compile(list, text: cached)
            } catch {
                statuses[list.id] = .failed(Self.describe(error))
                compiling.remove(list.id)
                notifyChange()
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
            notifyChange()
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
        notifyChange()
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
            for customList in settings.customFilterLists where customList.isEnabled {
                if let ruleList = customCompiled[customList.id] { controller.add(ruleList) }
            }
            if let userRules { controller.add(userRules) }
            // An extension's own rules, translated. These are not part of the
            // user's filter lists and are not switched by them: an extension
            // the person installed and enabled for this Space blocks what it
            // says it blocks.
            if let identity = identities.object(forKey: controller)?.identity {
                for ruleList in DeclarativeNetRequestService.shared.ruleLists(for: identity) {
                    controller.add(ruleList)
                }
            }
        }
        // The user's own per-site rules apply whatever the filter lists do.
        if let siteRules { controller.add(siteRules) }
    }

    // MARK: - User Rules

    /// Recompiles the user's custom ABP rules from Settings.shared.userRulesText.
    func compileUserRules() {
        let text = settings.userRulesText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            if let previous = userRulesIdentifier {
                ruleStore.removeContentRuleList(forIdentifier: previous) { _ in }
            }
            userRules = nil
            userRulesIdentifier = nil
            userRulesCount = 0
            applyToAll()
            notifyChange()
            return
        }

        let output = AdblockRuleConverter().convert(text)
        guard !output.rules.isEmpty else {
            userRules = nil
            userRulesCount = 0
            applyToAll()
            notifyChange()
            return
        }

        userRulesCount = output.rules.count
        let identifier = "kylmora.user-rules.v\(AdblockRuleConverter.version).\(Self.fingerprint(text))"
        guard identifier != userRulesIdentifier else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                let json = try output.encoded()
                let ruleList = try await self.compileList(identifier: identifier, json: json)
                if let previous = self.userRulesIdentifier, previous != identifier {
                    self.ruleStore.removeContentRuleList(forIdentifier: previous) { _ in }
                }
                self.userRules = ruleList
                self.userRulesIdentifier = identifier
                self.applyToAll()
                notifyChange()
            } catch {
                NSLog("Kylmora: failed to compile user rules: \(error.localizedDescription)")
            }
        }
    }

    /// Adds a single custom rule (e.g. from the element picker) and immediately reapplies.
    func addUserRule(_ rule: String) {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var current = settings.userRulesText
        if !current.isEmpty && !current.hasSuffix("\n") {
            current += "\n"
        }
        current += trimmed + "\n"
        settings.userRulesText = current
        compileUserRules()
    }

    // MARK: - Custom Filter Lists

    func compileCustomLists() {
        let lists = settings.customFilterLists
        let enabledIDs = Set(lists.filter(\.isEnabled).map(\.id))
        for (id, prevIdentifier) in customIdentifiers where !enabledIDs.contains(id) {
            ruleStore.removeContentRuleList(forIdentifier: prevIdentifier) { _ in }
            customCompiled[id] = nil
            customIdentifiers[id] = nil
            customStatuses[id] = nil
        }
        for list in lists where list.isEnabled {
            ensureCompiledCustom(list)
        }
    }

    func refreshCustomList(_ list: CustomFilterList) {
        guard !customCompiling.contains(list.id) else { return }
        customCompiling.insert(list.id)
        customStatuses[list.id] = .fetching
        notifyChange()
        Task { [weak self] in
            guard let self else { return }
            do {
                let cached = try await self.store.downloadCustom(id: list.id.uuidString, url: list.url)
                await self.compileCustom(list, text: cached)
            } catch {
                self.customStatuses[list.id] = .failed(Self.describe(error))
                self.customCompiling.remove(list.id)
                notifyChange()
            }
        }
    }

    private func ensureCompiledCustom(_ list: CustomFilterList) {
        guard customCompiled[list.id] == nil, !customCompiling.contains(list.id) else { return }
        customCompiling.insert(list.id)
        customStatuses[list.id] = .fetching
        notifyChange()
        Task { [weak self] in
            guard let self else { return }
            do {
                let cached = try await self.store.textForCustom(id: list.id.uuidString, url: list.url, refreshingStale: self.settings.autoUpdatesFilterLists)
                await self.compileCustom(list, text: cached)
            } catch {
                self.customStatuses[list.id] = .failed(Self.describe(error))
                self.customCompiling.remove(list.id)
                notifyChange()
            }
        }
    }

    private func compileCustom(_ list: CustomFilterList, text cached: FilterListStore.Cached) async {
        defer { customCompiling.remove(list.id) }
        let identifier = "kylmora.custom.\(list.id.uuidString).v\(AdblockRuleConverter.version).\(Self.fingerprint(cached.text))"
        if let existing = await lookUp(identifier) {
            var rules = await store.customRuleCount(id: list.id.uuidString, identifier: identifier)
            if rules == nil {
                let text = cached.text
                let counted = await Task.detached(priority: .utility) { AdblockRuleConverter().convert(text).rules.count }.value
                await store.recordCustomRuleCount(counted, id: list.id.uuidString, identifier: identifier)
                rules = counted
            }
            adoptCustom(existing, for: list, identifier: identifier, rules: rules, fetched: cached.fetched)
            return
        }
        let text = cached.text
        let output = await Task.detached(priority: .utility) { AdblockRuleConverter().convert(text) }.value
        do {
            let json = try output.encoded()
            let ruleList = try await compileList(identifier: identifier, json: json)
            await store.recordCustomRuleCount(output.rules.count, id: list.id.uuidString, identifier: identifier)
            adoptCustom(ruleList, for: list, identifier: identifier, rules: output.rules.count, fetched: cached.fetched)
        } catch {
            customStatuses[list.id] = .failed(Self.describe(error))
            notifyChange()
        }
    }

    private func adoptCustom(_ ruleList: WKContentRuleList, for list: CustomFilterList, identifier: String, rules: Int?, fetched: Date) {
        if let previous = customIdentifiers[list.id], previous != identifier {
            ruleStore.removeContentRuleList(forIdentifier: previous) { _ in }
        }
        customIdentifiers[list.id] = identifier
        customCompiled[list.id] = ruleList
        customStatuses[list.id] = .ready(rules: rules ?? -1, fetched: fetched)
        applyToAll()
        notifyChange()
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
