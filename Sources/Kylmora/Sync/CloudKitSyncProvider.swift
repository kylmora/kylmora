import CloudKit
import Foundation
import Security

/// Handles CloudKit Private Database synchronization for Kylmora.
///
/// Stores data directly into the user's private iCloud database with zero Kylmora servers.
/// Operates seamlessly in background tasks when iCloud entitlements are present.
actor CloudKitSyncProvider {
    static let recordType = "KylmoraDeviceSync"

    /// Checks if the process was signed with CloudKit entitlements.
    /// Calling CKContainer methods without entitlements triggers an uncatchable Objective-C CKException.
    static var isEntitled: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let containers = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil)
        let services = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil)
        return containers != nil || services != nil
    }

    private let container: CKContainer?
    private var database: CKDatabase? { container?.privateCloudDatabase }

    init?(container: CKContainer? = nil) {
        if let container {
            self.container = container
        } else if Self.isEntitled {
            self.container = CKContainer.default()
        } else {
            return nil
        }
    }

    /// Checks whether iCloud account is accessible and configured.
    func isAvailable() async -> Bool {
        guard let container else { return false }
        do {
            let status = try await container.accountStatus()
            return status == .available
        } catch {
            return false
        }
    }

    /// Uploads this device's sync archive to CloudKit.
    func save(archive: SyncArchive) async throws {
        guard let database else { return }
        let recordID = CKRecord.ID(recordName: "device-\(archive.deviceID.uuidString)")
        let record: CKRecord
        do {
            record = try await database.record(for: recordID)
        } catch {
            record = CKRecord(recordType: Self.recordType, recordID: recordID)
        }

        let encoder = JSONEncoder()
        let data = try encoder.encode(archive)
        record["payload"] = data
        record["deviceName"] = archive.deviceName
        record["updatedAt"] = archive.exportedAt

        _ = try await database.save(record)
    }

    /// Downloads sync archives from all other devices in CloudKit.
    func fetchRemoteArchives(excludingDeviceID localID: UUID) async throws -> [SyncArchive] {
        guard let database else { return [] }
        let predicate = NSPredicate(format: "recordID != %@", CKRecord.ID(recordName: "device-\(localID.uuidString)"))
        let query = CKQuery(recordType: Self.recordType, predicate: predicate)
        let (matchResults, _) = try await database.records(matching: query)

        var archives: [SyncArchive] = []
        let decoder = JSONDecoder()

        for (_, result) in matchResults {
            guard case .success(let record) = result,
                  let data = record["payload"] as? Data,
                  let archive = try? decoder.decode(SyncArchive.self, from: data),
                  archive.deviceID != localID else {
                continue
            }
            archives.append(archive)
        }

        return archives.sorted { $0.exportedAt > $1.exportedAt }
    }
}
