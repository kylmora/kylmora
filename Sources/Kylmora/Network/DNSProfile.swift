import CryptoKit
import Foundation

/// A macOS configuration profile that puts an encrypted resolver in front of
/// every process on the Mac, WebKit's network process included.
///
/// This is the only honest way for a third-party browser to get DNS over
/// HTTPS on macOS. Page loads happen in WebKit's own network process, which
/// asks the system resolver; nothing an app sets on itself reaches it. The
/// system resolver, in turn, only takes an encrypted-DNS setting from a
/// configuration profile (`com.apple.dnsSettings.managed`), which the user
/// approves once in System Settings ▸ General ▸ Device Management, or which an
/// MDM pushes. So Kylmora writes that profile for the chosen resolver and
/// hands it to the system.
struct DNSProfile: Equatable {
    let provider: DoHProvider
    let serverURL: String
    /// Well-known addresses for the presets, so the resolver can be reached
    /// before any name has been resolved. A custom endpoint has none, and
    /// macOS then resolves its host name once with the ordinary resolver.
    let serverAddresses: [String]

    /// The profile for `provider`, or nil when the provider is off or has no
    /// usable endpoint.
    init?(provider: DoHProvider) {
        guard let url = provider.endpointURLString, URL(string: url)?.scheme == "https" else { return nil }
        self.provider = provider
        self.serverURL = url
        self.serverAddresses = Self.addresses(for: provider)
    }

    static func addresses(for provider: DoHProvider) -> [String] {
        switch provider {
        case .cloudflare: return ["1.1.1.1", "1.0.0.1", "2606:4700:4700::1111", "2606:4700:4700::1001"]
        case .quad9: return ["9.9.9.9", "149.112.112.112", "2620:fe::fe", "2620:fe::9"]
        case .google: return ["8.8.8.8", "8.8.4.4", "2001:4860:4860::8888", "2001:4860:4860::8844"]
        case .adguard: return ["94.140.14.14", "94.140.15.15", "2a10:50c0::ad1:ff", "2a10:50c0::ad2:ff"]
        case .off, .custom: return []
        }
    }

    /// A short name for the resolver: "Cloudflare", or the host of a custom one.
    var resolverName: String {
        switch provider {
        case .cloudflare: return "Cloudflare"
        case .quad9: return "Quad9"
        case .google: return "Google"
        case .adguard: return "AdGuard"
        case .custom: return URL(string: serverURL)?.host ?? "Custom"
        case .off: return "Off"
        }
    }

    var displayName: String { "Kylmora Encrypted DNS (\(resolverName))" }
    var fileName: String { "\(displayName).mobileconfig" }

    /// Identifiers are derived from the resolver, so installing a second
    /// copy of the same profile replaces the first instead of stacking.
    var identifier: String { "com.kylmora.Kylmora.dns.\(provider.key)" }

    /// The profile as a property list.
    var plist: [String: Any] {
        var dnsSettings: [String: Any] = [
            "DNSProtocol": "HTTPS",
            "ServerURL": serverURL
        ]
        if !serverAddresses.isEmpty { dnsSettings["ServerAddresses"] = serverAddresses }
        let payload: [String: Any] = [
            "PayloadType": "com.apple.dnsSettings.managed",
            "PayloadIdentifier": identifier + ".settings",
            "PayloadUUID": Self.stableUUID(for: identifier + ".settings"),
            "PayloadVersion": 1,
            "PayloadDisplayName": "Encrypted DNS: \(resolverName)",
            "DNSSettings": dnsSettings,
            // The user may switch it off in System Settings without removing
            // the profile; this is a choice, not a lock.
            "ProhibitDisablement": false
        ]
        return [
            "PayloadContent": [payload],
            "PayloadType": "Configuration",
            "PayloadIdentifier": identifier,
            "PayloadUUID": Self.stableUUID(for: identifier),
            "PayloadVersion": 1,
            "PayloadDisplayName": displayName,
            "PayloadDescription": "Sends every DNS query from this Mac to \(resolverName) over HTTPS (\(serverURL)), so the local network and the ISP cannot read or alter name lookups. Made by the Kylmora browser; remove it here to go back to the network's DNS.",
            "PayloadOrganization": "Kylmora",
            "PayloadScope": "System",
            "PayloadRemovalDisallowed": false
        ]
    }

    func data() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    /// Writes the profile into `directory` and returns the file.
    @discardableResult
    func write(to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: fileName)
        try data().write(to: file, options: .atomic)
        return file
    }

    /// A UUID that is always the same for the same name.
    static func stableUUID(for name: String) -> String {
        let digest = Array(SHA256.hash(data: Data(name.utf8)).prefix(16))
        var bytes = digest
        bytes[6] = (bytes[6] & 0x0F) | 0x40 // version 4 layout
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        let uuid = uuid_t(bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                          bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])
        return UUID(uuid: uuid).uuidString
    }
}
