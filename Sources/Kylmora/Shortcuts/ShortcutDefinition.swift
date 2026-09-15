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
    /// A chord reads as its two strokes: "⌘K, T".
    public static func format(key: String, modifiers: NSEvent.ModifierFlags, secondKey: String?) -> String {
        let first = format(key: key, modifiers: modifiers)
        guard let secondKey, !secondKey.isEmpty else { return first }
        return first + ", " + format(key: secondKey, modifiers: [])
    }

    public static func format(key: String, modifiers: NSEvent.ModifierFlags) -> String {
        var str = ""
        let mods = modifiers.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.control) { str += "⌃" }
        if mods.contains(.option) { str += "⌥" }
        if mods.contains(.shift) { str += "⇧" }
        if mods.contains(.command) { str += "⌘" }

        switch key {
        case "\u{2190}", "\u{F702}": str += "←"
        case "\u{2192}", "\u{F703}": str += "→"
        case "\u{2191}", "\u{F700}": str += "↑"
        case "\u{2193}", "\u{F701}": str += "↓"
        case "\r": str += "↩"
        case "\u{1b}": str += "⎋"
        case " ": str += "Space"
        default:
            if key.unicodeScalars.count == 1,
               let scalar = key.unicodeScalars.first,
               (0xF704...0xF713).contains(scalar.value) {
                str += "F\(scalar.value - 0xF704 + 1)"
            } else {
                str += key.uppercased()
            }
        }
        return str
    }
}

/// A serialized custom keyboard shortcut override.
public struct CustomShortcut: Codable, Equatable, Sendable {
    public var key: String
    public var modifierFlagsRaw: UInt
    /// Explicitly unbound: the action has no shortcut (distinct from "no
    /// override", which falls back to the factory default).
    public var isCleared: Bool
    /// A chord's second stroke, pressed on its own after the first: "⌘K,
    /// then T". Nil for an ordinary shortcut.
    public var secondKey: String?

    private enum CodingKeys: String, CodingKey {
        case key, modifierFlagsRaw, isCleared, secondKey
    }

    public init(key: String, modifiers: NSEvent.ModifierFlags, isCleared: Bool = false, secondKey: String? = nil) {
        self.key = key
        self.modifierFlagsRaw = modifiers.intersection(.deviceIndependentFlagsMask).rawValue
        self.isCleared = isCleared
        self.secondKey = secondKey.flatMap { $0.isEmpty ? nil : $0.lowercased() }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.key = try container.decode(String.self, forKey: .key)
        self.modifierFlagsRaw = try container.decode(UInt.self, forKey: .modifierFlagsRaw)
        self.isCleared = try container.decodeIfPresent(Bool.self, forKey: .isCleared) ?? false
        self.secondKey = try container.decodeIfPresent(String.self, forKey: .secondKey)
    }

    public var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlagsRaw)
    }

    public var isChord: Bool { secondKey != nil }

    public var displayString: String {
        ShortcutFormatter.format(key: key, modifiers: modifiers, secondKey: secondKey)
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
