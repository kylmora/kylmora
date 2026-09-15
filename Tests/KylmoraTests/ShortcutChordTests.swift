import AppKit
import Foundation
import Testing
@testable import Kylmora

@Suite("Chords, custom-command keys and the cheat sheet")
@MainActor
struct ShortcutChordTests {
    private func makeManager() -> (ShortcutManager, URL) {
        let file = FileManager.default.temporaryDirectory.appending(path: "shortcuts-\(UUID().uuidString).json")
        return (ShortcutManager(store: ShortcutStore(fileURL: file)), file)
    }

    @Test("A chord is stored, displayed as two strokes, and kept out of the menu")
    func chords() throws {
        let (manager, file) = makeManager()
        defer { try? FileManager.default.removeItem(at: file) }
        manager.setChord(id: "print-page", key: "k", modifiers: [.command], secondKey: "P")
        #expect(manager.displayString(for: "print-page") == "⌘K, P")
        #expect(manager.secondKey(for: "print-page") == "p")
        let reloaded = ShortcutManager(store: ShortcutStore(fileURL: file))
        #expect(reloaded.displayString(for: "print-page") == "⌘K, P")

        let menu = NSMenu()
        let item = NSMenuItem(title: "Print", action: #selector(BrowserWindowController.printPage(_:)), keyEquivalent: "p")
        item.keyEquivalentModifierMask = [.command]
        menu.addItem(item)
        manager.apply(to: menu)
        #expect(item.keyEquivalent == "", "the leader must not fire the menu item")

        let bindings = manager.dispatcherBindings
        #expect(bindings.count == 1)
        #expect(bindings.first?.secondKey == "p")
        #expect(bindings.first?.selector == #selector(BrowserWindowController.printPage(_:)))

        manager.setShortcut(id: "print-page", key: "p", modifiers: [.command])
        #expect(manager.secondKey(for: "print-page") == nil)
        #expect(manager.dispatcherBindings.isEmpty)
    }

    @Test("A custom command's key is a binding with no selector, and conflicts are found")
    func commandKeys() {
        let (manager, file) = makeManager()
        defer { try? FileManager.default.removeItem(at: file) }
        let id = AutomationService.commandPrefix + UUID().uuidString
        manager.setShortcut(id: id, key: "j", modifiers: [.command, .shift])
        #expect(manager.displayString(for: id) == "⇧⌘J")
        #expect(manager.dispatcherBindings.first?.id == id)
        #expect(manager.dispatcherBindings.first?.selector == nil)
        #expect(manager.conflictingCommand(key: "J", modifiers: [.command, .shift]) == id)
        #expect(manager.conflictingCommand(key: "j", modifiers: [.command, .shift], excluding: id) == nil)
        manager.resetShortcut(id: id)
        #expect(manager.displayString(for: id) == "")
    }

    @Test("The dispatcher arms on a leader, fires on the second stroke, and forgets after the window")
    func dispatcher() {
        let dispatcher = ShortcutDispatcher()
        let command = AutomationService.commandPrefix + UUID().uuidString
        dispatcher.bindings = { [
            ShortcutManager.Binding(id: "print-page", key: "k", modifiers: [.command], secondKey: "p", selector: nil),
            ShortcutManager.Binding(id: command, key: "j", modifiers: [.command, .shift], secondKey: nil, selector: nil)
        ] }
        var ran: [String] = []
        dispatcher.runCommand = { ran.append($0); return true }

        let start = Date()
        #expect(dispatcher.decide(key: "x", modifiers: [.command], now: start) == .pass)
        #expect(dispatcher.decide(key: "k", modifiers: [.command], now: start) == .armed)
        #expect(dispatcher.decide(key: "p", modifiers: [], now: start.addingTimeInterval(0.5)) == .perform(id: "print-page"))
        #expect(dispatcher.decide(key: "p", modifiers: [], now: start) == .pass, "the leader was used up")

        #expect(dispatcher.decide(key: "k", modifiers: [.command], now: start) == .armed)
        #expect(dispatcher.decide(key: "p", modifiers: [], now: start.addingTimeInterval(3)) == .pass, "too late")

        #expect(dispatcher.decide(key: "k", modifiers: [.command], now: start) == .armed)
        #expect(dispatcher.decide(key: "z", modifiers: [], now: start) == .pass, "a different key is not the chord")

        #expect(dispatcher.decide(key: "j", modifiers: [.command, .shift], now: start) == .perform(id: command))
        #expect(dispatcher.handle(key: "j", modifiers: [.command, .shift], now: start))
        #expect(ran == [command])
        #expect(!dispatcher.handle(key: "q", modifiers: [.command], now: start))
    }

    @Test("The cheat sheet lists every action under its category, and custom commands last")
    func cheatSheet() {
        let (manager, file) = makeManager()
        defer { try? FileManager.default.removeItem(at: file) }
        let rulesFile = FileManager.default.temporaryDirectory.appending(path: "automations-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: rulesFile) }
        let automations = AutomationService(store: AutomationStore(fileURL: rulesFile))
        automations.add(AutomationRule(name: "Tidy", trigger: .manual, actions: [.muteTab]))
        let sheet = ShortcutCheatSheetWindowController(manager: manager, automations: automations)
        let rows = sheet.rows()
        let headings = rows.compactMap(\.heading)
        #expect(headings.first == ShortcutCategory.allCases.first?.rawValue)
        #expect(headings.last == "Custom commands")
        #expect(rows.filter { $0.heading == nil }.count == manager.definitions.count + 1)
        #expect(rows.contains { $0.title == "Print Page" && $0.keys == "⌘P" })
        #expect(rows.contains { $0.title == "Tidy" && $0.keys == "palette only" })
        #expect(sheet.window?.title == "Keyboard Shortcuts")
    }

    @Test("Help ▸ Keyboard Shortcuts is on ⌘/ and the palette knows it")
    func menu() {
        let stub = MenuDelegateStub()
        let menu = MainMenu.build(bookmarks: stub, history: stub, tabs: stub, pinnedSites: stub, spaces: stub)
        let help = menu.items.last
        #expect(help?.title == "Help")
        let item = help?.submenu?.items.first { $0.title == "Keyboard Shortcuts" }
        #expect(item?.keyEquivalent == "/")
        #expect(CommandCatalog.all.contains { $0.id == "keyboard-shortcuts" })
        #expect(ShortcutManager.shared.definition(for: "keyboard-shortcuts") != nil)
    }
}

@Suite("Menu key equivalents are unique")
@MainActor
struct MenuKeyUniquenessTests {
    @Test("No two menu items claim the same key with the same modifiers")
    func unique() {
        let stub = NSObject()
        let delegate = MenuDelegateStub()
        _ = stub
        let menu = MainMenu.build(bookmarks: delegate, history: delegate, tabs: delegate, pinnedSites: delegate, spaces: delegate)
        var seen: [String: String] = [:]
        var clashes: [String] = []
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if !item.keyEquivalent.isEmpty {
                    let key = ShortcutFormatter.format(key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask)
                    if let other = seen[key], other != item.title {
                        clashes.append("\(key): \(other) and \(item.title)")
                    }
                    seen[key] = item.title
                }
                if let sub = item.submenu { walk(sub) }
            }
        }
        walk(menu)
        #expect(clashes.isEmpty, "\(clashes)")
    }
}
