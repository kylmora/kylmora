import AppKit
import Foundation

/// Categories of customizable keyboard shortcuts in Kylmora.
public enum ShortcutCategory: String, CaseIterable, Codable, Sendable {
    case tabs = "Tabs"
    case navigation = "Navigation"
    case spaces = "Spaces"
    case appearance = "Appearance"
    case tools = "Tools"
}

/// Helper for formatting key equivalents and modifier flags for human display.
public enum ShortcutFormatter {
    public static func format(key: String, modifiers: NSEvent.ModifierFlags) -> String {
        var str = ""
        let mods = modifiers.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.control) { str += "⌃" }
        if mods.contains(.option) { str += "⌥" }
        if mods.contains(.shift) { str += "⇧" }
        if mods.contains(.command) { str += "⌘" }

        switch key {
        case "\u{2190}": str += "←"
        case "\u{2192}": str += "→"
        case "\u{2191}": str += "↑"
        case "\u{2193}": str += "↓"
        case "\r": str += "↩"
        case "\u{1b}": str += "⎋"
        case " ": str += "Space"
        default: str += key.uppercased()
        }
        return str
    }
}

/// A serialized custom keyboard shortcut override.
public struct CustomShortcut: Codable, Equatable, Sendable {
    public var key: String
    public var modifierFlagsRaw: UInt

    public init(key: String, modifiers: NSEvent.ModifierFlags) {
        self.key = key
        self.modifierFlagsRaw = modifiers.intersection(.deviceIndependentFlagsMask).rawValue
    }

    public var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlagsRaw)
    }

    public var displayString: String {
        ShortcutFormatter.format(key: key, modifiers: modifiers)
    }
}

/// A configurable keyboard shortcut definition.
public struct ShortcutDefinition: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let category: ShortcutCategory
    public let selector: Selector
    public let defaultKey: String
    public let defaultModifiers: NSEvent.ModifierFlags

    public init(
        id: String,
        title: String,
        category: ShortcutCategory,
        selector: Selector,
        defaultKey: String,
        defaultModifiers: NSEvent.ModifierFlags = .command
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.selector = selector
        self.defaultKey = defaultKey
        self.defaultModifiers = defaultModifiers
    }

    public var defaultDisplayString: String {
        ShortcutFormatter.format(key: defaultKey, modifiers: defaultModifiers)
    }
}
