import Foundation

/// A favicon as it is held on disk and passed between isolation domains.
struct FaviconRecord: Sendable, Equatable {
    /// Always a normalised PNG of at most `FaviconDecoder.outputPixelSize`.
    var data: Data
    var source: FaviconSourceKind
}

/// Fetching favicons and keeping them on disk.
///
/// An actor for the same reason `BrowserDatabase` is one:
/// this does network and file I/O, none of which belongs on the main thread,
/// and actor isolation serialises the in-flight table without a lock.
///
/// **The network session is deliberately anonymous.** A favicon fetch is a
/// request to the site that the user did not make, so it carries nothing that
/// could identify them: an ephemeral configuration, cookie storage detached and
/// cookie sending switched off, no credential storage, no URL cache, and no
/// association with any profile's `WKWebsiteDataStore`. See the decision log
/// for why this is the right answer rather than borrowing the profile's
/// cookies.
actor FaviconStore {
    static let shared = FaviconStore()

    /// After this, an icon is refetched the next time the site is opened.
    /// Sites redesign; a cache with no expiry would show last year's logo
    /// forever.
    static let maximumAge: TimeInterval = 7 * 24 * 60 * 60

    /// Roughly 2 MB of PNGs at the sizes this subsystem produces. Bounded for
    /// the same reason the memory cache is: an unbounded cache of everything
    /// ever visited is a slow leak, not a cache.
    static let maximumFileCount = 512
    private static let sweepTarget = 384
    private static let writesBetweenSweeps = 25

    /// Most sites publish one or two icons; four attempts is already generous
    /// and caps how many requests one page can cost.
    private static let maximumAttempts = 4

    private let session: URLSession
    private let directory: URL
    private var inFlight: [String: Task<FaviconRecord?, Never>] = [:]
    private var writesSinceSweep = Int.max

    init(directory: URL? = nil) {
        self.directory = directory ?? AppPaths.supportDirectory.appending(path: "Favicons", directoryHint: .isDirectory)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // A favicon is decoration. It must never hold a connection open or sit
        // in a queue waiting for a network that is not there.
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.httpAdditionalHeaders = ["Accept": "image/*"]
        session = URLSession(configuration: configuration)
    }

    // MARK: - Lookup

    /// The best icon available for a host, fetching if necessary.
    ///
    /// `persist` is false for a private profile: nothing about a browsing
    /// identity that writes nothing to disk should leave a file behind naming
    /// the hosts it visited.
    func icon(
        host: String,
        candidates: [URL],
        source: FaviconSourceKind,
        persist: Bool
    ) async -> FaviconRecord? {
        // Two sidebar rows on the same site must not become two downloads.
        let key = "\(host)#\(source.rawValue)"
        if let existing = inFlight[key] { return await existing.value }

        let task = Task { await self.resolve(host: host, candidates: candidates, source: source, persist: persist) }
        inFlight[key] = task
        let record = await task.value
        inFlight[key] = nil
        return record
    }

    private func resolve(
        host: String,
        candidates: [URL],
        source: FaviconSourceKind,
        persist: Bool
    ) async -> FaviconRecord? {
        let stored = persist ? read(host: host) : nil
        // A stored icon at least as good as the one being asked for, and not
        // yet stale, answers without a request.
        if let stored, stored.record.source >= source, stored.age < Self.maximumAge {
            return stored.record
        }

        for url in candidates.prefix(Self.maximumAttempts) {
            guard let data = await download(url) else { continue }
            guard let normalized = try? FaviconDecoder.normalize(data) else { continue }
            let record = FaviconRecord(data: normalized, source: source)
            if persist { write(record, host: host) }
            return record
        }

        // Every attempt failed. A stale icon is a better answer than none: the
        // site had this icon last week and is more likely offline than rebranded.
        return stored?.record
    }

    private func download(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // No `Referer`, and no other page's identity: the site learns only that
        // someone asked for its icon.
        request.setValue(nil, forHTTPHeaderField: "Referer")

        guard let (data, response) = try? await session.data(for: request) else { return nil }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        // Many servers answer an unknown path with a 200 HTML page rather than
        // a 404, so the cap is enforced on what actually arrived.
        guard !data.isEmpty, data.count <= FaviconDecoder.maximumByteCount else { return nil }
        return data
    }

    // MARK: - Disk

    /// Files are named `<host>-<hash>.<source>.png`.
    ///
    /// A directory of PNGs rather than a table in `browser.sqlite`: the records
    /// are opaque blobs looked up by one key and never joined or queried, which
    /// is the one shape SQL buys nothing for. It also means "forget every
    /// favicon" is removing a directory.
    private func fileURL(host: String, source: FaviconSourceKind) -> URL {
        var safe = ""
        for character in host.unicodeScalars where safe.count < 60 {
            let allowed = ("a"..."z").contains(String(character))
                || ("0"..."9").contains(String(character))
                || character == "." || character == "-"
            safe.unicodeScalars.append(allowed ? character : "_")
        }
        // The sanitiser above maps distinct hosts onto the same string, so the
        // hash of the original is what actually keys the file.
        return directory.appending(path: "\(safe)-\(Self.hash(host)).\(source.rawValue).png")
    }

    /// FNV-1a. Not a security boundary — it only has to spread hosts across
    /// filenames — so this stays a few lines rather than an import.
    private static func hash(_ value: String) -> String {
        var digest: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            digest ^= UInt64(byte)
            digest &*= 0x0000_0100_0000_01b3
        }
        return String(digest, radix: 16)
    }

    private func read(host: String) -> (record: FaviconRecord, age: TimeInterval)? {
        // Highest-quality source first, so a page-declared icon shadows the
        // `/favicon.ico` one that was cached before the page had loaded.
        for source in FaviconSourceKind.allCases.sorted(by: >) {
            let url = fileURL(host: host, source: source)
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            return (FaviconRecord(data: data, source: source), Date.now.timeIntervalSince(modified))
        }
        return nil
    }

    private func write(_ record: FaviconRecord, host: String) {
        guard AppPaths.ensureSupportDirectory(),
              (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil,
              (try? record.data.write(to: fileURL(host: host, source: record.source), options: .atomic)) != nil else {
            return
        }
        // The page's own icon supersedes the guess, so the guess goes.
        if record.source == .dom {
            try? FileManager.default.removeItem(at: fileURL(host: host, source: .convention))
        }

        writesSinceSweep &+= 1
        if writesSinceSweep >= Self.writesBetweenSweeps {
            writesSinceSweep = 0
            sweep()
        }
    }

    /// Least-recently-written eviction, run in batches rather than on every
    /// write so the common case never lists the directory.
    private func sweep() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ), files.count > Self.maximumFileCount else {
            return
        }

        let byAge = files.map { url in
            (url, (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast)
        }.sorted { $0.1 < $1.1 }

        for (url, _) in byAge.prefix(byAge.count - Self.sweepTarget) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// A page-declared icon is strictly better than a guessed one, which is what
/// lets a cached guess be recognised as upgradable.
extension FaviconSourceKind: Comparable {
    static func < (lhs: FaviconSourceKind, rhs: FaviconSourceKind) -> Bool {
        lhs == .convention && rhs == .dom
    }
}
