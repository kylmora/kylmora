import Foundation

/// Persists user shortcut customizations to disk.
@MainActor
final class ShortcutStore {
    static let shared = ShortcutStore()

    private let file: JSONFile<[String: CustomShortcut]>
    private(set) var customShortcuts: [String: CustomShortcut] = [:]
    var onChange: (() -> Void)?

    init(fileURL: URL = AppPaths.supportDirectory.appending(path: "shortcuts.json")) {
        file = JSONFile(fileURL)
        load()
    }

    func load() {
        if let loaded = file.load() { customShortcuts = loaded }
    }

    func save() {
        try? file.save(customShortcuts)
        onChange?()
    }

    func set(_ shortcut: CustomShortcut, for id: String) {
        customShortcuts[id] = shortcut
        save()
    }

    func remove(id: String) {
        customShortcuts.removeValue(forKey: id)
        save()
    }

    func removeAll() {
        customShortcuts.removeAll()
        save()
    }

    func shortcut(for id: String) -> CustomShortcut? {
        customShortcuts[id]
    }
}
