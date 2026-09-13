import Foundation

/// Getting an extension's files from wherever the user has them into a
/// folder of Kylmora's own.
///
/// Three shapes arrive: an unpacked folder, a `.zip`, and a `.crx`, which is
/// what the Chrome Web Store hands out. A `.crx` is a zip with a signature
/// header in front; strip the header and it is the same package. The manifest
/// is looked for at the top of the archive and one level down, because zips
/// made by hand usually wrap everything in a folder.
enum ExtensionPackage {
    enum Failure: Error, Equatable {
        case unreadable
        case notAPackage
        case noManifest
        case unpackFailed(String)
    }

    /// Copies or unpacks `source` into a fresh folder under `root`, named by
    /// `id`, and returns the folder that holds `manifest.json`.
    static func install(from source: URL, id: UUID, under root: URL) throws -> URL {
        let manager = FileManager.default
        let staging = root.appending(path: "\(id.uuidString).staging", directoryHint: .isDirectory)
        let destination = root.appending(path: id.uuidString, directoryHint: .isDirectory)
        try? manager.removeItem(at: staging)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }

        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: source.path(percentEncoded: false), isDirectory: &isDirectory) else {
            throw Failure.unreadable
        }
        if isDirectory.boolValue {
            try manager.copyItem(at: source, to: staging.appending(path: "package", directoryHint: .isDirectory))
        } else {
            let zip: URL
            switch source.pathExtension.lowercased() {
            case "zip", "xpi":
                // Firefox's `.xpi` is a zip by another name.
                zip = source
            case "crx":
                let data = try Data(contentsOf: source)
                guard let stripped = zipData(fromCRX: data) else { throw Failure.notAPackage }
                zip = staging.appending(path: "package.zip")
                try stripped.write(to: zip)
            default:
                throw Failure.notAPackage
            }
            try unzip(zip, into: staging.appending(path: "package", directoryHint: .isDirectory))
        }

        guard let manifestFolder = folderWithManifest(in: staging.appending(path: "package")) else {
            throw Failure.noManifest
        }
        try? manager.removeItem(at: destination)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try manager.moveItem(at: manifestFolder, to: destination)
        return destination
    }

    /// The zip inside a `.crx`. Version 3 puts a length-prefixed protobuf
    /// header after the magic; version 2 puts a public key and a signature.
    static func zipData(fromCRX data: Data) -> Data? {
        guard data.count > 16, data.prefix(4) == Data("Cr24".utf8) else { return nil }
        func uint32(at offset: Int) -> Int {
            Int(data[offset]) | Int(data[offset + 1]) << 8 | Int(data[offset + 2]) << 16 | Int(data[offset + 3]) << 24
        }
        let version = uint32(at: 4)
        let start: Int
        switch version {
        case 3:
            start = 12 + uint32(at: 8)
        case 2:
            start = 16 + uint32(at: 8) + uint32(at: 12)
        default:
            return nil
        }
        guard start < data.count, data[start] == 0x50, data[start + 1] == 0x4B else { return nil }
        return data.subdata(in: start..<data.count)
    }

    /// The shallowest folder holding a `manifest.json`, searching a few
    /// levels down: zips made by hand wrap everything in a folder, and a zip
    /// of that wrapper wraps it again.
    static func folderWithManifest(in root: URL) -> URL? {
        let manager = FileManager.default
        var level = [root]
        for _ in 0...3 {
            for folder in level where manager.fileExists(atPath: folder.appending(path: "manifest.json").path(percentEncoded: false)) {
                return folder
            }
            level = level.flatMap { folder -> [URL] in
                let children = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
                return children
                    .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                    .filter { !$0.lastPathComponent.hasPrefix("__MACOSX") }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
            }
            if level.isEmpty { break }
        }
        return nil
    }

    /// `ditto`, which ships with macOS and reads every zip Finder does. A
    /// child process runs inside the same sandbox as Kylmora.
    private static func unzip(_ zip: URL, into destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path(percentEncoded: false), destination.path(percentEncoded: false)]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw Failure.unpackFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw Failure.unpackFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// What the manifest says about itself, for the list before WebKit has
    /// loaded the package. Localised names (`__MSG_name__`) are left to WebKit.
    static func manifestSummary(in folder: URL) -> (name: String, version: String)? {
        guard let data = try? Data(contentsOf: folder.appending(path: "manifest.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let name = json["name"] as? String ?? "Extension"
        let version = json["version"] as? String ?? ""
        return (name.hasPrefix("__MSG_") ? "Extension" : name, version)
    }
}

/// One installed extension, as the index on disk records it.
struct InstalledExtension: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var version: String
    var isEnabled: Bool
    let installedAt: Date
    /// The Chrome Web Store ID it came from, if it did. Absent for packages
    /// the user supplied themselves.
    var storeID: String?
    /// The addons.mozilla.org slug it came from, if it did.
    var firefoxSlug: String?

    init(id: UUID, name: String, version: String, isEnabled: Bool, installedAt: Date,
         storeID: String? = nil, firefoxSlug: String? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.isEnabled = isEnabled
        self.installedAt = installedAt
        self.storeID = storeID
        self.firefoxSlug = firefoxSlug
    }
}

/// The index of installed extensions, next to their folders.
struct ExtensionIndex: Sendable {
    let root: URL

    init(root: URL = AppPaths.supportDirectory.appending(path: "extensions", directoryHint: .isDirectory)) {
        self.root = root
    }

    private var file: URL { root.appending(path: "index.json") }

    func folder(for record: InstalledExtension) -> URL {
        root.appending(path: record.id.uuidString, directoryHint: .isDirectory)
    }

    func load() -> [InstalledExtension] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([InstalledExtension].self, from: data)) ?? []
    }

    func save(_ extensions: [InstalledExtension]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(extensions).write(to: file, options: .atomic)
    }
}
