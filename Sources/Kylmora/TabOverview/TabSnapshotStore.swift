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

    /// Thumbnails are drawn a few hundred points wide, so that is the width
    /// they are captured at: WebKit renders the page scaled, and the image
    /// costs about a megabyte instead of the twenty-five a full Retina
    /// window would.
    static let captureWidth: CGFloat = 480

    /// How many tabs keep a thumbnail. Beyond this the least recently used
    /// goes; the overview captures a missing one on demand.
    let capacity: Int

    private var snapshots: [UUID: NSImage] = [:]
    /// Most recently used last.
    private var order: [UUID] = []

    init(capacity: Int = 30) {
        self.capacity = capacity
    }

    /// Retrieves any cached snapshot for the given tab ID.
    func snapshot(for tabID: UUID) -> NSImage? {
        guard let image = snapshots[tabID] else { return nil }
        touch(tabID)
        return image
    }

    /// Stores an explicit snapshot for the given tab ID (useful for testing and manual caching).
    func setSnapshot(_ image: NSImage, for tabID: UUID) {
        snapshots[tabID] = image
        touch(tabID)
        while order.count > capacity, let oldest = order.first {
            order.removeFirst()
            snapshots.removeValue(forKey: oldest)
        }
    }

    /// Removes the snapshot for a closed tab.
    func removeSnapshot(for tabID: UUID) {
        snapshots.removeValue(forKey: tabID)
        order.removeAll { $0 == tabID }
    }

    /// Clears all cached snapshots.
    func clear() {
        snapshots.removeAll()
        order.removeAll()
    }

    private func touch(_ tabID: UUID) {
        order.removeAll { $0 == tabID }
        order.append(tabID)
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
        return await capture(webView: webView, for: tab.id)
    }

    /// Captures `webView` at thumbnail width and files it under `id`.
    @discardableResult
    func capture(webView: WKWebView, for id: UUID) async -> NSImage? {
        guard webView.bounds.width > 0, webView.bounds.height > 0 else { return nil }
        do {
            let configuration = WKSnapshotConfiguration()
            configuration.snapshotWidth = NSNumber(value: Double(min(Self.captureWidth, webView.bounds.width)))
            let image = try await webView.takeSnapshot(configuration: configuration)
            setSnapshot(image, for: id)
            return image
        } catch {
            return nil
        }
    }
}
