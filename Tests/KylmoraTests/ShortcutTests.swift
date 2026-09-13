import AppKit
import Foundation
import Testing
@testable import Kylmora

private func temporaryDirectory() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "kylmora-shortcut-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite("Configurable Keyboard Shortcuts")
@MainActor
struct ShortcutTests {

    @Test("ShortcutFormatter formats modifiers and keys accurately")
    func formatting() {
        #expect(ShortcutFormatter.format(key: "c", modifiers: [.command, .shift]) == "⇧⌘C")
        #expect(ShortcutFormatter.format(key: "t", modifiers: [.command]) == "⌘T")
        #expect(ShortcutFormatter.format(key: "n", modifiers: [.command, .option]) == "⌥⌘N")
        #expect(ShortcutFormatter.format(key: "s", modifiers: [.command, .control]) == "⌃⌘S")
        #expect(ShortcutFormatter.format(key: "\u{2192}", modifiers: [.command, .option]) == "⌥⌘→")
        #expect(ShortcutFormatter.format(key: "\u{2190}", modifiers: [.command, .option]) == "⌥⌘←")
        #expect(ShortcutFormatter.format(key: "\u{2193}", modifiers: [.command, .option]) == "⌥⌘↓")
        #expect(ShortcutFormatter.format(key: "\u{2191}", modifiers: [.command, .option]) == "⌥⌘↑")
    }

    @Test("CustomShortcut encodes and decodes JSON correctly")
    func shortcutCodable() throws {
        let shortcut = CustomShortcut(key: "k", modifiers: [.command, .shift])
        let data = try JSONEncoder().encode(shortcut)
        let decoded = try JSONDecoder().decode(CustomShortcut.self, from: data)

        #expect(decoded.key == "k")
        #expect(decoded.modifiers.contains(.command))
        #expect(decoded.modifiers.contains(.shift))
        #expect(decoded.displayString == "⇧⌘K")
    }

    @Test("ShortcutStore saves and loads customized shortcuts")
    func storeCRUD() {
        let tempDir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let file = tempDir.appending(path: "shortcuts.json")
        let store = ShortcutStore(fileURL: file)

        #expect(store.customShortcuts.isEmpty)

        let custom1 = CustomShortcut(key: "x", modifiers: [.command, .option])
        store.set(custom1, for: "copy-url")

        #expect(store.shortcut(for: "copy-url")?.key == "x")

        // Reload fresh from disk
        let reloaded = ShortcutStore(fileURL: file)
        #expect(reloaded.shortcut(for: "copy-url")?.key == "x")
        #expect(reloaded.shortcut(for: "copy-url")?.displayString == "⌥⌘X")

        store.remove(id: "copy-url")
        #expect(store.shortcut(for: "copy-url") == nil)
    }

    @Test("ShortcutManager provides default and customized shortcuts")
    func managerShortcuts() {
        let tempDir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = ShortcutStore(fileURL: tempDir.appending(path: "shortcuts.json"))
        let manager = ShortcutManager(store: store)

        // 1. Defaults verification
        #expect(manager.displayString(for: "copy-url") == "⇧⌘C")
        #expect(manager.displayString(for: "pin-tab") == "⇧⌘P")
        #expect(manager.displayString(for: "duplicate-tab") == "⇧⌘D")
        #expect(manager.displayString(for: "new-tab") == "⌘T")
        #expect(manager.displayString(for: "close-tab") == "⌘W")
        #expect(!manager.isCustomized(id: "copy-url"))

        // 2. Custom override
        manager.setShortcut(id: "copy-url", key: "u", modifiers: [.command, .shift])
        #expect(manager.isCustomized(id: "copy-url"))
        #expect(manager.displayString(for: "copy-url") == "⇧⌘U")

        // 3. Reset
        manager.resetShortcut(id: "copy-url")
        #expect(!manager.isCustomized(id: "copy-url"))
        #expect(manager.displayString(for: "copy-url") == "⇧⌘C")
    }

    @Test("Conflict detection identifies overlapping shortcuts")
    func conflictDetection() {
        let tempDir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = ShortcutStore(fileURL: tempDir.appending(path: "shortcuts.json"))
        let manager = ShortcutManager(store: store)

        // "t" with .command is "new-tab"
        let conflict = manager.findConflict(key: "t", modifiers: [.command], excluding: "close-tab")
        #expect(conflict?.id == "new-tab")

        // Same action is excluded
        let selfConflict = manager.findConflict(key: "t", modifiers: [.command], excluding: "new-tab")
        #expect(selfConflict == nil)

        // Unused combination
        let noConflict = manager.findConflict(key: "z", modifiers: [.command, .control, .option])
        #expect(noConflict == nil)
    }

