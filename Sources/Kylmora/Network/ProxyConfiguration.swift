import Foundation

/// Supported proxy protocol types.
enum ProxyType: String, Codable, CaseIterable, Sendable {
    case http = "HTTP CONNECT"
    case https = "HTTPS"
    case socks5 = "SOCKSv5"

    var title: String { rawValue }
}

/// Settings defining a network proxy for the browser or a specific space.
struct ProxySettings: Codable, Equatable, Sendable {
    var enabled: Bool = false
    var type: ProxyType = .http
    var host: String = ""
    var port: Int = 8080
    var requiresAuthentication: Bool = false
    var username: String = ""
    var password: String = ""
    var bypassList: String = "localhost, 127.0.0.1, *.local"

    var hasValidHostAndPort: Bool {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && port > 0 && port <= 65535
    }

    var summary: String {
        if !enabled {
            return "Disabled"
        }
        guard hasValidHostAndPort else {
            return "Incomplete configuration"
        }
        return "\(type.rawValue)://\(host):\(port)"
    }
}
