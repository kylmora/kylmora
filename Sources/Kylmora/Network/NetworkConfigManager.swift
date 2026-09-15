import AppKit
import Foundation
import Network
import WebKit

/// Coordinates system network configuration for Kylmora, including
/// DNS over HTTPS (DoH) resolution and HTTP / SOCKSv5 proxying.
@MainActor
final class NetworkConfigManager {
    static let shared = NetworkConfigManager()

    var allStoresProvider: (() -> [(Space.Identity, WKWebsiteDataStore)])?
    var spaceProxyResolver: ((Space.Identity) -> ProxySettings?)?

    private var activeDoHContext: nw_privacy_context_t?

    private init() {}

    /// Initializes and applies stored network preferences on browser startup.
    func start() {
        applyDoH(provider: Settings.shared.dohProvider)
        applyToAllStores()
    }

    /// Configures DNS over HTTPS (DoH) name resolution.
    func applyDoH(provider: DoHProvider) {
        guard let urlString = provider.endpointURLString,
              let _ = URL(string: urlString) else {
            activeDoHContext = nil
            return
        }

        let dohEndpoint = nw_endpoint_create_url(urlString)
        let resolver = nw_resolver_config_create_https(dohEndpoint)
        let context = nw_privacy_context_create("KylmoraDoH")
        nw_privacy_context_require_encrypted_name_resolution(context, true, resolver)
        activeDoHContext = context
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
