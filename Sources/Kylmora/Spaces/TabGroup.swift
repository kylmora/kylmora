import AppKit

/// A named, collapsible set of tabs inside a Space.
///
/// This is the third level of organisation, between Space and Tab: a Space is
/// the workspace you switch to, a Group is a named cluster of related tabs
/// inside it, and a Tab is a page. Groups exist because a research session or a
/// ticket produces a burst of tabs that belong together and should be
/// collapsible as a unit.
///
/// A group holds no tabs itself. Tabs keep their place in the Space's single
/// ordered list and point at a group by identifier, so grouping never reorders
/// anything and an empty group is a legitimate state rather than a bug.
///
/// Nesting is the same trick one level up: a group points at its parent by
/// identifier instead of owning an array of children. The alternative -- a real
/// element chain -- makes reparenting a splice, makes
/// every predicate walk pointers, and forces an invisible placeholder tab into
/// every folder so the tree machinery cannot dissolve an empty one. None of
/// that is needed here.
@MainActor
final class TabGroup: Identifiable {
    let id: UUID

    var name: String
    /// Shown before the name. Optional, because forcing a symbol on every group
    /// produces meaningless ones.
    var emoji: String?
    var tint: NSColor
    /// How the plate behind the group is painted: the default, a solid colour,
    /// or a gradient. `tint` is only the header dot; this is the block.
    var appearance: TabGroupAppearance
    /// Collapsed hides the group's tabs in the sidebar. It does not suspend
    /// them; that is the memory policy's decision, not the user's filing.
    var isCollapsed: Bool

    /// The group this one is filed inside, if any. `nil` is a root group.
    ///
    /// Validity -- no cycles, no self-parenting, no nesting past the depth cap
    /// -- is not enforced here because a single group cannot see the others.
    /// `FolderTree` owns those rules and every mutation path goes through it.
    var parentID: TabGroup.ID?

    /// An SF Symbol chosen for the folder, when the user wanted a symbol rather
    /// than an emoji. The two are separate fields, not one enum, so that a
    /// session written before symbols existed still restores its emoji.
    var symbolName: String?
    /// A picture chosen instead of either, by its file name in
    /// `SpaceIconStore`. A third field rather than a third case for the same
    /// reason the first two are separate: a session written before pictures
    /// existed still restores its emoji.
    var iconFileName: String?

    /// True when the contents are maintained by a `LiveFolderProvider` rather
    /// than by the user. The provider's configuration and its accumulated state
    /// deliberately live outside the group, in `LiveFolderStore`: they are
    /// device-local, they are rewritten on every refresh, and the sidebar has
    /// no business reloading a row because a poll timer moved.
    var isLive: Bool

    /// Refuses to be deleted. Protects the folder itself -- its name, its
    /// colour, the fact that it groups these tabs -- not the tabs inside it,
    /// which carry their own locks. Deleting a folder is one keystroke away
    /// from a fortnight of filing, and there is no undo for it.
    var isLocked: Bool

    init(
        id: UUID = UUID(),
        name: String,
        emoji: String? = nil,
        tint: NSColor = .controlAccentColor,
        appearance: TabGroupAppearance = .standard,
        isCollapsed: Bool = false,
        parentID: TabGroup.ID? = nil,
        symbolName: String? = nil,
        iconFileName: String? = nil,
        isLive: Bool = false,
        isLocked: Bool = false
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.tint = tint
        self.appearance = appearance
        self.isCollapsed = isCollapsed
        self.parentID = parentID
        self.symbolName = symbolName
        self.iconFileName = iconFileName
        self.isLive = isLive
        self.isLocked = isLocked
    }

    var displayName: String {
        guard let emoji, !emoji.isEmpty else { return name }
        return "\(emoji) \(name)"
    }

    /// What the folder header draws.
    ///
    /// A picture wins over an emoji, which wins over a symbol, in order of how
    /// deliberate the choice is. In practice only one field is ever set --
    /// `BrowserSession.setIcon(_:for:)` clears the others -- and the order is
    /// what decides it for a session file written by hand or merged by sync.
    var icon: FolderIcon {
        if let iconFileName, !iconFileName.isEmpty { return .custom(iconFileName) }
        if let emoji, !emoji.isEmpty { return .emoji(emoji) }
        if let symbolName, !symbolName.isEmpty { return .symbol(symbolName) }
        return .automatic
    }

    /// Puts one of the three fields in and takes the other two out, so the
    /// folder wears one thing at a time.
    func setIcon(_ icon: FolderIcon) {
        switch icon {
        case .automatic:
            (emoji, symbolName, iconFileName) = (nil, nil, nil)
        case .emoji(let text):
            (emoji, symbolName, iconFileName) = (text, nil, nil)
        case .symbol(let name):
            (emoji, symbolName, iconFileName) = (nil, name, nil)
        case .custom(let fileName):
            (emoji, symbolName, iconFileName) = (nil, nil, fileName)
        }
    }
}
