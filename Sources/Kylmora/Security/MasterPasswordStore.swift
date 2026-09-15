import Foundation
import Security
import CryptoKit

/// Manages secure storage and verification of the user's master password in the macOS Keychain.
@MainActor
public enum MasterPasswordStore {
    public static let serviceName = "com.kylmora.browser.masterpassword"
    public static let accountName = "MasterPassword"

    /// For unit tests running in headless environments where Keychain may not be accessible.
    public static var testOverridePassword: String?

    private static func query() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
    }

    /// Returns whether a master password has been configured.
    public static func hasMasterPassword() -> Bool {
        if let test = testOverridePassword {
            return !test.isEmpty
        }

        var query = query()
        query[kSecReturnData as String] = kCFBooleanFalse
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return status == errSecSuccess
    }

    /// Stores or updates the master password securely in the Keychain.
    @discardableResult
    public static func setMasterPassword(_ password: String) -> Bool {
        if testOverridePassword != nil {
            testOverridePassword = password
            return true
        }

        guard !password.isEmpty else {
            return removeMasterPassword()
        }

        let hash = hashPassword(password)
        let data = Data(hash.utf8)

        // Try updating an existing item first
        let updateQuery = query()
        let updateAttributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }

        if updateStatus == errSecItemNotFound {
            var addAttributes = query()
            addAttributes[kSecValueData as String] = data
            addAttributes[kSecAttrLabel as String] = "Kylmora Master Password"
            let addStatus = SecItemAdd(addAttributes as CFDictionary, nil)
            return addStatus == errSecSuccess
        }

        return false
    }

    /// Verifies if the candidate password matches the stored master password.
    public static func verifyMasterPassword(_ candidate: String) -> Bool {
        if let test = testOverridePassword {
            return test == candidate
        }

        var query = query()
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let storedHash = String(data: data, encoding: .utf8) else {
            return false
        }

        let candidateHash = hashPassword(candidate)
        return candidateHash == storedHash
    }

    /// Clears the stored master password from the Keychain.
    @discardableResult
    public static func removeMasterPassword() -> Bool {
        if testOverridePassword != nil {
            testOverridePassword = nil
            return true
        }

        let query = query()
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func hashPassword(_ password: String) -> String {
        let salted = "kylmora.masterpassword.salt.v1:\(password)"
        let digest = SHA256.hash(data: Data(salted.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