    @Test("ShortcutManager updates NSMenu item key equivalents")
    func appliesToMenu() {
        let tempDir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = ShortcutStore(fileURL: tempDir.appending(path: "shortcuts.json"))
        let manager = ShortcutManager(store: store)

        let menu = NSMenu()
        let item = NSMenuItem(
            title: "New Tab",
            action: #selector(BrowserWindowController.newTab(_:)),
            keyEquivalent: "t"
        )
        item.keyEquivalentModifierMask = [.command]
        menu.addItem(item)

        // Customize New Tab to Cmd-Option-T
        manager.setShortcut(id: "new-tab", key: "t", modifiers: [.command, .option])
        manager.apply(to: menu)

        #expect(item.keyEquivalent == "t")
        #expect(item.keyEquivalentModifierMask.contains(.option))
        #expect(item.keyEquivalentModifierMask.contains(.command))

        // Reset
        manager.resetAll()
        manager.apply(to: menu)

        #expect(item.keyEquivalent == "t")
        #expect(!item.keyEquivalentModifierMask.contains(.option))
        #expect(item.keyEquivalentModifierMask.contains(.command))
    }

    @Test("Arrow-key defaults use function-key scalars AppKit can match")
    func arrowDefaultsAreFunctionKeys() {
        let tempDir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let manager = ShortcutManager(store: ShortcutStore(fileURL: tempDir.appending(path: "shortcuts.json")))

        // AppKit only fires arrow equivalents holding U+F700-U+F703; the
        // printable arrows (U+2190-U+2193) never match a real keypress.
        let expected: [String: String] = [
            "next-tab": "\u{F703}",
            "previous-tab": "\u{F702}",
            "next-space": "\u{F701}",
            "previous-space": "\u{F700}",
        ]
        for (id, key) in expected {
            let def = manager.definition(for: id)
            #expect(def?.defaultKey == key)
            #expect(def?.defaultKey.unicodeScalars.first.map { (0xF700...0xF703).contains($0.value) } ?? false)
        }
    }

    @Test("ShortcutFormatter displays function-key arrows and F-keys")
    func formatsFunctionKeys() {
        #expect(ShortcutFormatter.format(key: "\u{F703}", modifiers: [.command, .option]) == "⌥⌘→")
        #expect(ShortcutFormatter.format(key: "\u{F702}", modifiers: [.command, .option]) == "⌥⌘←")
        #expect(ShortcutFormatter.format(key: "\u{F701}", modifiers: [.command, .option]) == "⌥⌘↓")
        #expect(ShortcutFormatter.format(key: "\u{F700}", modifiers: [.command, .option]) == "⌥⌘↑")
    }

    @Test("Clearing a shortcut unbinds it instead of restoring the default")
    func clearUnbinds() {
        let tempDir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let manager = ShortcutManager(store: ShortcutStore(fileURL: tempDir.appending(path: "shortcuts.json")))

        manager.clearShortcut(id: "new-tab")
        #expect(manager.effectiveShortcut(for: "new-tab") == nil)
        #expect(manager.displayString(for: "new-tab") == "")
        #expect(manager.isCustomized(id: "new-tab"))

        // A cleared action no longer conflicts with anything.
        #expect(manager.findConflict(key: "t", modifiers: [.command], excluding: "new-tab") == nil)

        let menu = NSMenu()
        let item = NSMenuItem(title: "New Tab", action: #selector(BrowserWindowController.newTab(_:)), keyEquivalent: "t")
        menu.addItem(item)
        manager.apply(to: menu)
        #expect(item.keyEquivalent == "")

        // Reset restores the factory default.
        manager.resetShortcut(id: "new-tab")
        #expect(manager.effectiveShortcut(for: "new-tab")?.key == "t")
    }

    @Test("Reassigning a conflict frees the shortcut instead of duplicating it")
    func reassignFreesConflict() {
        let tempDir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let manager = ShortcutManager(store: ShortcutStore(fileURL: tempDir.appending(path: "shortcuts.json")))

        // Pin Tab steals New Tab's Cmd-T; the loser must end up unbound.
        #expect(manager.findConflict(key: "t", modifiers: [.command], excluding: "pin-tab")?.id == "new-tab")
        manager.clearShortcut(id: "new-tab")
        manager.setShortcut(id: "pin-tab", key: "t", modifiers: [.command])

        #expect(manager.effectiveShortcut(for: "new-tab") == nil)
        #expect(manager.effectiveShortcut(for: "pin-tab")?.key == "t")
        #expect(manager.findConflict(key: "t", modifiers: [.command], excluding: "pin-tab") == nil)
    }
}
