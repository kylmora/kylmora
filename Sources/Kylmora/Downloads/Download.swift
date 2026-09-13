import Foundation
import WebKit

/// Where one download has got to.
///
/// A top-level type rather than a member of `Download` so it stays free of the
/// main actor: it is half of the persisted record, which is written off the
/// main thread.
enum DownloadState: Equatable, Sendable {
    case running
    case finished
    /// The message is shown in the list, so it is the user-facing reason.
    case failed(String)
    case cancelled
}

/// One file the browser is fetching, or has fetched.
///
/// A `Download` outlives the `WKDownload` behind it: once the transfer ends
/// WebKit's object is finished with, but the row stays in the list so the user
/// can still reveal or open the file. That is why `webKitDownload` is optional
/// rather than a stored requirement — a restored entry from a previous launch
/// has never had one.
@MainActor
final class Download: Identifiable {
    let id: UUID

    /// Where the bytes come from. Kept so a failed download can be retried even
    /// when WebKit has no resume data to offer.
    let sourceURL: URL

    /// Where the bytes are being written. Fixed once WebKit accepts it, which
    /// is also the only path this download is ever allowed to touch.
    private(set) var destination: URL

    private(set) var state: DownloadState
    private(set) var startedAt: Date
    private(set) var finishedAt: Date?

    /// Bytes on disk when the download finished. `progress` is gone by then, so
    /// the size has to be captured rather than read back on demand.
    private(set) var finalByteCount: Int64?

    /// WebKit's own `Progress`. Handed straight to `NSProgressIndicator`, which
    /// knows how to observe it safely, and asked for its localized description
    /// rather than formatting byte counts by hand.
    private(set) var progress: Progress?

    /// What `cancel` or a failure gave back, when WebKit had anything to give.
    /// Absent for most failures: resuming needs a server that honours range
    /// requests and an ETag that still matches.
    private(set) var resumeData: Data?

    private(set) var webKitDownload: WKDownload?

    /// The web view the transfer started from. `resumeDownload(fromResumeData:)`
    /// is a method on `WKWebView`, not on `WKDownload`, so resuming is only
    /// possible while some web view is still alive to host it. Weak, because a
    /// download must never keep a closed tab's content process resident.
    private(set) weak var host: WKWebView?

    /// True while the current transfer is continuing a partial file rather than
    /// starting a new one. WebKit asks for a destination again on resume, and
    /// the answer has to be the partial file — the opposite of the answer for a
    /// fresh transfer, which must name a file that does not exist yet.
    private(set) var isResuming = false

    var filename: String { destination.lastPathComponent }

    /// True only when everything resuming needs is actually present. The list
    /// offers a Resume button from this, so a stale yes would be a dead button.
    var canResume: Bool {
        guard case .failed = state else { return false }
        return resumeData != nil && host != nil
    }

    /// A finished file can be moved or deleted from Finder behind our back, so
    /// Reveal and Open are offered from the file system, not from the state.
    var fileExists: Bool {
        state == .finished && FileManager.default.fileExists(atPath: destination.path(percentEncoded: false))
    }

    init(id: UUID = UUID(), sourceURL: URL, destination: URL, download: WKDownload, host: WKWebView?) {
        self.id = id
        self.sourceURL = sourceURL
        self.destination = destination
        self.state = .running
        self.startedAt = .now
        self.progress = download.progress
        self.webKitDownload = download
        self.host = host
    }

    /// Rebuilds a row from the persisted list. Nothing is in flight, so there
    /// is no `WKDownload` and no progress to show.
    init(record: DownloadRecord) {
        id = record.id
        sourceURL = record.sourceURL
        destination = record.destination
        state = record.state
        startedAt = record.startedAt
        finishedAt = record.finishedAt
        finalByteCount = record.byteCount
    }

    // MARK: - Transitions

    func finish(byteCount: Int64?) {
        state = .finished
        finishedAt = .now
        finalByteCount = byteCount ?? progress?.completedUnitCount
        release()
    }

    func fail(_ message: String, resumeData: Data?) {
        state = .failed(message)
        finishedAt = .now
        self.resumeData = resumeData
        release()
    }

    func markCancelled(resumeData: Data?) {
        state = .cancelled
        finishedAt = .now
        self.resumeData = resumeData
        release()
    }

    /// Re-binds the row to a fresh `WKDownload` when the user resumes it, so
    /// the list shows one continuing download rather than growing a duplicate.
    func restart(with download: WKDownload, host: WKWebView?, resuming: Bool) {
        isResuming = resuming
        state = .running
        startedAt = .now
        finishedAt = nil
        resumeData = nil
        progress = download.progress
        webKitDownload = download
        self.host = host
    }

    /// WebKit's destination decision is authoritative: it may have declined the
    /// name we proposed. The list must show where the file actually went.
    func relocate(to url: URL) {
        destination = url
    }

    /// Drops everything that belongs to a transfer in flight. A finished row is
    /// a few hundred bytes; holding WebKit's objects for it would keep a
    /// download's network state alive for as long as the window is open.
    private func release() {
        isResuming = false
        progress = nil
        webKitDownload = nil
    }

    func record() -> DownloadRecord {
        DownloadRecord(
            id: id,
            sourceURL: sourceURL,
            destination: destination,
            state: state,
            startedAt: startedAt,
            finishedAt: finishedAt,
            byteCount: finalByteCount
        )
    }
}

/// The persisted form of one row.
///
/// Deliberately not the live object: resume data, `Progress` and `WKDownload`
/// have no meaning across a launch, and writing resume data to disk would
/// promise a resume that cannot be delivered — the web view it needs is gone.
struct DownloadRecord: Codable, Sendable, Equatable {
    let id: UUID
    let sourceURL: URL
    let destination: URL
    let state: DownloadState
    let startedAt: Date
    let finishedAt: Date?
    let byteCount: Int64?
}

/// Hand-written so the stored form is a stable string rather than whatever the
/// synthesised enum coding happens to produce, and so a transfer that was still
/// running at quit is restored as what it actually is: interrupted.
extension DownloadState: Codable {
    private enum Key: String, CodingKey {
        case name
        case message
    }

    private static let interrupted = "Interrupted when Kylmora quit"

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        switch try container.decode(String.self, forKey: .name) {
        case "finished": self = .finished
        case "cancelled": self = .cancelled
        case "failed": self = .failed(try container.decodeIfPresent(String.self, forKey: .message) ?? "Failed")
        default: self = .failed(Self.interrupted)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        switch self {
        case .running:
            try container.encode("failed", forKey: .name)
            try container.encode(Self.interrupted, forKey: .message)
        case .finished:
            try container.encode("finished", forKey: .name)
        case .cancelled:
            try container.encode("cancelled", forKey: .name)
        case .failed(let message):
            try container.encode("failed", forKey: .name)
            try container.encode(message, forKey: .message)
        }
    }
}
