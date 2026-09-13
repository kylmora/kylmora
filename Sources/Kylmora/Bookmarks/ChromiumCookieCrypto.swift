import Foundation
import CommonCrypto
import Security

/// Decrypts the cookie values Chrome and the other Chromium browsers store.
///
/// On macOS a Chromium cookie's `encrypted_value` is `v10` followed by AES-128
/// in CBC mode. The key is PBKDF2-HMAC-SHA1 of a random password the browser
/// keeps in the login Keychain ("<Browser> Safe Storage"), with the fixed salt
/// "saltysalt", 1003 iterations, 16 bytes out; the IV is sixteen spaces. Reading
/// that Keychain item is what raises the one-time "Allow" prompt -- and needs an
/// unsandboxed app, which is why this is possible at all. This is the same
/// routine Chrome, Arc and Orion use to migrate logins.
enum ChromiumCookieCrypto {
    /// The Keychain password a Chromium browser encrypts its cookies with. The
    /// call raises the system's "Allow" prompt the first time.
    static func safeStoragePassword(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Turns a Safe Storage password into the 16-byte AES key.
    static func deriveKey(password: String) -> Data {
        pbkdf2SHA1(
            password: Data(password.utf8),
            salt: Data("saltysalt".utf8),
            iterations: 1003,
            keyLength: kCCKeySizeAES128
        )
    }

    /// Decrypts one `encrypted_value` blob to its cookie string. A value with no
    /// `v10` tag is already plaintext (a profile that never had a Keychain key).
    static func decrypt(_ encrypted: Data, key: Data) -> String? {
        guard encrypted.count > 3, encrypted.prefix(3) == Data("v10".utf8) else {
            return String(data: encrypted, encoding: .utf8)
        }
        let ciphertext = Data(encrypted.dropFirst(3))
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        guard let plaintext = aes128CBCDecrypt(ciphertext, key: key, iv: iv) else { return nil }
        // Newer Chromium prepends a 32-byte SHA-256 of the cookie's domain as an
        // integrity check; drop it when what is left is the text.
        if let text = String(data: plaintext, encoding: .utf8) { return text }
        guard plaintext.count > 32 else { return nil }
        return String(data: plaintext.dropFirst(32), encoding: .utf8)
    }

    // MARK: - Primitives

    static func pbkdf2SHA1(password: Data, salt: Data, iterations: Int, keyLength: Int) -> Data {
        var derived = Data(count: keyLength)
        let status = derived.withUnsafeMutableBytes { out in
            salt.withUnsafeBytes { saltBytes in
                password.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress, password.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        UInt32(iterations),
                        out.bindMemory(to: UInt8.self).baseAddress, keyLength
                    )
                }
            }
        }
        return status == kCCSuccess ? derived : Data()
    }

    static func aes128CBCDecrypt(_ ciphertext: Data, key: Data, iv: Data) -> Data? {
        guard !ciphertext.isEmpty, ciphertext.count % kCCBlockSizeAES128 == 0 else { return nil }
        var output = Data(count: ciphertext.count + kCCBlockSizeAES128)
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            ciphertext.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress,
                            input.baseAddress, ciphertext.count,
                            out.baseAddress, out.count, &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return output.prefix(moved)
    }
}
