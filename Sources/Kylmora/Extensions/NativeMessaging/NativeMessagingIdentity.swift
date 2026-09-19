import CryptoKit
import Foundation

/// Who an extension is, as a native messaging host recognises it.
///
/// A host's manifest names the extensions allowed to reach it, and it names
/// them the way Chrome or Firefox does -- `chrome-extension://<32 letters>/`
/// or `addon@vendor.example`. WebKit's engine has no idea about either: it
/// identifies an extension by whatever unique identifier the app hands it, a
/// UUID in Kylmora's case. So the match has to be made here, from what we know
/// about where the extension came from.
struct NativeMessagingExtensionIdentity: Equatable, Sendable {
    /// For Settings and for errors.
    let displayName: String
    /// Every `chrome-extension://.../` this extension can honestly claim.
    let origins: Set<String>
    /// Firefox-style identifiers from `browser_specific_settings`.
    let geckoIdentifiers: Set<String>

    init(displayName: String, origins: Set<String>, geckoIdentifiers: Set<String>) {
        self.displayName = displayName
        self.origins = Set(origins.map { $0.lowercased() })
        self.geckoIdentifiers = Set(geckoIdentifiers.map { $0.lowercased() })
    }
}

enum NativeMessagingIdentity {
    /// The 32-letter identifier Chrome derives from an extension's public key.
    ///
    /// SHA-256 of the DER-encoded key, the first sixteen bytes of it, each
    /// nibble written as a letter: 0 becomes `a`, 15 becomes `p`. Chrome has
    /// done this since 2009 and every store ID in every host manifest is the
    /// result, so computing it is the only way to recognise an extension the
    /// user installed from a file rather than from the store.
    static func chromeIdentifier(forPackedKey key: String) -> String? {
        guard let der = Data(base64Encoded: key, options: [.ignoreUnknownCharacters]), !der.isEmpty else { return nil }
        return chromeIdentifier(forKeyBytes: der)
    }

    static func chromeIdentifier(forKeyBytes der: Data) -> String {
        let digest = SHA256.hash(data: der)
        let letters = Array("abcdefghijklmnop")
        var identifier = ""
        for byte in digest.prefix(16) {
            identifier.append(letters[Int(byte >> 4)])
            identifier.append(letters[Int(byte & 0x0F)])
        }
        return identifier
    }

    /// What an installed extension may claim to be.
    ///
    /// Three sources, all of them things the extension cannot forge: the store
    /// ID Kylmora downloaded it under, the public key inside its own manifest,
    /// and the identifier the engine knows it by. The last one is there so a
    /// host written for Kylmora has something stable to list.
    static func identity(for record: InstalledExtension,
                         folder: URL,
                         engineIdentifier: String) -> NativeMessagingExtensionIdentity {
        var origins: Set<String> = ["chrome-extension://\(engineIdentifier.lowercased())/"]
        if let storeID = record.storeID?.lowercased(), !storeID.isEmpty {
            origins.insert("chrome-extension://\(storeID)/")
        }
        var geckoIDs: Set<String> = []
        if let manifest = manifest(in: folder) {
            if let key = manifest["key"] as? String, let derived = chromeIdentifier(forPackedKey: key) {
                origins.insert("chrome-extension://\(derived)/")
            }
            for identifier in geckoIdentifiers(in: manifest) {
                geckoIDs.insert(identifier)
            }
        }
        if let slug = record.firefoxSlug?.lowercased(), !slug.isEmpty, slug.contains("@") {
            geckoIDs.insert(slug)
        }
        return NativeMessagingExtensionIdentity(
            displayName: record.name,
            origins: origins,
            geckoIdentifiers: geckoIDs
        )
    }

    /// `browser_specific_settings.gecko.id`, and the older spelling of it.
    static func geckoIdentifiers(in manifest: [String: Any]) -> Set<String> {
        var found: Set<String> = []
        for key in ["browser_specific_settings", "applications"] {
            guard let settings = manifest[key] as? [String: Any],
                  let gecko = settings["gecko"] as? [String: Any],
                  let identifier = gecko["id"] as? String, !identifier.isEmpty
            else { continue }
            found.insert(identifier.lowercased())
        }
        return found
    }

    private static func manifest(in folder: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: folder.appending(path: "manifest.json")) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
