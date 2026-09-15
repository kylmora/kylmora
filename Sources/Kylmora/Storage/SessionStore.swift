import Foundation

/// Reads and writes the session snapshot as one JSON file.
///
/// Spaces and tabs are a small, wholly-rewritten document, so a file is the
/// right shape for them; SQLite earns its place for history, which is appended
/// to constantly and queried by prefix.
final class SessionStore {
    let fileURL: URL

    init(fileURL: URL = AppPaths.sessionFile) {
        self.fileURL = fileURL
    }

    func load() -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }

    /// Atomic, so a crash mid-write cannot leave a truncated session behind.
    /// The bytes last written, so an unchanged session is not written again.
    /// Saves are debounced already; this catches the ones the debounce lets
    /// through with nothing new in them.
    private var lastWritten: Data?

    func save(_ snapshot: SessionSnapshot) throws {
        // Sorted keys, so the same session always encodes to the same bytes
        // and the comparison below means something.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        guard data != lastWritten else { return }
        try data.write(to: fileURL, options: [.atomic])
        lastWritten = data
    }

    private func saveUncached(_ snapshot: SessionSnapshot) throws {
        AppPaths.ensureSupportDirectory()
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: fileURL, options: [.atomic])
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
