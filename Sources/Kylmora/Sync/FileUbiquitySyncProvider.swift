import Foundation

/// Handles file-based cross-device sync using iCloud Drive or a local ubiquitous directory.
///
/// Each device maintains its own JSON sync file in a shared `devices/` directory.
/// This prevents write-write clobbering: Mac A never overwrites Mac B's file directly;
/// instead, each device reads peer files and merges them via `SyncMergePolicy`.
actor FileUbiquitySyncProvider {
    struct Manifest: Codable, Equatable {
        struct DeviceEntry: Codable, Equatable {
            var id: UUID
            var name: String
            var lastUpdated: Date
        }
        var devices: [String: DeviceEntry] = [:]
    }

    private let syncDirectory: URL
    private var devicesDirectory: URL { syncDirectory.appending(path: "devices", directoryHint: .isDirectory) }
    private var manifestFile: URL { syncDirectory.appending(path: "manifest.json") }

    init(syncDirectory: URL) {
        self.syncDirectory = syncDirectory
    }

    /// Prepares the storage directory.
    func prepare() throws {
        try FileManager.default.createDirectory(at: devicesDirectory, withIntermediateDirectories: true)
    }

    /// Saves this device's sync archive atomically, optionally encrypted with a passphrase.
    func saveLocalArchive(_ archive: SyncArchive, passphrase: String? = nil) throws {
        try prepare()

        let deviceFile = devicesDirectory.appending(path: "device-\(archive.deviceID.uuidString).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(archive)
        if let passphrase, !passphrase.isEmpty {
            data = try SyncCrypto.encrypt(data, passphrase: passphrase)
        }
        try data.write(to: deviceFile, options: [.atomic])

        // Update manifest
        var manifest = loadManifest()
        manifest.devices[archive.deviceID.uuidString] = Manifest.DeviceEntry(
            id: archive.deviceID,
            name: archive.deviceName,
            lastUpdated: archive.exportedAt
        )
        if let manifestData = try? encoder.encode(manifest) {
            try? manifestData.write(to: manifestFile, options: [.atomic])
        }
    }

    /// Reads all peer device archives excluding this device's own ID, decrypting if needed.
    func fetchRemoteArchives(excludingDeviceID localID: UUID, passphrase: String? = nil) -> [SyncArchive] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: devicesDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return []
        }

        var archives: [SyncArchive] = []
        let decoder = JSONDecoder()

        for file in files where file.pathExtension == "json" {
            guard let rawData = try? Data(contentsOf: file),
                  let data = try? SyncCrypto.decrypt(rawData, passphrase: passphrase),
                  let archive = try? decoder.decode(SyncArchive.self, from: data),
                  archive.deviceID != localID else {
                continue
            }
            archives.append(archive)
        }

        // Return sorted by most recent first
        return archives.sorted { $0.exportedAt > $1.exportedAt }
    }

    /// Reads the current sync manifest.
    func loadManifest() -> Manifest {
        guard let data = try? Data(contentsOf: manifestFile),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            return Manifest()
        }
        return manifest
    }
}
