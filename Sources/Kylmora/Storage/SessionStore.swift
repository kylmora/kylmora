import Foundation

/// Reads and writes the session snapshot as one JSON file.
///
/// Spaces and tabs are a small, wholly-rewritten document, so a file is the
/// right shape for them; SQLite earns its place for history, which is appended
/// to constantly and queried by prefix.
struct SessionStore {
    let fileURL: URL

    init(fileURL: URL = AppPaths.sessionFile) {
        self.fileURL = fileURL
    }

    func load() -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }

    /// Atomic, so a crash mid-write cannot leave a truncated session behind.
    func save(_ snapshot: SessionSnapshot) throws {
        AppPaths.ensureSupportDirectory()
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: fileURL, options: [.atomic])
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
