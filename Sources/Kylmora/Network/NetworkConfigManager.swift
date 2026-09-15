import AppKit
import Foundation
import Network
import WebKit

/// Applies the HTTP / SOCKSv5 proxy settings to WebKit's data stores.
///
/// DNS over HTTPS is deliberately not here. WebKit resolves names in its own
/// network process, which nothing in this process can reach; the resolver is
/// set for the whole Mac through a configuration profile instead. See
/// `DNSProfile`.
@MainActor
final class NetworkConfigManager {
    static let shared = NetworkConfigManager()

    var allStoresProvider: (() -> [(Space.Identity, WKWebsiteDataStore)])?
    var spaceProxyResolver: ((Space.Identity) -> ProxySettings?)?

    private init() {}

    /// Applies stored network preferences on browser startup.
    func start() {
        applyToAllStores()
    }

    /// Applies proxy configuration to a single WKWebsiteDataStore.
    func apply(to store: WKWebsiteDataStore, spaceIdentity: Space.Identity? = nil) {
        let proxySettings: ProxySettings
        if let identity = spaceIdentity, let spaceSpecific = spaceProxyResolver?(identity) {
            proxySettings = spaceSpecific
        } else {
            proxySettings = Settings.shared.proxySettings
        }

        guard proxySettings.enabled && proxySettings.hasValidHostAndPort else {
            store.__proxyConfigurations = nil
            return
        }

        let host = proxySettings.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let portStr = String(proxySettings.port)
        let endpoint = nw_endpoint_create_host(host, portStr)

        let proxyConfig: nw_proxy_config_t
        switch proxySettings.type {
        case .http, .https:
            proxyConfig = nw_proxy_config_create_http_connect(endpoint, nil)
        case .socks5:
            proxyConfig = nw_proxy_config_create_socksv5(endpoint)
        }

        if !proxySettings.username.isEmpty {
            nw_proxy_config_set_username_and_password(
                proxyConfig,
                proxySettings.username,
                proxySettings.password
            )
        }

        let bypassEntries = proxySettings.bypassList.components(separatedBy: ",")
        for entry in bypassEntries {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                nw_proxy_config_add_excluded_domain(proxyConfig, trimmed)
            }
        }

        store.__proxyConfigurations = [proxyConfig]
    }

    /// Re-evaluates and applies proxy configurations to all active website data stores.
    func applyToAllStores() {
        guard let stores = allStoresProvider?() else { return }
        for (identity, store) in stores {
            apply(to: store, spaceIdentity: identity)
        }
    }
}
