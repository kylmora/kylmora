import Foundation

/// Renders a URL the way an address bar should: no `https://`, no bare `//`.
enum AddressFormatter {
    static func display(_ url: URL) -> String {
        display(url, full: true, unicodeDomains: false)
    }

    /// The address as the chrome shows it.
    ///
    /// - Parameters:
    ///   - full: the whole address, or the host alone.
    ///   - unicodeDomains: an internationalised host as its letters rather
    ///     than `xn--` and a code. Off by default: `paypal.com` written with
    ///     a Cyrillic letter looks identical to the real thing, and the code
    ///     is what gives it away.
    static func display(_ url: URL, full: Bool, unicodeDomains: Bool) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https" || components.scheme == "http" else {
            return url.absoluteString
        }
        // `URLComponents.host` already gives the letters; the encoded form
        // is what the URL carries, and the one shown unless asked otherwise.
        let encodedHost = url.host() ?? components.percentEncodedHost ?? ""
        let shownHost = unicodeDomains ? (Punycode.decodeHost(encodedHost) ?? encodedHost) : encodedHost
        if !full { return shownHost }
        if components.scheme == "https" { components.scheme = nil }
        var string = components.string ?? url.absoluteString
        if string.hasPrefix("//") { string.removeFirst(2) }
        if shownHost != encodedHost, let range = string.range(of: encodedHost) {
            string.replaceSubrange(range, with: shownHost)
        }
        return string
    }
}
