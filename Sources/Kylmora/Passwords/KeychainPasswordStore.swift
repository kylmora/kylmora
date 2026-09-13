import Foundation
import Security

/// One saved website login.
struct PasswordCredential: Equatable, Sendable, Identifiable {
    let host: String
    let username: String
    let password: String

    var id: String { "\(host)\u{0000}\(username)" }
}

/// Saves and reads website logins in the macOS login Keychain -- the system's
/// own store, iCloud-synced -- so Kylmora keeps no password database of its own.
/// Items are ordinary internet passwords, the same class Safari uses, so
/// they live beside the user's other saved logins and sync the same way.
///
/// Kylmora reads and writes its own items with no prompt; items another app saved
/// carry that app's access control, so reading them can raise the system's
/// "Allow" prompt -- which is the correct, user-visible boundary.
enum KeychainPasswordStore {
    /// New items are labelled so "Manage Passwords" can list the ones Kylmora saved
    /// without walking every internet password on the machine.
    static let label = "Kylmora"

    private static func query(host: String? = nil, account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        if let host { query[kSecAttrServer as String] = host }
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    /// Saves a login, updating the password if the host and username already
    /// exist. Returns whether it was stored.
    @discardableResult
    static func save(host: String, username: String, password: String) -> Bool {
        let data = Data(password.utf8)
        let update = SecItemUpdate(
            query(host: host, account: username) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }

        var attributes = query(host: host, account: username)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = label
        attributes[kSecAttrSynchronizable as String] = kCFBooleanTrue
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    /// Every login stored for a host -- what autofill offers on that site.
    static func credentials(host: String) -> [PasswordCredential] {
        items(matching: query(host: host)).compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String,
                  let password = password(in: item) else { return nil }
            return PasswordCredential(host: host, username: account, password: password)
        }
    }

    /// Every login Kylmora has saved, for the Manage Passwords list.
    static func all() -> [PasswordCredential] {
        var q = query()
        q[kSecAttrLabel as String] = label
        return items(matching: q).compactMap { item in
            guard let host = item[kSecAttrServer as String] as? String,
                  let account = item[kSecAttrAccount as String] as? String,
                  let password = password(in: item) else { return nil }
            return PasswordCredential(host: host, username: account, password: password)
        }.sorted { $0.host == $1.host ? $0.username < $1.username : $0.host < $1.host }
    }

    @discardableResult
    static func delete(host: String, username: String) -> Bool {
        SecItemDelete(query(host: host, account: username) as CFDictionary) == errSecSuccess
    }

    // MARK: - Helpers

    private static func items(matching query: [String: Any]) -> [[String: Any]] {
        var query = query
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items
    }

    private static func password(in item: [String: Any]) -> String? {
        guard let data = item[kSecValueData as String] as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Where Kylmora fills passwords from. The macOS Keychain is built in; every other
/// manager (1Password, Bitwarden, ...) plugs in as a browser extension, not as a
/// native provider -- there is no public API to read their vaults -- so
/// the alternative is simply "Others", which points the user at those.
enum PasswordProvider: String, CaseIterable, Sendable {
    case keychain
    case others

    var title: String {
        switch self {
        case .keychain: return "macOS Keychain"
        case .others: return "Others"
        }
    }
}

/// A password manager Kylmora can point the user to install, since it cannot read
/// the manager's vault itself -- clicking one opens its extension page in Kylmora.
struct PasswordManagerLink: Sendable {
    let name: String
    let url: URL

    static let common: [PasswordManagerLink] = [
        Self(name: "1Password", "https://1password.com/downloads/browser-extension/"),
        Self(name: "Bitwarden", "https://bitwarden.com/download/"),
        Self(name: "Dashlane", "https://www.dashlane.com/download"),
        Self(name: "Proton Pass", "https://proton.me/pass/download"),
        Self(name: "LastPass", "https://www.lastpass.com/misc/download")
    ]

    private init(name: String, _ url: String) {
        self.name = name
        self.url = URL(string: url)!
    }
}
