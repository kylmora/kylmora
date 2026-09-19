import AppKit
import Foundation

extension Notification.Name {
    /// Broadcast when enterprise policies change or are reloaded.
    public static let enterprisePoliciesDidChange = Notification.Name("com.kylmora.enterprisePoliciesDidChange")
}

/// Represents an actively enforced corporate policy for display and auditing.
public struct EnforcedPolicy: Identifiable, Sendable {
    public var id: String { key.rawValue }
    public let key: EnterprisePolicyKey
    public let valueDescription: String
    public let isForced: Bool
}

/// The core corporate policy manager for Kylmora.
///
/// Reads and enforces enterprise configurations distributed via:
/// 1. Apple Managed Preferences (MCX / MDM profiles via `CFPreferencesAppValueIsForced`).
/// 2. `UserDefaults` managed domain (`com.kylmora.Kylmora`).
/// 3. Standard corporate JSON policy files in `/Library/Application Support/Kylmora/policies.json`.
/// 4. Programmatic mock policies for unit testing and local developer overrides.
@MainActor
public final class EnterprisePolicyManager {
    public static let shared = EnterprisePolicyManager()

    public let bundleIdentifier: String
    private let defaults: UserDefaults
    private let fileManager: FileManager
    private var mockPolicies: [EnterprisePolicyKey: Any]?
    private var cachedJSONPolicies: [String: Any]?

    public init(
        bundleIdentifier: String = "com.kylmora.Kylmora",
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.defaults = defaults
        self.fileManager = fileManager
        loadJSONPolicies()
    }

    // MARK: - Testing & Overrides

    /// Injects an in-memory dictionary of policies for unit tests.
    public func setMockPolicies(_ policies: [EnterprisePolicyKey: Any]) {
        self.mockPolicies = policies
        NotificationCenter.default.post(name: .enterprisePoliciesDidChange, object: self)
    }

    /// Clears any in-memory mock policies.
    public func clearMockPolicies() {
        self.mockPolicies = nil
        NotificationCenter.default.post(name: .enterprisePoliciesDidChange, object: self)
    }

    // MARK: - JSON Policy Loading

    /// Checks standard corporate policy paths:
    /// - `/Library/Application Support/Kylmora/policies.json` (System-wide)
    /// - `~/Library/Application Support/Kylmora/policies.json` (User-specific)
    private func loadJSONPolicies() {
        let paths = [
            "/Library/Application Support/Kylmora/policies.json",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Kylmora/policies.json").path
        ]

        for path in paths {
            guard fileManager.fileExists(atPath: path),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            cachedJSONPolicies = json
            return
        }
    }

    public func reloadPolicies() {
        loadJSONPolicies()
        NotificationCenter.default.post(name: .enterprisePoliciesDidChange, object: self)
    }

    // MARK: - Value Query

    /// Checks if a policy key is actively managed and enforced.
    public func isPolicyForced(_ key: EnterprisePolicyKey) -> Bool {
        if mockPolicies != nil {
            return mockPolicies?[key] != nil
        }

        // 1. Apple Managed Preferences check (MDM / MCX)
        if CFPreferencesAppValueIsForced(key.rawValue as CFString, bundleIdentifier as CFString) {
            return true
        }

        // 2. JSON policy file check
        if cachedJSONPolicies?[key.rawValue] != nil {
            return true
        }

        // 3. User defaults check
        return defaults.object(forKey: key.rawValue) != nil
    }

    /// Retrieves an object value for a given policy key.
    public func value(for key: EnterprisePolicyKey) -> Any? {
        if let mock = mockPolicies?[key] {
            return mock
        }

        // 1. Managed preference via CFPreferences
        if let cfVal = CFPreferencesCopyAppValue(key.rawValue as CFString, bundleIdentifier as CFString) {
            return cfVal as Any
        }

        // 2. JSON policy file
        if let jsonVal = cachedJSONPolicies?[key.rawValue] {
            return jsonVal
        }

        // 3. UserDefaults
        return defaults.object(forKey: key.rawValue)
    }

    public func string(for key: EnterprisePolicyKey) -> String? {
        guard let val = value(for: key) else { return nil }
        if let str = val as? String { return str }
        if let num = val as? NSNumber { return num.stringValue }
        return nil
    }

