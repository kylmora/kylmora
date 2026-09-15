import Foundation

/// Merges remote and local sync archives intelligently.
///
/// Designed to preserve local edits while incorporating changes from other
/// devices without losing spaces, folders, pinned items, or bookmarks.
enum SyncMergePolicy {
    enum MergeMode {
        case merge
        case replace
    }

    struct MergeSummary: Equatable, Sendable {
        var addedSpaces: Int = 0
        var addedGroups: Int = 0
        var addedPinnedSites: Int = 0
        var addedTabs: Int = 0
        var addedBookmarks: Int = 0
        var updatedSiteSettings: Int = 0
        var addedRoutes: Int = 0
        var addedVisits: Int = 0
        var addedCredentials: Int = 0

        var hasChanges: Bool {
            addedSpaces > 0 || addedGroups > 0 || addedPinnedSites > 0 ||
            addedTabs > 0 || addedBookmarks > 0 || updatedSiteSettings > 0 || addedRoutes > 0 ||
            addedVisits > 0 || addedCredentials > 0
        }
    }

    /// Merges a remote archive into a local archive based on user sync preferences.
    static func merge(
        local: SyncArchive,
        remote: SyncArchive,
        syncOpenTabs: Bool = true,
        syncBookmarks: Bool = true,
        syncSiteSettings: Bool = true,
        syncHistory: Bool = false,
        syncPasswords: Bool = false
    ) -> (merged: SyncArchive, summary: MergeSummary) {
        var summary = MergeSummary()
        var mergedSession = local.session

        // 1. Merge Spaces, Folders, Pinned Sites, and Tabs
        for remoteSpace in remote.session.spaces {
            if let localIndex = mergedSession.spaces.firstIndex(where: {
                $0.name.localizedCaseInsensitiveCompare(remoteSpace.name) == .orderedSame
            }) {
                var localSpace = mergedSession.spaces[localIndex]

                // Merge Groups (Folders)
                var localGroups = localSpace.groups ?? []
                let localGroupIDs = Set(localGroups.map(\.id))
                for remoteGroup in remoteSpace.groups ?? [] where !localGroupIDs.contains(remoteGroup.id) {
                    localGroups.append(remoteGroup)
                    summary.addedGroups += 1
                }
                localSpace.groups = localGroups

                // Merge Pinned Sites
                var localPinned = localSpace.pinnedSites ?? []
                let localPinnedURLs = Set(localPinned.map(\.url.absoluteString))
                for remotePin in remoteSpace.pinnedSites ?? [] where !localPinnedURLs.contains(remotePin.url.absoluteString) {
                    localPinned.append(remotePin)
                    summary.addedPinnedSites += 1
                }
                localSpace.pinnedSites = localPinned

                // Merge Tabs if enabled
                if syncOpenTabs {
                    var localTabs = localSpace.tabs
                    let localTabURLs = Set(localTabs.map(\.url.absoluteString))
                    for remoteTab in remoteSpace.tabs where !localTabURLs.contains(remoteTab.url.absoluteString) {
                        localTabs.append(remoteTab)
                        summary.addedTabs += 1
                    }
                    localSpace.tabs = localTabs
                }

                mergedSession.spaces[localIndex] = localSpace
            } else {
                // New Space from another device
                var newSpace = remoteSpace
                if !syncOpenTabs {
                    newSpace.tabs = []
                }
                mergedSession.spaces.append(newSpace)
                summary.addedSpaces += 1
                if syncOpenTabs {
                    summary.addedTabs += newSpace.tabs.count
                }
            }
        }

        // 2. Merge Bookmarks
        var mergedBookmarks = local.bookmarks
        if syncBookmarks {
            let localBookmarkURLs = Set(local.bookmarks.map(\.url.absoluteString))
            for remoteBookmark in remote.bookmarks where !localBookmarkURLs.contains(remoteBookmark.url.absoluteString) {
                mergedBookmarks.append(remoteBookmark)
                summary.addedBookmarks += 1
            }
        }

        // 3. Merge Site Settings
        var mergedSiteSettings = local.siteSettings
        if syncSiteSettings, let remoteSettings = remote.siteSettings {
            var current = mergedSiteSettings ?? SiteSettingsState()
            for (category, option) in remoteSettings.defaults where current.defaults[category] == nil {
                current.defaults[category] = option
            }
            for (category, hosts) in remoteSettings.sites {
                for (host, option) in hosts where current.sites[category]?[host] == nil {
                    current.set(option, for: host, in: category)
                    summary.updatedSiteSettings += 1
                }
            }
            mergedSiteSettings = current
        }

        // 4. Merge Space Routing Rules
        var mergedRouting = local.spaceRouting ?? []
        let existingPatterns = Set(mergedRouting.map { "\($0.reference)|\($0.match.rawValue)" })
        for remoteRoute in remote.spaceRouting ?? [] {
            let key = "\(remoteRoute.reference)|\(remoteRoute.match.rawValue)"
            if !existingPatterns.contains(key) {
                mergedRouting.append(remoteRoute)
                summary.addedRoutes += 1
            }
        }

        // 5. Merge Custom Search Engines
        var mergedSearchEngines = local.customSearchEngines ?? []
        let existingEngineIDs = Set(mergedSearchEngines.map(\.id))
        for remoteEngine in remote.customSearchEngines ?? [] where !existingEngineIDs.contains(remoteEngine.id) {
            mergedSearchEngines.append(remoteEngine)
        }

        // 6. Merge history: every visit the other device saw that this one
        // did not, newest kept when the cap is reached.
        var mergedHistory = local.history
        if syncHistory, let remoteHistory = remote.history {
            var current = local.history ?? []
            let seen = Set(current.map(\.key))
            for visit in remoteHistory where !seen.contains(visit.key) {
                current.append(visit)
                summary.addedVisits += 1
            }
            current.sort { $0.visitedAt > $1.visitedAt }
            mergedHistory = Array(current.prefix(SyncArchive.historyLimit))
        }

        // 7. Merge logins: a login this device does not have is added; one it
        // has keeps the local password, so a change made here is never
        // overwritten by a stale copy from elsewhere.
        var mergedCredentials = local.credentials
        if syncPasswords, let remoteCredentials = remote.credentials {
            var current = local.credentials ?? []
            let seen = Set(current.map(\.key))
            for credential in remoteCredentials where !seen.contains(credential.key) {
                current.append(credential)
                summary.addedCredentials += 1
            }
            mergedCredentials = current
        }

        var result = SyncArchive(
            version: SyncArchive.currentVersion,
            deviceID: local.deviceID,
            deviceName: local.deviceName,
            exportedAt: .now,
            session: mergedSession,
            bookmarks: mergedBookmarks,
            siteSettings: mergedSiteSettings,
            spaceRouting: mergedRouting,
            customSearchEngines: mergedSearchEngines,
            defaultSearchEngineID: local.defaultSearchEngineID ?? remote.defaultSearchEngineID
        )
        result.history = mergedHistory
        result.credentials = mergedCredentials

        return (result, summary)
    }
}
