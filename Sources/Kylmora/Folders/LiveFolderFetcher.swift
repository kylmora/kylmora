import Foundation

/// The one network client live folders are allowed to use.
///
/// **Anonymous, and outside every profile.** A live folder polls on a timer
/// the user did not start, for a folder they may not be looking at, and
/// attaching a profile's session cookie to that turns a background poll into
/// an authenticated hit the site can attribute to a person. Worse,
/// `URLSession` cannot share a `WKWebsiteDataStore`'s jar, so doing it would
/// mean reading cookies out of `WKHTTPCookieStore` and copying them across
/// the profile isolation boundary by hand, on a timer, for every poll.
///
/// The alternative would be to issue these requests under the workspace's
/// container so the user's GitHub session comes along for free. The cost of
/// not doing that: Kylmora's GitHub provider sees public activity for a named
/// account and nothing else. That is a real feature difference, taken
/// deliberately.
actor LiveFolderFetcher {
    static let shared = LiveFolderFetcher()

    /// A sound cap: a feed is text, and anything past a few megabytes of it
    /// is not a feed.
    static let maximumContentLength = 5 * 1024 * 1024

    struct Response: Sendable {
        var data: Data
        /// The body decoded using the charset the document declares, in HTML
        /// precedence order.
        var text: String
        var status: Int
    }

    enum Failure: Error, Sendable, Equatable {
        case unsupportedScheme
        case transport(String)
        case notFound
        case rateLimited(retryAfter: TimeInterval?)
        case status(Int)
        case tooLarge
    }

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // A poll that cannot finish promptly has already missed its slot; the
        // next one is thirty minutes away and will do just as well.
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: configuration)
    }

    /// A plain GET, with the size cap enforced twice: on the declared length
    /// before the body is read, and on the bytes actually received.
    func get(_ url: URL, accept: String) async throws -> Response {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw Failure.unsupportedScheme
        }

        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        // No Referer, no cookies, no credentials: see the type's note.
        request.httpShouldHandleCookies = false

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.transport((error as NSError).localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw Failure.transport("No response") }

        if let declared = http.value(forHTTPHeaderField: "Content-Length"),
           let length = Int(declared), length > Self.maximumContentLength {
            throw Failure.tooLarge
        }
        guard data.count <= Self.maximumContentLength else { throw Failure.tooLarge }

        switch http.statusCode {
        case 200...299:
            break
        case 404:
            throw Failure.notFound
        case 403, 429:
            // GitHub answers a spent rate limit with 403 and an
            // `x-ratelimit-remaining: 0`, not a 429. Both have to be read as a
            // rate limit or the backoff never engages.
            let remaining = http.value(forHTTPHeaderField: "x-ratelimit-remaining")
            if http.statusCode == 429 || remaining == "0" {
                throw Failure.rateLimited(retryAfter: Self.retryAfter(from: http))
            }
            throw Failure.status(http.statusCode)
        default:
            throw Failure.status(http.statusCode)
        }

        let text = Self.decode(data, response: http)
        return Response(data: data, text: text, status: http.statusCode)
    }

    private static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        if let header = response.value(forHTTPHeaderField: "Retry-After"), let seconds = TimeInterval(header) {
            return seconds
        }
        // GitHub sends an absolute reset time instead of a delay.
        if let header = response.value(forHTTPHeaderField: "x-ratelimit-reset"), let epoch = TimeInterval(header) {
            return max(epoch - Date().timeIntervalSince1970, 0)
        }
        return nil
    }

    // MARK: - Charset

    /// Decoding in the precedence order a browser uses: byte-order mark, then
    /// the document's own declaration, then the transport header, then UTF-8.
    ///
    /// Feeds get this wrong constantly -- a Windows-1252 feed served as
    /// `text/xml` with no charset is a normal Tuesday -- and decoding one as
    /// UTF-8 produces either mojibake in every title or, worse, a `nil` string
    /// and an empty folder that looks like a successful fetch.
    static func decode(_ data: Data, response: HTTPURLResponse?) -> String {
        if let fromBOM = decodeUsingBOM(data) { return fromBOM }

        let prefix = data.prefix(8 * 1024)
        if let declared = declaredCharset(in: prefix),
           let text = String(data: data, encoding: declared) {
            return text
        }

        if let name = response?.textEncodingName {
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId {
                let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
                if let text = String(data: data, encoding: encoding) { return text }
            }
        }

        if let text = String(data: data, encoding: .utf8) { return text }
        // Latin-1 cannot fail, so there is always something to parse rather
        // than an empty string masquerading as an empty feed.
        return String(decoding: data, as: UTF8.self)
    }

    private static func decodeUsingBOM(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(4))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if bytes.starts(with: [0xFF, 0xFE]) {
            return String(data: data, encoding: .utf16LittleEndian)
        }
        if bytes.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16BigEndian)
        }
        return nil
    }

    /// `<?xml encoding="…"?>` or `<meta charset="…">`, whichever appears first
    /// in the opening bytes.
    private static func declaredCharset(in prefix: Data) -> String.Encoding? {
        guard let ascii = String(data: prefix, encoding: .isoLatin1)?.lowercased() else { return nil }
        let patterns = ["encoding=\"", "encoding='", "charset=\"", "charset='", "charset="]
        for pattern in patterns {
            guard let start = ascii.range(of: pattern) else { continue }
            let rest = ascii[start.upperBound...]
            let terminators: Set<Character> = ["\"", "'", " ", ">", ";", "?", "\n", "\r"]
            let name = String(rest.prefix { !terminators.contains($0) })
            guard !name.isEmpty else { continue }
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            guard cf != kCFStringEncodingInvalidId else { continue }
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        }
        return nil
    }
}

extension LiveFolderIssue {
    /// The one place a transport failure becomes a displayable state, so both
    /// providers report the same conditions the same way.
    static func from(_ failure: LiveFolderFetcher.Failure) -> LiveFolderIssue {
        switch failure {
        case .unsupportedScheme: return .notConfigured
        case .transport(let message): return .network(message)
        case .notFound: return .sourceUnavailable(status: 404)
        case .rateLimited(let retryAfter): return .rateLimited(retryAfter: retryAfter)
        case .status(let code): return .sourceUnavailable(status: code)
        case .tooLarge: return .malformedResponse
        }
    }
}
