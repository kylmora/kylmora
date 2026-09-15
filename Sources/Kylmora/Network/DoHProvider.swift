import Foundation

/// DNS over HTTPS (DoH) providers supported by Kylmora.
///
/// Encrypts all DNS resolution queries using TLS over HTTPS, bypassing
/// unencrypted system or ISP resolvers to prevent tracking, eavesdropping,
/// and DNS poisoning.
enum DoHProvider: Codable, Equatable, Hashable, Sendable {
    case off
    case cloudflare
    case quad9
    case google
    case adguard
    case custom(url: String)

    static let allPresets: [DoHProvider] = [
        .off,
        .cloudflare,
        .quad9,
        .google,
        .adguard,
        .custom(url: "")
    ]

    var title: String {
        switch self {
        case .off: return "Off (System Default)"
        case .cloudflare: return "Cloudflare (1.1.1.1 - Fast & Private)"
        case .quad9: return "Quad9 (Malware & Phishing Protection)"
        case .google: return "Google (8.8.8.8 - High Reliability)"
        case .adguard: return "AdGuard (Built-in Ad & Tracker Blocking)"
        case .custom: return "Custom DoH Endpoint…"
        }
    }

    var subtitle: String {
        switch self {
        case .off: return "Uses macOS system and local network DNS"
        case .cloudflare: return "https://cloudflare-dns.com/dns-query"
        case .quad9: return "https://dns.quad9.net/dns-query"
        case .google: return "https://dns.google/dns-query"
        case .adguard: return "https://dns.adguard-dns.com/dns-query"
        case .custom(let url): return url.isEmpty ? "Enter custom DoH URL" : url
        }
    }

    var endpointURLString: String? {
        switch self {
        case .off:
            return nil
        case .cloudflare:
            return "https://cloudflare-dns.com/dns-query"
        case .quad9:
            return "https://dns.quad9.net/dns-query"
        case .google:
            return "https://dns.google/dns-query"
        case .adguard:
            return "https://dns.adguard-dns.com/dns-query"
        case .custom(let url):
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    var key: String {
        switch self {
        case .off: return "off"
        case .cloudflare: return "cloudflare"
        case .quad9: return "quad9"
        case .google: return "google"
        case .adguard: return "adguard"
        case .custom: return "custom"
        }
    }

    static func from(key: String, customURL: String = "") -> DoHProvider {
        switch key {
        case "cloudflare": return .cloudflare
        case "quad9": return .quad9
        case "google": return .google
        case "adguard": return .adguard
        case "custom": return .custom(url: customURL)
        default: return .off
        }
    }
}
