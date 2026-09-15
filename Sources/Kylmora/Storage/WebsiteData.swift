import Foundation
import WebKit

/// The website data every space holds, as one thing to list and to clear.
///
/// Each space has its own data store, so "all website data" means the
/// default store plus every isolated one the session knows. Private spaces
/// hold theirs in memory and are not listed: there is nothing on disk to
/// manage, and it goes when they do.
@MainActor
enum WebsiteData {
    /// One site's data across the stores it appears in.
    struct Record: Identifiable, Sendable {
        let id: String
        let displayName: String
        let types: Set<String>
        /// Which stores hold it, so removal can go back to each.
        let identities: [Space.Identity]
    }

    static let cookieTypes: Set<String> = [WKWebsiteDataTypeCookies]

    static func stores(for identities: [Space.Identity]) -> [(Space.Identity, WKWebsiteDataStore)] {
        var seen: Set<Space.Identity> = []
        return identities.compactMap { identity in
            guard !identity.isPrivate, seen.insert(identity).inserted else { return nil }
            return (identity, WebEnvironment.shared.dataStore(for: identity))
        }
    }

    static func records(for identities: [Space.Identity]) async -> [Record] {
        var byName: [String: (types: Set<String>, identities: [Space.Identity])] = [:]
        for (identity, store) in stores(for: identities) {
            let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
            for record in records {
                var entry = byName[record.displayName] ?? (Set<String>(), [])
                entry.types.formUnion(record.dataTypes)
                entry.identities.append(identity)
                byName[record.displayName] = entry
            }
        }
        return byName.keys.sorted().map { name in
            Record(id: name, displayName: name, types: byName[name]!.types, identities: byName[name]!.identities)
        }
    }

    static func remove(_ records: [Record]) async {
        for record in records {
            for (_, store) in stores(for: record.identities) {
                let matching = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
                    .filter { $0.displayName == record.displayName }
                await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: matching)
            }
        }
    }

    static func removeAll(types: Set<String> = WKWebsiteDataStore.allWebsiteDataTypes(), for identities: [Space.Identity]) async {
        for (_, store) in stores(for: identities) {
            await store.removeData(ofTypes: types, modifiedSince: .distantPast)
        }
    }

    /// Whether a target host matches an allow-listed entry (exact match, subdomains, or apex domains).
    static func isHostAllowed(_ host: String, in allowlist: [String]) -> Bool {
        let normHost = SiteSettingsState.normalise(host)
        guard !normHost.isEmpty else { return false }
        for allowed in allowlist {
            let normAllowed = SiteSettingsState.normalise(allowed)
            guard !normAllowed.isEmpty else { continue }
            if normHost == normAllowed || normHost.hasSuffix("." + normAllowed) || normAllowed.hasSuffix("." + normHost) {
                return true
            }
        }
        return false
    }

    /// Whether a target host matches a WebKit data record's displayName.
    static func matches(host: String, displayName: String) -> Bool {
        let h = SiteSettingsState.normalise(host)
        let d = SiteSettingsState.normalise(displayName)
        guard !h.isEmpty && !d.isEmpty else { return false }
        if h == d { return true }
        if h.hasSuffix("." + d) || d.hasSuffix("." + h) { return true }
        return false
    }

    /// Removes website data on quit, preserving records that match the allowlist.
    /// If allowlist is empty, clears all website data across all identities.
    static func clearDataOnQuit(allowlist: [String], for identities: [Space.Identity]) async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        if allowlist.isEmpty {
            await removeAll(types: types, for: identities)
            return
        }
        for (_, store) in stores(for: identities) {
            let records = await store.dataRecords(ofTypes: types)
            let toRemove = records.filter { record in
                !isHostAllowed(record.displayName, in: allowlist)
            }
            if !toRemove.isEmpty {
                await store.removeData(ofTypes: types, for: toRemove)
            }
        }
    }

    /// Removes website data (cookies, storage, cache, databases) for a specific host from the given spaces.
    static func removeData(forHost host: String, in identities: [Space.Identity]) async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        for (_, store) in stores(for: identities) {
            let records = await store.dataRecords(ofTypes: types)
            let matching = records.filter { matches(host: host, displayName: $0.displayName) }
            if !matching.isEmpty {
                await store.removeData(ofTypes: types, for: matching)
            }
        }
    }

    /// Clears all website data (cookies, storage, cache, databases) for a single space identity.
    static func clearSpaceData(for identity: Space.Identity) async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let store = WebEnvironment.shared.dataStore(for: identity)
        await store.removeData(ofTypes: types, modifiedSince: .distantPast)
    }

    /// What a record's types are, in words, for the list.
    static func describe(_ types: Set<String>) -> String {
        var parts: [String] = []
        if types.contains(WKWebsiteDataTypeCookies) { parts.append("Cookies") }
        if types.contains(WKWebsiteDataTypeLocalStorage) || types.contains(WKWebsiteDataTypeSessionStorage) { parts.append("Local Storage") }
        if types.contains(WKWebsiteDataTypeIndexedDBDatabases) { parts.append("Databases") }
        if types.contains(WKWebsiteDataTypeDiskCache) || types.contains(WKWebsiteDataTypeMemoryCache) { parts.append("Cache") }
        if types.contains(WKWebsiteDataTypeServiceWorkerRegistrations) { parts.append("Service Workers") }
        if parts.isEmpty { parts.append("Website Data") }
        return parts.joined(separator: ", ")
    }
}
