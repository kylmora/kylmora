import Testing
import Foundation
import AppKit
import WebKit
@testable import Kylmora

@Suite("DNS over HTTPS and Proxy Configuration (F-29)")
@MainActor
struct NetworkConfigTests {

    @Test("DoHProvider presets and URL endpoint definitions")
    func dohProviderPresets() {
        #expect(DoHProvider.off.endpointURLString == nil)
        #expect(DoHProvider.cloudflare.endpointURLString == "https://cloudflare-dns.com/dns-query")
        #expect(DoHProvider.quad9.endpointURLString == "https://dns.quad9.net/dns-query")
        #expect(DoHProvider.google.endpointURLString == "https://dns.google/dns-query")
        #expect(DoHProvider.adguard.endpointURLString == "https://dns.adguard-dns.com/dns-query")

        let custom = DoHProvider.custom(url: "https://example.com/dns")
        #expect(custom.endpointURLString == "https://example.com/dns")

        let emptyCustom = DoHProvider.custom(url: "   ")
        #expect(emptyCustom.endpointURLString == nil)
    }

    @Test("DoHProvider serialization key and from(key:customURL:) resolution")
    func dohProviderSerialization() {
        #expect(DoHProvider.from(key: "off") == .off)
        #expect(DoHProvider.from(key: "cloudflare") == .cloudflare)
        #expect(DoHProvider.from(key: "quad9") == .quad9)
        #expect(DoHProvider.from(key: "google") == .google)
        #expect(DoHProvider.from(key: "adguard") == .adguard)
        #expect(DoHProvider.from(key: "custom", customURL: "https://dns.test") == .custom(url: "https://dns.test"))
        #expect(DoHProvider.from(key: "unknown") == .off)
    }

    @Test("ProxySettings host/port validation and summary representation")
    func proxySettingsValidation() {
        var proxy = ProxySettings()
        #expect(proxy.enabled == false)
        #expect(proxy.summary == "Disabled")

        proxy.enabled = true
        proxy.host = ""
        proxy.port = 8080
        #expect(proxy.hasValidHostAndPort == false)
        #expect(proxy.summary == "Incomplete configuration")

        proxy.host = "127.0.0.1"
        proxy.port = 8080
        proxy.type = .http
        #expect(proxy.hasValidHostAndPort == true)
        #expect(proxy.summary.contains("127.0.0.1:8080"))

        proxy.port = 70000 // Out of range
        #expect(proxy.hasValidHostAndPort == false)
    }

    @Test("ProxySettings JSON Codable roundtrip")
    func proxySettingsCodable() throws {
        let original = ProxySettings(
            enabled: true,
            type: .socks5,
            host: "proxy.company.internal",
            port: 1080,
            requiresAuthentication: true,
            username: "dev_user",
            password: "secret_password",
            bypassList: "localhost, 127.0.0.1, internal.corp"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProxySettings.self, from: data)

        #expect(decoded == original)
        #expect(decoded.type == .socks5)
        #expect(decoded.host == "proxy.company.internal")
        #expect(decoded.port == 1080)
        #expect(decoded.username == "dev_user")
    }

    @Test("Space effectiveProxy falls back to global settings when space has no proxy")
    func spaceEffectiveProxyFallback() {
        let space = Space(name: "Work", identity: .makeIsolated())
        #expect(space.customProxy == nil)

        // When global proxy is off, effectiveProxy is nil
        Settings.shared.proxySettings = ProxySettings(enabled: false)
        #expect(space.effectiveProxy == nil)

        // When global proxy is on, effectiveProxy yields global
        let globalProxy = ProxySettings(enabled: true, type: .http, host: "127.0.0.1", port: 8888)
        Settings.shared.proxySettings = globalProxy
        #expect(space.effectiveProxy?.host == "127.0.0.1")
        #expect(space.effectiveProxy?.port == 8888)

        // When space has its own enabled proxy, it overrides global
        let spaceProxy = ProxySettings(enabled: true, type: .socks5, host: "space.proxy.local", port: 9050)
        space.customProxy = spaceProxy
        #expect(space.effectiveProxy?.host == "space.proxy.local")
        #expect(space.effectiveProxy?.type == .socks5)

        // When space proxy is disabled, it falls back to global
        space.customProxy = ProxySettings(enabled: false, host: "space.proxy.local", port: 9050)
        #expect(space.effectiveProxy?.host == "127.0.0.1")

        // Reset
        Settings.shared.proxySettings = ProxySettings()
    }

    @Test("NetworkConfigManager applies configuration without crashing")
    func networkConfigManagerApplication() {
        let manager = NetworkConfigManager.shared
        manager.applyDoH(provider: .cloudflare)
        manager.applyDoH(provider: .off)

        let store = WKWebsiteDataStore.nonPersistent()
        manager.apply(to: store)
        // Default proxy is disabled, so __proxyConfigurations should be nil
        #expect(store.__proxyConfigurations == nil)

        // With enabled valid proxy
        Settings.shared.proxySettings = ProxySettings(
            enabled: true,
            type: .http,
            host: "127.0.0.1",
            port: 8080,
            requiresAuthentication: true,
            username: "user",
            password: "pwd",
            bypassList: "localhost, internal.net"
        )
        manager.apply(to: store)
        #expect(store.__proxyConfigurations != nil)
        #expect(store.__proxyConfigurations?.isEmpty == false)

        // Reset
        Settings.shared.proxySettings = ProxySettings()
        manager.apply(to: store)
        #expect(store.__proxyConfigurations == nil)
    }
}
