import Foundation
import AppKit

/// Imports spaces, folders, pinned tabs, and open tabs from Arc's `StorableSidebar.json`.
///
/// Designed to enable seamless one-click migration for Arc users switching to Kylmora.
enum ArcSidebarImporter {
    enum Failure: Error, Equatable {
        case unreadable
        case invalidFormat
        case noSpacesFound
    }

    struct ParsedSpace {
        var id: String
        var title: String
        var themeColorHex: String?
    }

    struct ParsedItem {
        var id: String
        var parentID: String?
        var title: String?
        var url: URL?
        var isFolder: Bool
        var isPinned: Bool
    }

    /// Reads and parses Arc's `StorableSidebar.json` data into a Kylmora `SessionSnapshot`.
    static func importSidebar(from data: Data) throws -> SessionSnapshot {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.invalidFormat
        }

        var parsedSpaces: [ParsedSpace] = []
        var parsedItems: [ParsedItem] = []

        // Arc has varied its schema across versions:
        // Version 1: root["sidebar"]["containers"]
        // Version 2: root["sidebarSyncState"]["items"] / ["spaces"]
        // Version 3: root["sidebar"]["items"]

        let sidebar = (json["sidebar"] as? [String: Any]) ?? (json["sidebarSyncState"] as? [String: Any]) ?? json

        // 1. Extract spaces from containers or direct list
        if let containers = sidebar["containers"] as? [[String: Any]] {
            for container in containers {
                if let spaces = container["spaces"] as? [[String: Any]] {
                    for spaceDict in spaces {
                        if let space = parseSpaceDict(spaceDict) {
                            parsedSpaces.append(space)
                        }
                    }
                }
                if let items = container["items"] as? [[String: Any]] {
                    for itemDict in items {
                        if let item = parseItemDict(itemDict) {
                            parsedItems.append(item)
                        }
                    }
                } else if let itemsMap = container["items"] as? [String: [String: Any]] {
                    for (_, itemDict) in itemsMap {
                        if let item = parseItemDict(itemDict) {
                            parsedItems.append(item)
                        }
                    }
                }
            }
        }

        if let directSpaces = sidebar["spaces"] as? [[String: Any]] {
            for spaceDict in directSpaces {
                if let space = parseSpaceDict(spaceDict) {
                    parsedSpaces.append(space)
                }
            }
        }

        if let directItems = sidebar["items"] as? [[String: Any]] {
            for itemDict in directItems {
                if let item = parseItemDict(itemDict) {
                    parsedItems.append(item)
                }
            }
        } else if let itemsMap = sidebar["items"] as? [String: [String: Any]] {
            for (_, itemDict) in itemsMap {
                if let item = parseItemDict(itemDict) {
                    parsedItems.append(item)
                }
            }
        }

        // If no spaces were found, provide a default space for all items
        if parsedSpaces.isEmpty {
            parsedSpaces.append(ParsedSpace(id: "default-space", title: "Personal", themeColorHex: "#007aff"))
        }

        // Map items to spaces
        let spaceIDSet = Set(parsedSpaces.map(\.id))

        var spacesSnapshot: [SessionSnapshot.Space] = []

