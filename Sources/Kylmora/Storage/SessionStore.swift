import CryptoKit
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
        do {
            return try JSONDecoder().decode(SessionSnapshot.self, from: data)
        } catch {
            // A session that will not decode is every Space, tab, scroll
            // position and half-typed form the user had open -- and `save`
            // writes over this file, so the next one of those destroys it.
            // Keep the bytes beside it so they survive that.
            //
            // One copy under a fixed name, not a timestamped one: a session
            // that stays broken across launches would otherwise fill the
            // support folder with copies of the same dead file.
            //
            // This matters most for the version that adds a field: the
            // snapshot is synthesised `Codable`, so a new property without a
            // default makes every file written by the previous version fail
            // here, and every user loses their tabs on upgrade.
            let backup = fileURL.deletingLastPathComponent()
                .appending(path: "session.undecodable.json")
            try? data.write(to: backup)
            return nil
        }
    }

    /// A digest of the bytes last written, so an unchanged session is not
    /// written again. Saves are debounced already; this catches the ones the
    /// debounce lets through with nothing new in them. A digest, not the
    /// bytes: a session file runs to megabytes.
    private var lastWrittenDigest: SHA256Digest?

    /// Atomic, so a crash mid-write cannot leave a truncated session behind.
    func save(_ snapshot: SessionSnapshot) throws {
        // Sorted keys, so the same session always encodes to the same bytes
        // and the comparison below means something.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        let digest = SHA256.hash(data: data)
        guard digest != lastWrittenDigest else { return }
        try data.write(to: fileURL, options: [.atomic])
        lastWrittenDigest = digest
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
