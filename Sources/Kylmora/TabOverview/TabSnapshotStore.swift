import AppKit
import WebKit

/// In-memory cache and capture manager for tab preview snapshots.
///
/// Used by the Safari-style Tab Overview grid to render visual thumbnail cards
/// of open tabs. Snapshots are captured asynchronously when tabs finish loading,
/// when tabs are deactivated, or on demand when Tab Overview opens.
@MainActor
final class TabSnapshotStore {
    static let shared = TabSnapshotStore()

    private var snapshots: [UUID: NSImage] = [:]

    init() {}

    /// Retrieves any cached snapshot for the given tab ID.
    func snapshot(for tabID: UUID) -> NSImage? {
        snapshots[tabID]
    }

    /// Stores an explicit snapshot for the given tab ID (useful for testing and manual caching).
    func setSnapshot(_ image: NSImage, for tabID: UUID) {
        snapshots[tabID] = image
    }

    /// Removes the snapshot for a closed tab.
    func removeSnapshot(for tabID: UUID) {
        snapshots.removeValue(forKey: tabID)
    }

    /// Clears all cached snapshots.
    func clear() {
        snapshots.removeAll()
    }

    /// Number of cached snapshots.
    var count: Int {
        snapshots.count
    }

    /// Captures a snapshot of the tab's web view if available and visible.
    ///
    /// If snapshot capture succeeds, the image is automatically cached and returned.
    /// If the tab has no loaded web view or is off-screen / 0-sized, returns nil.
    @discardableResult
    func capture(tab: Tab) async -> NSImage? {
        guard let webView = tab.currentWebView else { return nil }
        guard webView.bounds.width > 0, webView.bounds.height > 0 else { return nil }

        do {
            let image = try await webView.takeSnapshot(configuration: nil)
            snapshots[tab.id] = image
            return image
        } catch {
            return nil
        }
    }
}
