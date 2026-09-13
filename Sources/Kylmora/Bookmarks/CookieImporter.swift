import Foundation

/// Reads another browser's cookies, so the sites the user is signed into there
/// stay signed in in Kylmora.
///
/// Chromium browsers keep cookies in a `Cookies` SQLite whose values are
/// encrypted behind a Keychain key (`ChromiumCookieCrypto`); Firefox keeps them
/// in `cookies.sqlite` in the clear. Both files are read read-only and immutable
/// (`SQLiteDatabase.init(readingOnly:)`) so a running browser's lock never
/// blocks the read and its file is never touched. Reaching the profile folder
/// and the Keychain needs an unsandboxed app (D-SB9).
enum CookieImporter {
    struct Cookie: Sendable, Equatable {
        let name: String
        let value: String
        let domain: String
        let path: String
        /// Nil for a session cookie with no stored expiry.
        let expires: Date?
        let isSecure: Bool
    }

    enum Failure: Error, Equatable {
        case unreadable
        case unrecognised
        /// The "<Browser> Safe Storage" Keychain item was absent or denied.
        case keyUnavailable
        /// Cookies were read but none decrypted -- the key the Keychain gave
        /// back did not fit, which an ad-hoc signature can cause.
        case decryptFailed
        case unsupported
    }

    /// The offset between the 1601 epoch Chromium counts from and 1970, seconds.
    private static let chromeEpochOffset: Double = 11_644_473_600

    static func cookies(from source: BrowserImportSource) throws -> [Cookie] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let profile = source.chromiumProfile, let keychain = source.cookieKeychain {
            // `chromiumProfile` ends in "/Default"; its parent holds every
            // profile's folder, and all of them share one Keychain key.
            let base = home.appending(path: profile).deletingLastPathComponent()
            return try chromium(base: base, service: keychain.service, account: keychain.account)
        }
        if source == .firefox {
            guard let path = firefoxCookiesPath(home) else { throw Failure.unreadable }
            return try firefox(atPath: path)
        }
        throw Failure.unsupported
    }

    // MARK: - Chromium

    /// Reads and decrypts cookies from every profile of a Chromium browser, so a
    /// user with several profiles (Default, Profile 1, ...) gets all their
    /// logins at once. Cookies with no value, and profiles whose cookies do not
    /// decrypt, are skipped; if rows were read but nothing decrypted at all, the
    /// key did not fit and that is reported rather than a silent "imported 0".
    static func chromium(base: URL, service: String, account: String) throws -> [Cookie] {
        guard let password = ChromiumCookieCrypto.safeStoragePassword(service: service, account: account) else {
            throw Failure.keyUnavailable
        }
        let key = ChromiumCookieCrypto.deriveKey(password: password)
        let manager = FileManager.default
        let profiles = (try? manager.contentsOfDirectory(atPath: base.path)) ?? []
        let files = profiles
            .map { base.appending(path: $0).appending(path: "Cookies").path(percentEncoded: false) }
            .filter { manager.fileExists(atPath: $0) }
        guard !files.isEmpty else { throw Failure.unreadable }

        var cookies: [Cookie] = []
        var readAnyRows = false
        var decryptedAny = false
        for path in files {
            guard let database = try? SQLiteDatabase(readingOnly: path),
                  let rows = try? database.query(
                    "SELECT host_key, name, encrypted_value, value, path, expires_utc, is_secure FROM cookies;",
                    row: { row in
                        (host: row.text(0) ?? "", name: row.text(1) ?? "", encrypted: row.blob(2),
                         plain: row.text(3) ?? "", path: row.text(4) ?? "", expires: row.integer(5), secure: row.integer(6))
                    }
                  ) else { continue }
            readAnyRows = readAnyRows || !rows.isEmpty
            for row in rows {
                let value = row.encrypted.isEmpty ? row.plain : (ChromiumCookieCrypto.decrypt(row.encrypted, key: key) ?? "")
                if !value.isEmpty { decryptedAny = true }
                guard !row.host.isEmpty, !value.isEmpty else { continue }
                let expires: Date? = row.expires == 0
                    ? nil
                    : Date(timeIntervalSince1970: Double(row.expires) / 1_000_000 - chromeEpochOffset)
                cookies.append(Cookie(name: row.name, value: value, domain: row.host,
                                      path: row.path.isEmpty ? "/" : row.path, expires: expires, isSecure: row.secure != 0))
            }
        }
        if readAnyRows && !decryptedAny { throw Failure.decryptFailed }
        return cookies
    }

    // MARK: - Firefox

    /// The `cookies.sqlite` of the user's Firefox profile: the default-release
    /// one first, then any profile that has the file.
    static func firefoxCookiesPath(_ home: URL) -> String? {
        let profiles = home.appending(path: "Library/Application Support/Firefox/Profiles")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: profiles.path) else { return nil }
        let ordered = entries.sorted { first, _ in first.contains("default") }
        for name in ordered {
            let candidate = profiles.appending(path: name).appending(path: "cookies.sqlite").path(percentEncoded: false)
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }

    static func firefox(atPath path: String) throws -> [Cookie] {
        guard FileManager.default.fileExists(atPath: path) else { throw Failure.unreadable }
        guard let database = try? SQLiteDatabase(readingOnly: path) else { throw Failure.unreadable }
        guard let rows = try? database.query(
            "SELECT host, name, value, path, expiry, isSecure FROM moz_cookies;",
            row: { row in
                (host: row.text(0) ?? "", name: row.text(1) ?? "", value: row.text(2) ?? "",
                 path: row.text(3) ?? "", expiry: row.integer(4), secure: row.integer(5))
            }
        ) else { throw Failure.unrecognised }

        return rows.compactMap { row in
            guard !row.host.isEmpty else { return nil }
            let expires: Date? = row.expiry == 0 ? nil : Date(timeIntervalSince1970: Double(row.expiry))
            return Cookie(name: row.name, value: row.value, domain: row.host,
                          path: row.path.isEmpty ? "/" : row.path, expires: expires, isSecure: row.secure != 0)
        }
    }
}
