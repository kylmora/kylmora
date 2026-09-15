import AppKit
import Foundation
import WebKit

extension Notification.Name {
    /// Broadcast when cache mode or capacity settings change.
    public static let cacheConfigurationDidChange = Notification.Name("com.kylmora.cacheConfigurationDidChange")
    /// Broadcast when caches are emptied or purged.
    public static let cachesDidPurge = Notification.Name("com.kylmora.cachesDidPurge")
}

/// The central controller for browser caching behavior, SSD write protection,
/// and volatile memory-only caching (F-39).
@MainActor
public final class RAMCacheManager {
    public static let shared = RAMCacheManager()

    /// Custom provider to obtain all active WKWebsiteDataStore instances.
    var storesProvider: (() -> [(Space.Identity, WKWebsiteDataStore)])?

    private let fileManager = FileManager.default
    private var maintenanceTimer: Timer?

    private init() {
        startMaintenanceTimer()
    }


    // MARK: - Status & Inspection

    public var isRAMOnly: Bool {
        Settings.shared.cacheMode == .ramOnly
    }

    public var isCacheDisabled: Bool {
        Settings.shared.cacheMode == .disabled
    }

    /// Returns the bundle caches URL (`~/Library/Caches/<bundleIdentifier>`).
    public var cacheDirectoryURL: URL {
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let bundleID = Bundle.main.bundleIdentifier ?? "com.kylmora.Kylmora"
        return base.appendingPathComponent(bundleID, isDirectory: true)
    }

    /// WebKit network cache subdirectory.
    public var webKitNetworkCacheURL: URL {
        cacheDirectoryURL.appendingPathComponent("WebKit", isDirectory: true)
    }

    // MARK: - Configuration Enforcement

    /// Configures `URLCache.shared` and triggers disk cache cleanup according to current settings.
    public func applyCacheConfiguration() {
        let mode = Settings.shared.cacheMode
        let ramCapacityMB = Settings.shared.ramCacheCapacityMB
        let ramBytes = ramCapacityMB * 1024 * 1024

        switch mode {
        case .standard:
            // 64 MB memory, 500 MB disk
            URLCache.shared = URLCache(
                memoryCapacity: 64 * 1024 * 1024,
                diskCapacity: 500 * 1024 * 1024,
                diskPath: nil
            )

        case .ramOnly:
            // Configured RAM capacity, strictly 0 bytes on disk
            URLCache.shared = URLCache(
                memoryCapacity: ramBytes,
                diskCapacity: 0,
                diskPath: nil
            )
            // Immediately purge any stale WebKit disk cache files
            purgeDiskCacheOnly()

        case .disabled:
            // 0 bytes memory, 0 bytes disk
            URLCache.shared = URLCache(
                memoryCapacity: 0,
                diskCapacity: 0,
                diskPath: nil
            )
            purgeAllCaches()
        }

        NotificationCenter.default.post(name: .cacheConfigurationDidChange, object: self)
    }

    // MARK: - Purge Operations

    /// Completely clears all in-memory and on-disk caches across WebKit and URLCache.
    public func purgeAllCaches(completion: (@Sendable () -> Void)? = nil) {
        URLCache.shared.removeAllCachedResponses()

        let types = Set([
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache
        ])

        let stores = storesProvider?().map(\.1) ?? [WKWebsiteDataStore.default()]

        Task { @MainActor in
            for store in stores {
                await store.removeData(ofTypes: types, modifiedSince: .distantPast)
            }
            self.clearDiskCacheDirectory()
            NotificationCenter.default.post(name: .cachesDidPurge, object: self)
            completion?()
        }
    }

    /// Clears only the disk cache while leaving volatile RAM cache untouched.
    public func purgeDiskCacheOnly(completion: (@Sendable () -> Void)? = nil) {
        URLCache.shared.diskCapacity = 0

        let types: Set<String> = [WKWebsiteDataTypeDiskCache]
        let stores = storesProvider?().map(\.1) ?? [WKWebsiteDataStore.default()]

        Task { @MainActor in
            for store in stores {
                await store.removeData(ofTypes: types, modifiedSince: .distantPast)
            }
            self.clearDiskCacheDirectory()
            NotificationCenter.default.post(name: .cachesDidPurge, object: self)
            completion?()
        }
    }

    /// Deletes the on-disk WebKit NetworkCache directory to ensure zero SSD footprint.
    public func clearDiskCacheDirectory() {
        let pathsToClean = [
            webKitNetworkCacheURL,
            cacheDirectoryURL.appendingPathComponent("fsCachedData", isDirectory: true),
            cacheDirectoryURL.appendingPathComponent("WebKit/NetworkCache", isDirectory: true),
            cacheDirectoryURL.appendingPathComponent("WebKit/WebsiteData/Default/NetworkCache", isDirectory: true)
        ]

        for path in pathsToClean {
            guard fileManager.fileExists(atPath: path.path) else { continue }
            do {
                let items = try fileManager.contentsOfDirectory(at: path, includingPropertiesForKeys: nil)
                for item in items {
                    try? fileManager.removeItem(at: item)
                }
            } catch {
                try? fileManager.removeItem(at: path)
            }
        }
    }

    // MARK: - Metrics & Diagnostics

    /// Current RAM cache usage in bytes.
    public func currentMemoryUsageBytes() -> Int {
        URLCache.shared.currentMemoryUsage
    }

    /// Current disk cache usage in bytes (evaluates both URLCache and filesystem WebKit caches).
    public func currentDiskUsageBytes() -> Int {
        if isRAMOnly || isCacheDisabled {
            return 0
        }

        var total = URLCache.shared.currentDiskUsage
        if let size = directorySize(at: webKitNetworkCacheURL) {
            total += size
        }
        return total
    }

    public func formattedMemoryUsage() -> String {
        ByteCountFormatter.string(fromByteCount: Int64(currentMemoryUsageBytes()), countStyle: .memory)
    }

    public func formattedDiskUsage() -> String {
        if isRAMOnly {
            return "0 KB (SSD writes disabled)"
        }
        if isCacheDisabled {
            return "Disabled"
        }
        return ByteCountFormatter.string(fromByteCount: Int64(currentDiskUsageBytes()), countStyle: .file)
    }

    public func formattedSummary() -> String {
        if isCacheDisabled {
            return "Cache disabled (Always network fetch)"
        }
        if isRAMOnly {
            return "RAM: \(formattedMemoryUsage()) · Disk: 0 KB (Protected)"
        }
        return "RAM: \(formattedMemoryUsage()) · Disk: \(formattedDiskUsage())"
    }

    private func directorySize(at url: URL) -> Int? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var total: Int = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                  values.isDirectory == false,
                  let size = values.fileSize else { continue }
            total += size
        }
        return total
    }

    // MARK: - Periodic Maintenance

    private func startMaintenanceTimer() {
        // Runs every 5 minutes in background: if in RAM-only mode, sweeps any accidental disk cache files
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRAMOnly else { return }
                self.clearDiskCacheDirectory()
            }
        }
    }
}