        for space in parsedSpaces {
            let spaceID = space.id

            // Identify items directly belonging to this space or folders within this space
            var spaceFolderIDs: Set<String> = []
            for item in parsedItems where item.isFolder {
                if item.parentID == spaceID {
                    spaceFolderIDs.insert(item.id)
                }
            }
            // Recurse child folders
            var addedNewFolder = true
            while addedNewFolder {
                addedNewFolder = false
                for item in parsedItems where item.isFolder && !spaceFolderIDs.contains(item.id) {
                    if let parent = item.parentID, spaceFolderIDs.contains(parent) {
                        spaceFolderIDs.insert(item.id)
                        addedNewFolder = true
                    }
                }
            }

            // Groups (Folders)
            let groups: [SessionSnapshot.Group] = parsedItems
                .filter { $0.isFolder && (spaceFolderIDs.contains($0.id) || $0.parentID == spaceID) }
                .compactMap { folder in
                    guard let uuid = UUID(uuidString: folder.id) ?? uuidFromArbitraryID(folder.id) else { return nil }
                    let parentUUID: UUID? = folder.parentID.flatMap { parentID in
                        if spaceFolderIDs.contains(parentID) {
                            return UUID(uuidString: parentID) ?? uuidFromArbitraryID(parentID)
                        }
                        return nil
                    }
                    return SessionSnapshot.Group(
                        id: uuid,
                        name: folder.title ?? "Folder",
                        emoji: nil,
                        tint: space.themeColorHex ?? "#007aff",
                        appearance: nil,
                        isCollapsed: false,
                        parentID: parentUUID,
                        symbolName: "folder",
                        isLive: nil
                    )
                }

            // Pinned sites
            let pinnedSites: [SessionSnapshot.Pinned] = parsedItems
                .filter { item in
                    guard item.url != nil, !item.isFolder else { return false }
                    return item.isPinned && (item.parentID == spaceID || !spaceIDSet.contains(item.parentID ?? ""))
                }
                .compactMap { pin in
                    guard let url = pin.url else { return nil }
                    let uuid = UUID(uuidString: pin.id) ?? uuidFromArbitraryID(pin.id) ?? UUID()
                    return SessionSnapshot.Pinned(
                        id: uuid,
                        url: url,
                        title: pin.title ?? url.host() ?? url.absoluteString
                    )
                }

            // Tabs (unpinned tabs and tabs in folders)
            let tabs: [SessionSnapshot.Tab] = parsedItems
                .filter { item in
                    guard let _ = item.url, !item.isFolder else { return false }
                    if item.isPinned { return false }
                    if item.parentID == spaceID { return true }
                    if let parent = item.parentID, spaceFolderIDs.contains(parent) { return true }
                    // If item parent isn't any known space, put in first space
                    if parsedSpaces.first?.id == spaceID && !spaceIDSet.contains(item.parentID ?? "") {
                        return true
                    }
                    return false
                }
                .compactMap { tab in
                    guard let url = tab.url else { return nil }
                    let groupUUID: UUID? = tab.parentID.flatMap { parentID in
                        if spaceFolderIDs.contains(parentID) {
                            return UUID(uuidString: parentID) ?? uuidFromArbitraryID(parentID)
                        }
                        return nil
                    }
                    return SessionSnapshot.Tab(
                        url: url,
                        title: tab.title ?? url.host() ?? url.absoluteString,
                        groupID: groupUUID,
                        customName: tab.title
                    )
                }

            let themeString = space.themeColorHex ?? "blue"

            spacesSnapshot.append(
                SessionSnapshot.Space(
                    name: space.title,
                    symbolName: nil,
                    tint: themeString,
                    tabs: tabs,
                    activeTabIndex: tabs.isEmpty ? nil : 0,
                    profileID: nil,
                    identity: .standard,
                    theme: themeString,
                    border: nil,
                    look: nil,
                    groups: groups,
                    pinnedSites: pinnedSites,
                    archivedTabs: nil
                )
            )
        }

        guard !spacesSnapshot.isEmpty else {
            throw Failure.noSpacesFound
        }

        return SessionSnapshot(
            spaces: spacesSnapshot,
            activeSpaceIndex: 0
        )
    }

    private static func parseSpaceDict(_ dict: [String: Any]) -> ParsedSpace? {
        guard let id = dict["id"] as? String else { return nil }
        let title = (dict["title"] as? String) ?? "Space"

        var colorHex: String?
        if let customInfo = dict["customInfo"] as? [String: Any],
           let windowTheme = customInfo["windowTheme"] as? [String: Any] {
            if let singleColor = windowTheme["singleColor"] as? [String: Any],
               let r = singleColor["r"] as? Double,
               let g = singleColor["g"] as? Double,
               let b = singleColor["b"] as? Double {
                colorHex = String(format: "#%02x%02x%02x", Int(r * 255), Int(g * 255), Int(b * 255))
            }
        }

        return ParsedSpace(id: id, title: title, themeColorHex: colorHex)
    }

    private static func parseItemDict(_ dict: [String: Any]) -> ParsedItem? {
        guard let id = dict["id"] as? String else { return nil }
        let parentID = dict["parentID"] as? String
        let title = dict["title"] as? String

        var url: URL?
        var isFolder = false

        if let data = dict["data"] as? [String: Any] {
            if let tab = data["tab"] as? [String: Any] {
                if let urlString = tab["savedURL"] as? String {
                    url = URL(string: urlString)
                }
            } else if data["itemContainer"] != nil || data["folder"] != nil {
                isFolder = true
            }
        }

        let isPinned = (dict["pinned"] as? Bool) ?? (dict["isPinned"] as? Bool) ?? false

        return ParsedItem(
            id: id,
            parentID: parentID,
            title: title,
            url: url,
            isFolder: isFolder,
            isPinned: isPinned
        )
    }

    private static func uuidFromArbitraryID(_ text: String) -> UUID? {
        if let uuid = UUID(uuidString: text) { return uuid }
        // Create deterministic UUID from UTF-8 data
        let hash = text.utf8.reduce(into: [UInt8](repeating: 0, count: 16)) { acc, byte in
            acc[Int(byte) % 16] ^= byte
        }
        return UUID(uuid: (
            hash[0], hash[1], hash[2], hash[3],
            hash[4], hash[5], hash[6], hash[7],
            hash[8], hash[9], hash[10], hash[11],
            hash[12], hash[13], hash[14], hash[15]
        ))
    }
}
