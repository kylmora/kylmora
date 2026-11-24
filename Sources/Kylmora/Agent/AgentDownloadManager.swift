import Foundation
import WebKit

/// Manages browser downloads initiated during agent automation so agents can
/// await downloads, inspect suggested filenames, and save artifacts to absolute paths.
@MainActor
public final class AgentDownloadManager: NSObject, WKDownloadDelegate {
    public static let shared = AgentDownloadManager()

    public final class Record: @unchecked Sendable {
        public let id: String
        public let tabId: UUID
        public let url: String
        public var suggestedFilename: String
        public var tempPath: URL?
        public var state: String = "in_progress" // in_progress | completed | failed | cancelled
        public var errorMessage: String?
        weak var download: WKDownload?

        init(id: String, tabId: UUID, url: String, suggestedFilename: String, download: WKDownload) {
            self.id = id
            self.tabId = tabId
            self.url = url
            self.suggestedFilename = suggestedFilename
            self.download = download
        }

        public func toDictionary() -> [String: Any] {
            var d: [String: Any] = [
                "downloadId": id,
                "url": url,
                "suggestedFilename": suggestedFilename,
                "state": state,
            ]
            if let tempPath { d["tempPath"] = tempPath.path }
            if let errorMessage { d["error"] = errorMessage }
            return d
        }
    }

    private var recordsById: [String: Record] = [:]
    private var recordsByDownload: [ObjectIdentifier: Record] = [:]
    private var waitersByTab: [UUID: [(id: UUID, continuation: CheckedContinuation<Record, Error>)]] = [:]
    private var recentByTab: [UUID: Record] = [:]

    private override init() { super.init() }

    public func shouldIntercept(tabId: UUID) -> Bool {
        if let waiters = waitersByTab[tabId], !waiters.isEmpty { return true }
        return AgentHandoffManager.shared.isAgentDriving
    }

    public func attach(_ download: WKDownload, tabId: UUID) {
        let id = "dl-" + UUID().uuidString.prefix(8).lowercased()
        let urlStr = download.originalRequest?.url?.absoluteString ?? ""
        let record = Record(id: id, tabId: tabId, url: urlStr, suggestedFilename: "download", download: download)
        recordsById[id] = record
        recordsByDownload[ObjectIdentifier(download)] = record
        recentByTab[tabId] = record
        download.delegate = self
    }

    public func waitForDownload(tabId: UUID, timeout: TimeInterval = 30) async throws -> Record {
        if let recent = recentByTab.removeValue(forKey: tabId) {
            return recent
        }
        let waiterId = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var list = waitersByTab[tabId] ?? []
                list.append((id: waiterId, continuation: continuation))
                waitersByTab[tabId] = list
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(max(0.1, timeout) * 1_000_000_000))
                    self?.failWaiter(tabId: tabId, waiterId: waiterId, error: AgentError.invalidTarget("Timed out after \(Int(timeout))s waiting for download"))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.failWaiter(tabId: tabId, waiterId: waiterId, error: CancellationError())
            }
        }
    }

    private func wakeWaiters(for tabId: UUID, record: Record) {
        guard let list = waitersByTab.removeValue(forKey: tabId), !list.isEmpty else { return }
        recentByTab.removeValue(forKey: tabId)
        for item in list {
            item.continuation.resume(returning: record)
        }
    }

    private func failWaiter(tabId: UUID, waiterId: UUID, error: Error) {
        guard var list = waitersByTab[tabId],
              let idx = list.firstIndex(where: { $0.id == waiterId }) else { return }
        let removed = list.remove(at: idx)
        if list.isEmpty { waitersByTab.removeValue(forKey: tabId) }
        else { waitersByTab[tabId] = list }
        removed.continuation.resume(throwing: error)
    }

    public func saveAs(downloadId: String, destinationPath: String) async throws -> [String: Any] {
        guard destinationPath.hasPrefix("/") else {
            throw AgentError.invalidTarget("Download saveAs path must be absolute: \(destinationPath)")
        }
        guard let record = recordsById[downloadId] else {
            throw AgentError.invalidTarget("Unknown downloadId: \(downloadId)")
        }
        let deadline = Date().addingTimeInterval(60)
        while record.state == "in_progress" && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard record.state == "completed", let src = record.tempPath else {
            throw AgentError.invalidTarget("Download not completed (state=\(record.state), error=\(record.errorMessage ?? "none"))")
        }
        let dst = URL(fileURLWithPath: destinationPath)
        let fm = FileManager.default
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        try fm.copyItem(at: src, to: dst)
        let attrs = try fm.attributesOfItem(atPath: dst.path)
        let bytes = (attrs[.size] as? NSNumber)?.intValue ?? 0
        return ["success": true, "path": dst.path, "bytes": bytes, "suggestedFilename": record.suggestedFilename]
    }

    public func cancel(downloadId: String) throws -> [String: Any] {
        guard let record = recordsById[downloadId] else {
            throw AgentError.invalidTarget("Unknown downloadId: \(downloadId)")
        }
        record.state = "cancelled"
        record.download?.cancel { _ in }
        return ["success": true, "downloadId": downloadId]
    }

    public func cleanupTempFiles() {
        let fm = FileManager.default
        for record in recordsById.values {
            if let temp = record.tempPath { try? fm.removeItem(at: temp) }
        }
        recordsById.removeAll()
        recordsByDownload.removeAll()
        recentByTab.removeAll()
    }

    // MARK: - WKDownloadDelegate

    public func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping @MainActor @Sendable (URL?) -> Void
    ) {
        guard let record = recordsByDownload[ObjectIdentifier(download)] else {
            completionHandler(nil)
            return
        }
        record.suggestedFilename = suggestedFilename
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kylmora-agent-downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(record.id)-\(suggestedFilename)")
        try? FileManager.default.removeItem(at: dest)
        record.tempPath = dest
        wakeWaiters(for: record.tabId, record: record)
        completionHandler(dest)
    }

    public func downloadDidFinish(_ download: WKDownload) {
        guard let record = recordsByDownload[ObjectIdentifier(download)] else { return }
        record.state = "completed"
    }

    public func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        guard let record = recordsByDownload[ObjectIdentifier(download)] else { return }
        record.state = "failed"
        record.errorMessage = error.localizedDescription
    }
}
