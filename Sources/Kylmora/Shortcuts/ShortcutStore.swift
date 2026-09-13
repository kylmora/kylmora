import Foundation

/// Persists user shortcut customizations to disk.
@MainActor
final class ShortcutStore {
    static let shared = ShortcutStore()

    private let fileURL: URL
    private(set) var customShortcuts: [String: CustomShortcut] = [:]
    var onChange: (() -> Void)?

    init(fileURL: URL = AppPaths.supportDirectory.appending(path: "shortcuts.json")) {
        self.fileURL = fileURL
        load()
    }

    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)),
              let data = try? Data(contentsOf: fileURL),
              let loaded = try? JSONDecoder().decode([String: CustomShortcut].self, from: data) else {
            return
        }
        self.customShortcuts = loaded
    }

    func save() {
        AppPaths.ensureSupportDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(customShortcuts) else { return }
        try? data.write(to: fileURL, options: .atomic)
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
