import Foundation

/// The defined keys for Apple Managed Preferences (MCX), MDM mobileconfig payloads,
/// and enterprise policy configuration for Kylmora.
public enum EnterprisePolicyKey: String, CaseIterable, Sendable {
    /// Overrides and locks the browser's default homepage URL.
    case homepageURL = "HomepageURL"
    /// Overrides and locks the default new tab URL.
    case newTabURL = "NewTabURL"
    /// Enforces the default search engine identifier (e.g. "google", "duckduckgo", "kagi", "bing").
    case defaultSearchEngine = "DefaultSearchEngine"
    /// When true, prevents the user from changing the default search engine.
    case lockSearchEngine = "LockSearchEngine"
    /// List of URL patterns or domains blocked by corporate policy.
    case urlBlocklist = "URLBlocklist"
    /// List of URL patterns or domains explicitly permitted, overriding the blocklist.
    case urlAllowlist = "URLAllowlist"
    /// When true, completely disables extension installation.
    case blockAllExtensions = "BlockAllExtensions"
    /// List of extension identifiers blocked from installation.
    case extensionInstallBlocklist = "ExtensionInstallBlocklist"
    /// List of extension identifiers permitted for installation.
    case extensionInstallAllowlist = "ExtensionInstallAllowlist"
    /// When true, prevents extensions from launching native messaging hosts.
    case nativeMessagingDisabled = "NativeMessagingDisabled"
    /// Host names extensions may launch; when set, every other host is refused.
    case nativeMessagingHostAllowlist = "NativeMessagingHostAllowlist"
    /// When true, disables Web Inspector, Developer Tools, and JavaScript Console.
    case developerToolsDisabled = "DeveloperToolsDisabled"
    /// When true, disables creation and usage of Private Spaces and Private Tabs for auditing compliance.
    case privateBrowsingDisabled = "PrivateBrowsingDisabled"
    /// When true, disables built-in password autofill and saving.
    case passwordManagerDisabled = "PasswordManagerDisabled"
    /// When true, forces built-in ad and tracker blocking on without allowing user to disable it.
    case contentBlockingForced = "ContentBlockingForced"
    /// When true, forces automatic update checks and disables the ability to turn them off.
    case autoUpdateForced = "AutoUpdateForced"
    /// Enforces a specific DNS over HTTPS resolver URL across the browser.
    case dohURL = "DNSOverHTTPSURL"
    /// The display name of the managing organization (e.g. "Acme Corp"), shown in UI indicators.
    case organizationName = "OrganizationName"
    /// When true, forces RAM-only caching without persisting web cache to SSD.
    case ramCacheOnlyForced = "RAMCacheOnlyForced"

    /// A human-readable title for the policy.
    public var title: String {
        switch self {
        case .homepageURL: return "Homepage URL"
        case .newTabURL: return "New Tab URL"
        case .defaultSearchEngine: return "Default Search Engine"
        case .lockSearchEngine: return "Lock Search Engine"
        case .urlBlocklist: return "URL Blocklist"
        case .urlAllowlist: return "URL Allowlist"
        case .blockAllExtensions: return "Block All Extensions"
        case .extensionInstallBlocklist: return "Extension Install Blocklist"
        case .extensionInstallAllowlist: return "Extension Install Allowlist"
        case .nativeMessagingDisabled: return "Native Messaging Disabled"
        case .nativeMessagingHostAllowlist: return "Native Messaging Host Allowlist"
        case .developerToolsDisabled: return "Developer Tools Disabled"
        case .privateBrowsingDisabled: return "Private Browsing Disabled"
        case .passwordManagerDisabled: return "Password Manager Disabled"
        case .contentBlockingForced: return "Force Content Blocking"
        case .autoUpdateForced: return "Force Automatic Updates"
        case .dohURL: return "DNS Over HTTPS Resolver"
        case .organizationName: return "Organization Name"
        case .ramCacheOnlyForced: return "Force RAM-Only Caching"
        }
    }

    /// A human-readable description of what the policy enforces.
    public var summary: String {
        switch self {
        case .homepageURL: return "Sets the mandatory homepage URL."
        case .newTabURL: return "Sets the mandatory URL for new tabs."
        case .defaultSearchEngine: return "Sets the mandatory search engine."
        case .lockSearchEngine: return "Prevents modification of the search engine selection."
        case .urlBlocklist: return "Restricts access to specific domains and URL patterns."
        case .urlAllowlist: return "Exceptions to the URL blocklist that remain accessible."
        case .blockAllExtensions: return "Completely blocks installation and execution of browser extensions."
        case .extensionInstallBlocklist: return "Blocks specific extension identifiers from being installed."
        case .extensionInstallAllowlist: return "Allows only specified extension identifiers."
        case .nativeMessagingDisabled: return "Stops extensions from starting programs installed on the Mac."
        case .nativeMessagingHostAllowlist: return "Permits only these native messaging hosts, by manifest name."
        case .developerToolsDisabled: return "Disables Web Inspector, Inspect Element, and Developer Console."
        case .privateBrowsingDisabled: return "Disables Private Spaces and unlogged browsing for compliance."
        case .passwordManagerDisabled: return "Disables saving or autofilling credentials in the browser."
        case .contentBlockingForced: return "Forces ad and tracking protection on without user override."
        case .autoUpdateForced: return "Forces automatic security and software updates."
        case .dohURL: return "Preselects and locks this DNS-over-HTTPS resolver in Settings. Page loads use the Mac's DNS, so push a DNS profile through MDM to enforce it."
        case .organizationName: return "Identifies the managing organization in browser chrome."
        case .ramCacheOnlyForced: return "Mandates memory-only caching to protect SSDs and eliminate disk forensics."
        }
    }
}
