import Foundation
import CryptoKit

/// End-to-end AES-256-GCM encryption for cross-device sync archives.
///
/// Ensures zero-knowledge privacy when syncing via Google Drive, Dropbox,
/// Nextcloud, WebDAV, or untrusted network shares.
public enum SyncCrypto {
    public enum CryptoError: LocalizedError {
        case passphraseRequired
        case incorrectPassphrase
        case corruptedCiphertext

        public var errorDescription: String? {
            switch self {
            case .passphraseRequired:
                return "This sync archive is encrypted. Please enter the sync passphrase in Settings."
            case .incorrectPassphrase:
                return "Incorrect sync passphrase. Could not decrypt sync archive."
            case .corruptedCiphertext:
                return "The encrypted sync archive is corrupted."
            }
        }
    }

    /// Magic prefix for encrypted archives ("KYLENC1" + null byte).
    public static let header = Data([0x4B, 0x59, 0x4C, 0x45, 0x4E, 0x43, 0x31, 0x00])
    private static let salt = "com.kylmora.sync.aes256.v1"

    /// Checks if a payload was encrypted with Kylmora's sync cipher.
    public static func isEncrypted(_ data: Data) -> Bool {
        guard data.count >= header.count else { return false }
        return data.prefix(header.count) == header
    }

    /// Derives a 256-bit symmetric key from a user passphrase.
    public static func deriveKey(from passphrase: String) -> SymmetricKey {
        let input = (passphrase + salt).data(using: .utf8) ?? Data()
        let digest = SHA256.hash(data: input)
        return SymmetricKey(data: digest)
    }

    /// Encrypts data with AES-256-GCM using the provided passphrase.
    public static func encrypt(_ data: Data, passphrase: String) throws -> Data {
        let key = deriveKey(from: passphrase)
        let sealedBox = try AES.GCM.seal(data, using: key)
        guard let combined = sealedBox.combined else {
            throw CryptoError.corruptedCiphertext
        }
        var output = header
        output.append(combined)
        return output
    }

    /// Decrypts data with AES-256-GCM if encrypted, or returns raw data if plain.
    public static func decrypt(_ data: Data, passphrase: String?) throws -> Data {
        guard isEncrypted(data) else {
            // Plaintext JSON archive: return as is
            return data
        }

        guard let passphrase, !passphrase.isEmpty else {
            throw CryptoError.passphraseRequired
        }

        let key = deriveKey(from: passphrase)
        let ciphertext = data.dropFirst(header.count)

        do {
            let sealedBox = try AES.GCM.SealedBox(combined: ciphertext)
            return try AES.GCM.open(sealedBox, using: key)
        } catch {
            throw CryptoError.incorrectPassphrase
        }
    }
}
