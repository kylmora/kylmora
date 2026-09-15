import Foundation

/// One value kept as one readable JSON file, the way every store in
/// Application Support keeps its data: pretty-printed, keys sorted so
/// diffs are stable, written atomically so a crash mid-write leaves the old
/// file rather than half a new one. A missing or unreadable file reads as
/// nil, which every store treats as "nothing yet".
struct JSONFile<Value: Codable> {
    let url: URL

    init(_ url: URL) {
        self.url = url
    }

    /// A file in Application Support by name.
    init(named name: String) {
        self.init(AppPaths.supportDirectory.appending(path: name))
    }

    func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    func save(_ value: Value) throws {
        AppPaths.ensureSupportDirectory()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encode(value).write(to: url, options: [.atomic])
    }

    /// The bytes as the file would hold them, for export.
    static func encode(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }

    static func decode(_ data: Data) throws -> Value {
        try JSONDecoder().decode(Value.self, from: data)
    }
}
