import Foundation

/// Defines how Kylmora manages HTTP and resource caching.
public enum CacheMode: String, CaseIterable, Codable, Sendable {
    /// Standard WebKit caching with disk persistence and volatile memory cache.
    case standard = "standard"
    /// RAM-Only caching. Zero bytes written to SSD. All cached resources are held
    /// strictly in volatile system memory and discarded on tab close or app exit.
    case ramOnly = "ramOnly"
    /// No caching. Always reload fresh content directly from the network.
    case disabled = "disabled"

    public var title: String {
        switch self {
        case .standard:
            return "Standard (Disk & RAM)"
        case .ramOnly:
            return "RAM-Only (Zero SSD writes)"
        case .disabled:
            return "Disabled (Always fetch fresh)"
        }
    }

    public var summary: String {
        switch self {
        case .standard:
            return "Caches pages and images to disk and RAM for fastest reloads across sessions."
        case .ramOnly:
            return "Keeps all cache in volatile system RAM only. Prevents SSD wear and leaves zero forensic disk traces."
        case .disabled:
            return "Bypasses all caches and always retrieves web resources directly from the network."
        }
    }
}

/// Permitted memory capacity thresholds for RAM-only caching.
public enum RAMCacheCapacity: Int, CaseIterable, Codable, Sendable {
    case mb64 = 64
    case mb128 = 128
    case mb256 = 256
    case mb512 = 512
    case mb1024 = 1024

    public var title: String {
        switch self {
        case .mb64: return "64 MB"
        case .mb128: return "128 MB (Recommended)"
        case .mb256: return "256 MB"
        case .mb512: return "512 MB"
        case .mb1024: return "1 GB (High memory)"
        }
    }

    public var bytes: Int {
        rawValue * 1024 * 1024
    }
}
