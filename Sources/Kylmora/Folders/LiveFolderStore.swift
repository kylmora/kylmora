import Foundation

/// The live folders' own file.
///
/// Deliberately not part of the session snapshot, for the reason D-FV9 keeps
/// favicons out of `browser.sqlite`: this is device-local poll bookkeeping that
/// is rewritten every half hour, and folding it into the session would make
/// every refresh dirty the file that holds the user's tabs. It is also the part
/// that must *not* follow a folder to another machine if syncing ever exists --
/// `lastFetched` and `lastIssue` are facts about this device.
actor LiveFolderStore {
    static let shared = LiveFolderStore()

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? AppPaths.supportDirectory.appending(path: "live-folders.json")
    }

    func load() -> [LiveFolderRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        // A file we cannot read is a file written by a future version or a
        // half-finished write. Starting empty re-fetches everything, which
        // costs one poll; refusing to launch costs the whole browser.
        return (try? JSONDecoder().decode([LiveFolderRecord].self, from: data)) ?? []
    }

    func save(_ records: [LiveFolderRecord]) {
        guard AppPaths.ensureSupportDirectory() else { return }
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
