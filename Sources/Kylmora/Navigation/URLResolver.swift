import Foundation

/// Turns raw address-bar text into something navigable.
///
/// This is the omnibox decision: is the user typing a URL, or a search? Kept as
/// pure, dependency-free logic so it can be unit tested without a web view.
enum URLResolver {
    /// Schemes we hand straight to WebKit when the user types them explicitly.
    private static let passthroughSchemes: Set<String> = [
        "http", "https", "file", "about", "data", "blob", "javascript"
    ]

    /// Hosts that are valid without a dot.
    private static let dotlessHosts: Set<String> = ["localhost"]

    static func resolve(_ input: String, using engine: SearchEngine = .duckDuckGo) -> URL? {
        resolve(input, using: engine, engines: [])
    }

    /// As above, with quick searches: a first word that is an engine's
    /// keyword, followed by anything, searches that engine instead.
    static func resolve(_ input: String, using engine: SearchEngine, engines: [SearchEngine]) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let quick = quickSearch(text, engines: engines) {
            return quick.engine.url(for: quick.query)
        }

        if let scheme = explicitScheme(of: text) {
            return passthroughSchemes.contains(scheme) ? URL(string: text) : engine.url(for: text)
        }

        if looksLikeHost(text), let url = URL(string: "\(defaultScheme(for: text))://\(text)") {
            return url
        }

        return engine.url(for: text)
    }

    /// `g cats` with an engine whose keyword is `g`. The keyword alone is not
    /// a search; there is nothing to search for.
    static func quickSearch(_ text: String, engines: [SearchEngine]) -> (engine: SearchEngine, query: String)? {
        guard let space = text.firstIndex(where: \.isWhitespace) else { return nil }
        let word = text[..<space].lowercased()
        let query = text[space...].trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, let engine = engines.first(where: { $0.keyword == word }) else { return nil }
        return (engine, query)
    }

    /// Schemes that are legitimately written without `//` after the colon.
    private static let opaqueSchemes: Set<String> = [
        "about", "data", "javascript", "blob", "mailto", "tel", "sms"
    ]

    /// Returns the lowercased scheme if the text really starts with `scheme:`.
    ///
    /// The colon alone is not enough: `localhost:8080` is a host and a port, not
    /// a `localhost` scheme. A scheme is recognised only when it is followed by
    /// `//` or when it is a known opaque scheme.
    private static func explicitScheme(of text: String) -> String? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let candidate = String(text[text.startIndex..<colon])
        guard !candidate.isEmpty,
              candidate.first?.isLetter == true,
              candidate.allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }) else {
            return nil
        }

        let rest = text[text.index(after: colon)...]
        let scheme = candidate.lowercased()
        if rest.hasPrefix("//") || opaqueSchemes.contains(scheme) {
            return scheme
        }
        return nil
    }

    /// `https` for the web, `http` for this machine and the local network.
    ///
    /// A development server on `localhost:8080` or `192.168.1.5` has no
    /// certificate, so an upgraded address there never loads: it fails with a
    /// certificate error and no way to try plain HTTP short of typing the
    /// scheme. Safari and Chrome make the same exception.
    static func defaultScheme(for text: String) -> String {
        guard let host = host(of: text) else { return "https" }
        return isLocal(host: host) ? "http" : "https"
    }

    /// The host portion of typed text: no scheme, userinfo, port or path.
    private static func host(of text: String) -> String? {
        guard !text.contains(where: { $0.isWhitespace }) else { return nil }

        // Strip path, query and fragment; only the authority matters here.
        let authority = text.prefix(while: { $0 != "/" && $0 != "?" && $0 != "#" })
        guard !authority.isEmpty else { return nil }

        // Drop any userinfo and port.
        let hostPart = authority.split(separator: "@").last.map(String.init) ?? String(authority)
        let host = hostPart.split(separator: ":").first.map(String.init) ?? hostPart
        return host.isEmpty ? nil : host
    }

    /// `localhost`, `.local`/`.localhost` names, and the loopback, private
    /// and link-local IPv4 ranges.
    private static func isLocal(host: String) -> Bool {
        let name = host.lowercased()
        if name == "localhost" || name.hasSuffix(".localhost") || name.hasSuffix(".local") { return true }
        guard isIPv4(name) else { return false }
        let octets = name.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (0, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        default: return false
        }
    }

    /// Heuristic: a bare host has no whitespace and either contains a dot in the
    /// host portion or is a known dotless host such as `localhost`.
    private static func looksLikeHost(_ text: String) -> Bool {
        guard let host = host(of: text) else { return false }

        if dotlessHosts.contains(host.lowercased()) { return true }
        guard host.contains(".") else { return false }

        // Dotted-quad IP addresses are hosts even though their last label is numeric.
        if isIPv4(host) { return true }

        // "1.5" or "hello.world " style input is more likely a search than a host,
        // so require the last label to look like a TLD.
        guard let tld = host.split(separator: ".").last, tld.count >= 2,
              tld.allSatisfy({ $0.isLetter }) else {
            return false
        }
        return true
    }

    private static func isIPv4(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count == 4 else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 3 && label.allSatisfy(\.isNumber) && (Int(label) ?? 256) <= 255
        }
    }
}