    public func bool(for key: EnterprisePolicyKey) -> Bool? {
        guard let val = value(for: key) else { return nil }
        if let b = val as? Bool { return b }
        if let num = val as? NSNumber { return num.boolValue }
        if let str = val as? String {
            let lower = str.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return lower == "true" || lower == "1" || lower == "yes"
        }
        return nil
    }

    public func stringArray(for key: EnterprisePolicyKey) -> [String]? {
        guard let val = value(for: key) else { return nil }
        if let arr = val as? [String] { return arr }
        if let arr = val as? [Any] { return arr.compactMap { "\($0)" } }
        if let str = val as? String {
            return str.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    // MARK: - Standard Policy Accessors

    /// Whether any corporate policies are currently active.
    public var isManaged: Bool {
        EnterprisePolicyKey.allCases.contains { isPolicyForced($0) }
    }

    /// Name of the managing organization.
    public var organizationName: String {
        string(for: .organizationName) ?? "Your Organization"
    }

    public var homepageURL: URL? {
        guard let str = string(for: .homepageURL), let url = URL(string: str) else { return nil }
        return url
    }

    public var newTabURL: URL? {
        guard let str = string(for: .newTabURL), let url = URL(string: str) else { return nil }
        return url
    }

    public var defaultSearchEngine: String? {
        string(for: .defaultSearchEngine)
    }

    public var isSearchEngineLocked: Bool {
        bool(for: .lockSearchEngine) == true || defaultSearchEngine != nil
    }

    public var isDeveloperToolsDisabled: Bool {
        bool(for: .developerToolsDisabled) == true
    }

    public var isPrivateBrowsingDisabled: Bool {
        bool(for: .privateBrowsingDisabled) == true
    }

    public var isPasswordManagerDisabled: Bool {
        bool(for: .passwordManagerDisabled) == true
    }

    public var isContentBlockingForced: Bool {
        bool(for: .contentBlockingForced) == true
    }

    public var isAutoUpdateForced: Bool {
        bool(for: .autoUpdateForced) == true
    }

    public var isRAMCacheOnlyForced: Bool {
        bool(for: .ramCacheOnlyForced) == true
    }

    public var dohURL: URL? {
        guard let str = string(for: .dohURL), let url = URL(string: str) else { return nil }
        return url
    }

    public var urlBlocklist: [String] {
        stringArray(for: .urlBlocklist) ?? []
    }

    public var urlAllowlist: [String] {
        stringArray(for: .urlAllowlist) ?? []
    }

    public var isBlockAllExtensions: Bool {
        bool(for: .blockAllExtensions) == true
    }

    public var isNativeMessagingDisabled: Bool {
        bool(for: .nativeMessagingDisabled) == true
    }

    /// `nil` when the organisation has not restricted the list, which is not
    /// the same as an empty list: an empty list would allow nothing.
    public var nativeMessagingHostAllowlist: [String]? {
        stringArray(for: .nativeMessagingHostAllowlist)
    }

    public var extensionInstallBlocklist: [String] {
        stringArray(for: .extensionInstallBlocklist) ?? []
    }

    public var extensionInstallAllowlist: [String] {
        stringArray(for: .extensionInstallAllowlist) ?? []
    }

    // MARK: - URL Filtering Logic

    /// Evaluates if navigation to the given URL is blocked by corporate URL policy.
    public func isURLBlocked(_ url: URL) -> Bool {
        guard !urlBlocklist.isEmpty else { return false }

        // Allow internal schemes that must function
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "about" || scheme == "kylmora" {
            return false
        }

        // 1. Check Allowlist: if explicitly allowed, never block
        for pattern in urlAllowlist {
            if matches(pattern: pattern, url: url) {
                return false
            }
        }

        // 2. Check Blocklist: if matches any blocked pattern, block
        for pattern in urlBlocklist {
            if matches(pattern: pattern, url: url) {
                return true
            }
        }

        return false
    }

    /// Matches a URL against an enterprise pattern.
    ///
    /// Patterns support:
    /// - `*`: All URLs
    /// - `*.example.com` or `.example.com`: Matches `example.com` and all subdomains
    /// - `example.com`: Matches `example.com`, `www.example.com`, and subdomains
    /// - `https://*`: Matches all HTTPS traffic
    /// - `http://*`: Matches all HTTP traffic
    /// - `example.com/restricted/*`: Path-based filtering
    public func matches(pattern: String, url: URL) -> Bool {
        let pattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if pattern == "*" { return true }

        let urlString = url.absoluteString.lowercased()
        let host = url.host?.lowercased() ?? ""
        let scheme = url.scheme?.lowercased() ?? ""
        let path = url.path.lowercased()

        // Scheme-only wildcard matching (e.g. "https://*" or "http://*")
        if pattern == "\(scheme)://*" {
            return true
        }

        // Scheme + Host + Path pattern (e.g. "https://bad.com/*" or "*://*.gambling.com/*")
        if pattern.contains("://") {
            let parts = pattern.components(separatedBy: "://")
            guard parts.count == 2 else { return false }
            let patternScheme = parts[0]
            let patternRest = parts[1]

            if patternScheme != "*" && patternScheme != scheme {
                return false
            }

            return matchHostAndPath(patternRest: patternRest, host: host, path: path, fullString: urlString)
        }

        // Host and optional path pattern (e.g. "*.domain.com" or "domain.com/path*")
        return matchHostAndPath(patternRest: pattern, host: host, path: path, fullString: urlString)
    }

    private func matchHostAndPath(patternRest: String, host: String, path: String, fullString: String) -> Bool {
        var patternHost = patternRest
        var patternPath: String?

        if let slashIndex = patternRest.firstIndex(of: "/") {
            patternHost = String(patternRest[..<slashIndex])
            patternPath = String(patternRest[slashIndex...])
        }

        // Check Host
        let hostMatches: Bool
        if patternHost == "*" {
            hostMatches = true
        } else if patternHost.hasPrefix("*.") {
            let base = String(patternHost.dropFirst(2))
            hostMatches = host == base || host.hasSuffix("." + base)
        } else if patternHost.hasPrefix(".") {
            let base = String(patternHost.dropFirst(1))
            hostMatches = host == base || host.hasSuffix("." + base)
        } else {
            hostMatches = host == patternHost || host.hasSuffix("." + patternHost)
        }

        guard hostMatches else { return false }

        // Check Path if specified
        if let patternPath {
            if patternPath == "/*" || patternPath == "/" || patternPath.isEmpty {
                return true
            }
            if patternPath.hasSuffix("/*") {
                let prefix = String(patternPath.dropLast(2))
                return path.hasPrefix(prefix)
            }
            if patternPath.hasSuffix("*") {
                let prefix = String(patternPath.dropLast(1))
                return path.hasPrefix(prefix)
            }
            return path == patternPath || path.hasPrefix(patternPath + "/")
        }

        return true
    }

    // MARK: - Extension Filtering Logic

    /// Checks if a given extension identifier is allowed by enterprise policy.
    public func isExtensionAllowed(id: String) -> Bool {
        if isBlockAllExtensions {
            return false
        }

        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedID.isEmpty else { return true }

        // 1. If allowlist is populated:
        let allowlist = extensionInstallAllowlist.map { $0.lowercased() }
        if !allowlist.isEmpty {
            if allowlist.contains("*") || allowlist.contains(normalizedID) {
                return true
            }
            return false
        }

        // 2. If blocklist is populated:
        let blocklist = extensionInstallBlocklist.map { $0.lowercased() }
        if blocklist.contains("*") || blocklist.contains(normalizedID) {
            return false
        }

        return true
    }

    // MARK: - Active Policies Report

    /// Returns a list of all currently active policies and their enforced values.
    public var activePolicies: [EnforcedPolicy] {
        var list: [EnforcedPolicy] = []
        for key in EnterprisePolicyKey.allCases {
            guard isPolicyForced(key), let val = value(for: key) else { continue }
            let desc: String
            if let arr = val as? [Any] {
                desc = arr.map { "\($0)" }.joined(separator: ", ")
            } else if let b = val as? Bool {
                desc = b ? "Enabled" : "Disabled"
            } else {
                desc = "\(val)"
            }
            list.append(EnforcedPolicy(key: key, valueDescription: desc, isForced: true))
        }
        return list
    }
}
